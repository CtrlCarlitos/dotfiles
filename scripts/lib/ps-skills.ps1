# scripts/lib/ps-skills.ps1 - the "is this skills source already installed?" check,
# the PowerShell twin of skills_up_to_date / skills_record_source in
# scripts/lib/agent-skills.sh.
#
# Consumers:
#   - run_onchange_install_packages.ps1.tmpl: inlined at RENDER time via
#     `{{ include "scripts/lib/ps-skills.ps1" }}` (a run_onchange script must be
#     self-contained, so it cannot dot-source at runtime).
#   - scripts/update_ai_tools.ps1: dot-sources this file.
#
# Template-free on purpose: both consumers load it byte-for-byte.
#
# `skills add` re-fetches every skill on every run and a cold `npx skills@latest` costs
# 30+ s even when nothing moved upstream. A source is skipped only when ALL hold:
#   - DOT_SKILLS_FORCE is not 1,
#   - every named skill is present for Claude (~\.claude\skills) and for OpenCode/Codex
#     (~\.agents\skills),
#   - upstream HEAD (one `git ls-remote`) equals the commit recorded after the last
#     successful install of this exact source + skill list + agent list.
# An unreachable remote never skips. Why not `skills update`: it takes no --copy / -a
# flags and re-links the Claude copy as a symlink into ~\.agents (measured on skills
# 1.7.0), but these installs are deliberately copies.

# Read under Set-StrictMode in the consumers: initialised here, before any function reads
# them (tests/ps_script_scope_vars_contract.sh holds the class).
$script:SkillsPendingKey = ''
$script:SkillsPendingHead = ''
$script:SkillsSeenKeys = @()
# Why the last Test-SkillsUpToDate said "not current", printed with the install line so a
# reinstall on every run can be told apart from a real upstream change.
$script:SkillsStaleReason = ''
# Upstream HEADs fetched by Read-SkillsUpstreamHead, by owner/repo.
$script:SkillsHeadCache = @{}

# USERPROFILE on Windows; $HOME where it is unset (the test fixtures run this on Linux pwsh).
function Get-SkillsHome {
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return $HOME
}

function Get-SkillsSourceStatePath {
    $base = if ($env:XDG_STATE_HOME -and [IO.Path]::IsPathRooted($env:XDG_STATE_HOME)) { $env:XDG_STATE_HOME } else { Join-Path (Get-SkillsHome) '.local\state' }
    return Join-Path (Join-Path $base 'dotfiles') 'skills-sources'
}

# Upstream HEAD of owner/repo, or '' when unknown. A separate function so tests can
# replace it; a process with a hard wait, because git has no timeout of its own.
function Get-SkillsRemoteHead {
    param([string]$Repo)
    if ($script:SkillsHeadCache.ContainsKey($Repo)) { return [string]$script:SkillsHeadCache[$Repo] }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git'
        $psi.Arguments = "ls-remote https://github.com/$Repo.git HEAD"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        if (-not $process.WaitForExit(20000)) {
            try { $process.Kill() } catch { $null = $_ }
            return ''
        }
        $line = ($process.StandardOutput.ReadToEnd() -split "`r?`n" | Select-Object -First 1)
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($line)) { return '' }
        return ($line -split "\s+")[0]
    }
    catch { return '' }
}

# Every source's upstream HEAD in one parallel round, answered from the cache by
# Get-SkillsRemoteHead (twin of skills_prefetch_heads): eight sequential ls-remotes, two of them
# for repos already asked, took 13-35 s. One 20 s deadline for all; anything slower is ''.
function Read-SkillsUpstreamHead {
    param([string[]]$Repo)
    $running = @{}
    foreach ($r in @($Repo | Select-Object -Unique)) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'git'
            $psi.Arguments = "ls-remote https://github.com/$r.git HEAD"
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $running[$r] = [System.Diagnostics.Process]::Start($psi)
        }
        catch { $script:SkillsHeadCache[$r] = '' }
    }
    $deadline = (Get-Date).AddSeconds(20)
    foreach ($r in @($running.Keys)) {
        $process = $running[$r]
        $left = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        if (-not $process.WaitForExit($left)) {
            try { $process.Kill() } catch { $null = $_ }
            $script:SkillsHeadCache[$r] = ''
            continue
        }
        $line = ($process.StandardOutput.ReadToEnd() -split "`r?`n" | Select-Object -First 1)
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($line)) { $script:SkillsHeadCache[$r] = '' }
        else { $script:SkillsHeadCache[$r] = ($line -split "\s+")[0] }
    }
}

function Test-SkillsUpToDate {
    param([string]$Repo, [string[]]$Skills, [string[]]$Agents)

    $script:SkillsPendingKey = "$Repo|$($Skills -join ' ')|$($Agents -join ' ')"
    $script:SkillsSeenKeys += $script:SkillsPendingKey
    $script:SkillsPendingHead = Get-SkillsRemoteHead -Repo $Repo
    $script:SkillsStaleReason = ''
    if ($env:DOT_SKILLS_FORCE -eq '1') { $script:SkillsStaleReason = 'DOT_SKILLS_FORCE=1'; return $false }
    foreach ($skill in $Skills) {
        foreach ($root in '.claude', '.agents') {
            if (-not (Test-Path -LiteralPath (Join-Path (Get-SkillsHome) "$root\skills\$skill\SKILL.md") -PathType Leaf)) {
                $script:SkillsStaleReason = "$skill missing from ~\$root\skills"
                return $false
            }
        }
    }
    if (-not $script:SkillsPendingHead) { $script:SkillsStaleReason = 'upstream unreachable'; return $false }
    $state = Get-SkillsSourceStatePath
    if (-not (Test-Path -LiteralPath $state -PathType Leaf)) { $script:SkillsStaleReason = 'no install recorded yet'; return $false }
    foreach ($line in @(Get-Content -LiteralPath $state)) {
        $parts = $line -split "`t"
        if ($parts.Count -eq 2 -and $parts[0] -ceq $script:SkillsPendingKey) {
            if ($parts[1] -ceq $script:SkillsPendingHead) { return $true }
            $script:SkillsStaleReason = 'upstream changed'
            return $false
        }
    }
    $script:SkillsStaleReason = 'no install recorded for this selection'
    return $false
}

# After a SUCCESSFUL install: store the HEAD Test-SkillsUpToDate saw for the same key.
# Best effort - the state is only a cache.
function Save-SkillsSource {
    if (-not $script:SkillsPendingHead) { return }
    try {
        $state = Get-SkillsSourceStatePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $state) | Out-Null
        $kept = @()
        if (Test-Path -LiteralPath $state -PathType Leaf) {
            $kept = @(Get-Content -LiteralPath $state | Where-Object { ($_ -split "`t")[0] -cne $script:SkillsPendingKey })
        }
        $kept += "$($script:SkillsPendingKey)`t$($script:SkillsPendingHead)"
        [IO.File]::WriteAllLines($state, [string[]]$kept, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-Verbose "skills state not saved: $($_.Exception.Message)" }
}

# Drop state lines this run superseded - twin of skills_prune_state in agent-skills.sh. A
# source key is repo|skills|agents, so changing a selection (a skill added or retired)
# leaves the old key behind for good. For every repo this run checked, keep only the keys it
# checked; lines for repos it did not touch are never removed. Best effort: the state is
# only a cache, and a wrongly dropped line costs one reinstall.
function Invoke-SkillsStatePrune {
    if ($script:SkillsSeenKeys.Count -eq 0) { return }
    try {
        $state = Get-SkillsSourceStatePath
        if (-not (Test-Path -LiteralPath $state -PathType Leaf)) { return }
        $repos = @($script:SkillsSeenKeys | ForEach-Object { ($_ -split '\|')[0] })
        $kept = @(Get-Content -LiteralPath $state | Where-Object {
                $key = ($_ -split "`t")[0]
                ($repos -cnotcontains ($key -split '\|')[0]) -or ($script:SkillsSeenKeys -ccontains $key)
            })
        [IO.File]::WriteAllLines($state, [string[]]$kept, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-Verbose "skills state not pruned: $($_.Exception.Message)" }
}

# Install one source unless it is up to date. $Install returns $true on success; only
# then is the source recorded.
function Invoke-SkillsSource {
    param([string]$Label, [string]$Repo, [string[]]$Skills, [string[]]$Agents, [scriptblock]$Install)

    if (Test-SkillsUpToDate -Repo $Repo -Skills $Skills -Agents $Agents) {
        Write-Host "  ${Label}: up to date"
        return
    }
    if ((& $Install) -eq $true) {
        Save-SkillsSource
        Write-Host "  ${Label}: installed ($script:SkillsStaleReason)"
    }
}

# Remove the skills listed in scripts/retired-agent-skills.txt (`<skill> <source>` per line)
# from every agent directory, the OpenCode command shim we generated and the skills CLI
# lock - twin of skills_remove_retired in scripts/lib/agent-skills.sh. Only when the lock
# records that exact source: a skill of the same name written by hand is never touched.
function Invoke-RetiredSkillsCleanup {
    param([string]$ListPath)

    $userHome = Get-SkillsHome
    $lockPath = Join-Path (Join-Path $userHome '.agents') '.skill-lock.json'
    if (-not $ListPath -or -not (Test-Path -LiteralPath $ListPath -PathType Leaf) -or -not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { return }
    try { $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json } catch { return }
    if ($null -eq $lock.PSObject.Properties['skills']) { return }
    $changed = $false
    foreach ($line in @(Get-Content -LiteralPath $ListPath)) {
        $parts = @(($line.Trim()) -split '\s+')
        if ($parts.Count -lt 2 -or $parts[0].StartsWith('#')) { continue }
        $name = $parts[0]
        $source = $parts[1]
        if ($name -cnotmatch '^[a-z0-9][a-z0-9-]*$') { continue }
        $entry = $lock.skills.PSObject.Properties[$name]
        if ($null -eq $entry -or "$($entry.Value.source)" -cne $source) { continue }
        foreach ($relative in @(".claude\skills\$name", ".agents\skills\$name", ".gemini\antigravity-cli\skills\$name")) {
            Remove-Item -LiteralPath (Join-Path $userHome $relative) -Recurse -Force -ErrorAction SilentlyContinue
        }
        $shim = Join-Path $userHome ".config\opencode\commands\$name.md"
        if ((Test-Path -LiteralPath $shim -PathType Leaf) -and (Select-String -LiteralPath $shim -SimpleMatch 'managed-by: chezmoi-curated-skills' -Quiet)) {
            Remove-Item -LiteralPath $shim -Force -ErrorAction SilentlyContinue
        }
        $lock.skills.PSObject.Properties.Remove($name)
        $changed = $true
        Write-Host "  Removed retired skill: $name"
    }
    if ($changed) {
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    }
}

# Prints a one-line summary plus one line per warn/fail check of `agent-browser doctor
# --json` (the lines it printed) instead of the ~3 KB JSON blob it used to dump on every
# run. Output that is not the expected JSON is printed raw, never dropped.
function Write-AgentBrowserDoctorSummary {
    param([string[]]$Output)

    $text = (@($Output) -join "`n").Trim()
    if (-not $text) { return }
    try { $doctor = $text | ConvertFrom-Json -ErrorAction Stop } catch { Write-Host $text; return }
    if ($null -eq $doctor -or $null -eq $doctor.PSObject.Properties['summary']) { Write-Host $text; return }
    Write-Host ("  agent-browser doctor: {0} pass, {1} warn, {2} fail" -f $doctor.summary.pass, $doctor.summary.warn, $doctor.summary.fail)
    if ($null -eq $doctor.PSObject.Properties['checks']) { return }
    foreach ($check in @($doctor.checks)) {
        if ($check.status -in 'warn', 'fail') {
            $fix = if ($check.PSObject.Properties['fix'] -and $check.fix) { " (fix: $($check.fix))" } else { '' }
            Write-Host ("    {0}: {1}{2}" -f $check.status, $check.message, $fix)
        }
    }
}

# --- guardrail installer output (shared by the installer and the updater) -------------------------
# Twin of guardrail_console_filter in scripts/lib/agent-skills.sh: the agent-guardrails installer
# ends every run with a ~45-line doctor dump, identical on a healthy machine, that buried the
# lines that matter. The FULL output goes to the apply log (Tee-Object, upstream of this filter);
# the console loses only lines whose shape is on this list. A warning, a problem, a verdict, the
# hook latency and anything never seen before - above all an approval prompt or URL, which the
# installer blocks on - stay. DOT_GUARDRAIL_VERBOSE=1 shows everything.
$script:GuardrailHidden = 0
$script:GuardrailRoutinePattern = '^(cwd|GUARDRAIL_CONFIG|overlay|policy warnings|waivers|audit log|approval mode|operator authenticators|engine health|spawn latency):|^web-research enforcement:|^recipes |^(claude|opencode|antigravity|codex): (already enabled|probes pass|guardrail (hook|hooks|integration) registered)|^(claude|opencode|antigravity|codex) settings: guardrail (hook|hooks|integration) registered($|;)|^(claude|opencode|antigravity|codex) ownership: (manifest matches settings|no manifest)|^antigravity coverage:|^  (configured MCP servers|declared MCP tools|uncontracted)|^note: codex probes invoke the hook directly|^setup: (registering|plane status)|^guardrail v[0-9]'

# Get-CodexSuperpowersMarketplace - the marketplace that actually carries a superpowers plugin on
# THIS codex, or $null.
#
# Never hardcode this name. Every consumer used to pass `superpowers@openai-curated-remote`, which
# does not exist on the installed codex: the installer ended in "Error: plugin `superpowers` was not
# found in marketplace `openai-curated-remote`", and the updater reported "Superpowers not installed
# for Codex" with the real error swallowed. The name is genuinely volatile - it resolved to
# `openai-curated` one morning and `openai-api-curated` the same evening - so the only reliable
# source is codex itself: `codex plugin list` prints one `<plugin>@<marketplace>` row per available
# plugin. The Unix twin is codex_superpowers_marketplace in agent-skills.sh;
# tests/codex_marketplace_contract.sh pins all four consumers.
#
# Callers must tolerate $null: a codex that cannot list (offline, first run, a catalog needing auth)
# is a skip, never a hard failure.
function Get-CodexSuperpowersMarketplace {
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { return $null }
    $rows = @()
    try { $rows = @(& codex plugin list 2>$null | ForEach-Object { "$_" }) } catch { return $null }
    foreach ($row in $rows) {
        # `superpowers@<marketplace>` is the first column; the rest of the row is status/path.
        $m = [regex]::Match($row, '^superpowers@(\S+)')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

# Shared by Select-GuardrailConsoleLine and Invoke-GuardrailInstallerProcess: apply the hide list
# to one COMPLETE line. Never called for a still-unterminated prompt fragment - that bypasses the
# hide list entirely and prints immediately (see Invoke-GuardrailInstallerProcess below).
function Write-GuardrailFilteredLine {
    # Not Mandatory: a bare [Parameter(Mandatory)] on a [string] rejects an empty string outright
    # (PowerShell's own binder, not ValidateNotNullOrEmpty) - and a blank line is valid installer
    # output, not a missing argument.
    param([string]$Line)
    if ($env:DOT_GUARDRAIL_VERBOSE -ne '1' -and $Line -cmatch $script:GuardrailRoutinePattern) { $script:GuardrailHidden++ }
    else { Write-Host $Line }
}

function Select-GuardrailConsoleLine {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    begin { $script:GuardrailHidden = 0 }
    process { Write-GuardrailFilteredLine -Line "$InputObject" }
    end {
        if ($script:GuardrailHidden -gt 0) {
            Write-Host ("  ({0} routine guardrail status line(s) hidden; full output in the apply log, or DOT_GUARDRAIL_VERBOSE=1)" -f $script:GuardrailHidden) -ForegroundColor DarkGray
        }
    }
}

# Invoke-GuardrailInstallerProcess <FilePath> <ArgumentList> <LogPath> - runs the agent-guardrails
# installer directly and returns its exit code. Twin of guardrail_console_filter's byte-oriented
# rewrite in scripts/lib/agent-skills.sh (agent-guardrails issue: the installer's approval prompt,
# "Approve register guardrail on planes ...? [y/N] ", carries NO trailing newline - the cursor is
# meant to sit after it).
#
# `& powershell -File install.ps1 2>&1 | Tee-Object -FilePath $log -Append | Select-GuardrailConsoleLine`
# looks like the shell twin's `install.sh 2>&1 | tee -a $log | guardrail_console_filter`, but it is
# not: a shell pipe moves raw bytes, so replacing the sh twin's awk filter with a byte-oriented one
# was enough there. Here, the thing that buffers the prompt is not Select-GuardrailConsoleLine - it
# is PowerShell's own native-command CAPTURE, the step that turns a piped process's stdout into
# pipeline objects in the first place. That capture is RECORD-oriented exactly like awk: it will
# not hand a string downstream until it has seen that line's newline. No filter running AFTER that
# capture can see an unterminated prompt, because the capture never emits one. Confirmed live
# (2026-10-08): with the pipeline form above, the console stayed blank for the whole wait on the
# approval prompt, then printed the prompt AND the typed answer as one line, 3+ seconds late.
#
# So this bypasses that capture: it starts the process itself and reads both output streams at the
# byte level (merging them by whichever read completes first - the same arrival order `2>&1` gives
# on the shell side), using the perl filter's GRACE heuristic: a chunk boundary mid-line keeps
# buffering (more bytes are likely still coming), a stream gone quiet mid-line is a blocked prompt
# and is released immediately, and a released prefix is never re-printed or re-filtered once its
# newline arrives. Complete lines go through the same hide list as Select-GuardrailConsoleLine
# (Write-GuardrailFilteredLine), so the noise reduction is unchanged. The full byte stream still
# lands in -LogPath, byte for byte, exactly as Tee-Object did.
#
# Standard input is deliberately left alone (RedirectStandardInput is never set): it was never the
# broken half - the installer's keystrokes always reached it - and leaving it unset keeps it
# attached to the real console exactly as `&` piping did, so a nested prompt still reads the
# operator's keystrokes.
function Invoke-GuardrailInstallerProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$LogPath
    )
    $script:GuardrailHidden = 0
    $graceMs = 200     # seconds-as-ms twin of guardrail_console_filter's $GRACE (0.2s)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    # Not $psi.ArgumentList.Add(...): on .NET Framework (Windows PowerShell 5.1, confirmed live on
    # PSVersion 5.1.26100.9444) ArgumentList is never auto-initialised and stays $null, unlike
    # .NET Core/pwsh where the constructor creates an empty collection - calling .Add on it throws
    # "cannot call a method on a null-valued expression" there. Arguments takes one pre-quoted
    # string on every PowerShell version, so this builds it the same way ArgumentList would have:
    # every element gets its own double quotes (every value here is this script's own data - a
    # path, a version tag, "enabled"/"disabled" - never free text, so doubling an embedded quote is
    # the only escape this needs).
    $psi.Arguments = ($ArgumentList | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()

    # Same encoding PowerShell's own native-command capture would have decoded these bytes with -
    # this changes only the buffering/timing of what reaches the console, never the text.
    $encoding = [Console]::OutputEncoding
    if (-not $encoding) { $encoding = [System.Text.Encoding]::UTF8 }
    $outDecoder = $encoding.GetDecoder()
    $errDecoder = $encoding.GetDecoder()

    $logStream = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $outStream = $proc.StandardOutput.BaseStream
        $errStream = $proc.StandardError.BaseStream
        $outBuf = New-Object byte[] 65536
        $errBuf = New-Object byte[] 65536
        $charBuf = New-Object char[] 131072
        $outTask = $outStream.ReadAsync($outBuf, 0, $outBuf.Length)
        $errTask = $errStream.ReadAsync($errBuf, 0, $errBuf.Length)
        $outDone = $false
        $errDone = $false
        $line = ''        # text of the line currently being assembled (CR stripped at emit time)
        $shownLen = 0      # how many chars of $line are already on the console (an in-progress prompt)

        while (-not ($outDone -and $errDone)) {
            $tasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
            $taskIsOut = [System.Collections.Generic.List[bool]]::new()
            if (-not $outDone) { [void]$tasks.Add($outTask); [void]$taskIsOut.Add($true) }
            if (-not $errDone) { [void]$tasks.Add($errTask); [void]$taskIsOut.Add($false) }
            # No pending fragment -> block indefinitely; otherwise wake after GRACE so a prompt from
            # a writer that has gone quiet can be released (twin of the perl filter's select() timeout).
            $timeoutMs = if ($line.Length -gt $shownLen) { $graceMs } else { -1 }
            $idx = [System.Threading.Tasks.Task]::WaitAny($tasks.ToArray(), $timeoutMs)
            if ($idx -lt 0) {
                Write-Host -NoNewline $line.Substring($shownLen)
                $shownLen = $line.Length
                continue
            }
            $isOut = $taskIsOut[$idx]
            $n = if ($isOut) { $outTask.Result } else { $errTask.Result }
            if ($n -eq 0) {
                if ($isOut) { $outDone = $true } else { $errDone = $true }
                continue
            }
            $buf = if ($isOut) { $outBuf } else { $errBuf }
            $decoder = if ($isOut) { $outDecoder } else { $errDecoder }
            $logStream.Write($buf, 0, $n)
            $charCount = $decoder.GetChars($buf, 0, $n, $charBuf, 0)
            $line += [string]::new($charBuf, 0, $charCount)
            while (($i = $line.IndexOf("`n")) -ge 0) {
                $completeLine = $line.Substring(0, $i).TrimEnd("`r")
                if ($shownLen -gt 0) {
                    # Finishing a line already partly shown (the prompt): print only what the
                    # console does not have yet, and never re-test it against the hide list.
                    Write-Host $completeLine.Substring([Math]::Min($shownLen, $completeLine.Length))
                    $shownLen = 0
                } else {
                    Write-GuardrailFilteredLine -Line $completeLine
                }
                $line = $line.Substring($i + 1)
            }
            if ($isOut) { $outTask = $outStream.ReadAsync($outBuf, 0, $outBuf.Length) }
            else { $errTask = $errStream.ReadAsync($errBuf, 0, $errBuf.Length) }
        }
        if ($line.Length -gt 0) {
            # Unterminated final line (no trailing newline at EOF).
            $completeLine = $line.TrimEnd("`r")
            if ($shownLen -gt 0) { Write-Host $completeLine.Substring([Math]::Min($shownLen, $completeLine.Length)) }
            else { Write-GuardrailFilteredLine -Line $completeLine }
        }
        if ($script:GuardrailHidden -gt 0) {
            Write-Host ("  ({0} routine guardrail status line(s) hidden; full output in the apply log, or DOT_GUARDRAIL_VERBOSE=1)" -f $script:GuardrailHidden) -ForegroundColor DarkGray
        }
    } finally {
        $logStream.Dispose()
    }
    $proc.WaitForExit()
    return $proc.ExitCode
}

# --- Graft retirement ------------------------------------------------------------------------
# Graft (@nanonets/graft) was installed by the dotfiles until 2026-10-09 and dropped after a
# benchmark showed no accuracy or cost benefit. Invoke-GraftRetirement removes it from a machine
# that has it; the installer and `dot upgrade` call it. Twin of graft_retire in
# scripts/lib/agent-skills.sh - see there for exactly what goes. Only what is unambiguously
# graft's: MCP entries named graft whose command runs graft, the hook/statusLine/allow/footer
# fragments `graft init` writes into the user-level Claude Code and Codex settings, its shims
# and skill, the global npm package, then ~/.graft. Repos you ran `graft init` in keep their own
# graft/ directory and wiring. Quiet when there is nothing to do; never throws.

# True when a JSON value (an MCP server entry) runs graft: one of its strings is the graft
# command (bare, or a path ending in graft / graft.cmd / graft.exe) or the npm package.
function Test-GraftJsonEntry {
    param($Value)
    if ($null -eq $Value) { return $false }
    $json = $Value | ConvertTo-Json -Depth 20 -Compress
    return ($json -match '@nanonets[\\/]+graft' -or $json -match '"(?:[^"]*[\\/])?graft(?:\.cmd|\.exe)?"')
}

# Drop hook entries that run graft-hooks.cjs from a settings object's `hooks` map (Claude Code
# settings.json, Codex hooks.json). An event left with no entries is removed. True if changed.
function Edit-GraftHookEntry {
    param($Root)
    $hooksProp = $Root.PSObject.Properties['hooks']
    if ($null -eq $hooksProp -or $hooksProp.Value -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $changed = $false
    foreach ($hookEvent in @($hooksProp.Value.PSObject.Properties)) {
        $entries = @($hookEvent.Value)
        $kept = @($entries | Where-Object { ($_ | ConvertTo-Json -Depth 20 -Compress) -notmatch 'graft-hooks\.cjs' })
        if ($kept.Count -eq $entries.Count) { continue }
        $changed = $true
        if ($kept.Count -eq 0) { $hooksProp.Value.PSObject.Properties.Remove($hookEvent.Name) }
        else { $hookEvent.Value = $kept }
    }
    if ($changed -and @($hooksProp.Value.PSObject.Properties).Count -eq 0) { $Root.PSObject.Properties.Remove('hooks') }
    return $changed
}

# The rest of what `graft init` puts in a Claude Code settings file: a statusLine that runs
# graft-statusline.cjs, its Bash allow entries and its graft/ footer regex. True if changed.
function Edit-GraftClaudeSetting {
    param($Root)
    $changed = $false
    foreach ($key in @('statusLine', 'subagentStatusLine')) {
        $prop = $Root.PSObject.Properties[$key]
        if ($null -ne $prop -and ($prop.Value | ConvertTo-Json -Depth 10 -Compress) -match 'graft-statusline\.cjs') {
            $Root.PSObject.Properties.Remove($key)
            $changed = $true
        }
    }
    $perm = $Root.PSObject.Properties['permissions']
    if ($null -ne $perm -and $perm.Value -is [System.Management.Automation.PSCustomObject] -and $null -ne $perm.Value.PSObject.Properties['allow']) {
        $allow = @($perm.Value.allow)
        $keep = @($allow | Where-Object { "$_" -notmatch '^Bash\((graft|npx graft|graft-dev)(:|\))' })
        if ($keep.Count -ne $allow.Count) { $perm.Value.allow = $keep; $changed = $true }
    }
    $footer = $Root.PSObject.Properties['footerLinksRegexes']
    if ($null -ne $footer -and $null -ne $footer.Value) {
        $all = @($footer.Value)
        $keep = @($all | Where-Object { "$_" -notlike '*graft/*' })
        if ($keep.Count -ne $all.Count) { $footer.Value = $keep; $changed = $true }
    }
    return $changed
}

# Parse a JSON file that mentions graft, let $Edit change the object (it returns True when it
# did), and write it back BOM-less only then. An unreadable or unparsable file is left alone.
function Edit-GraftJsonFile {
    param([string]$Path, [scriptblock]$Edit)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $raw = [IO.File]::ReadAllText($Path)
        if ($raw -notmatch 'graft') { return $false }
        $root = $raw | ConvertFrom-Json
        if ($root -isnot [System.Management.Automation.PSCustomObject]) { return $false }
        if (-not (& $Edit $root)) { return $false }
        [IO.File]::WriteAllText($Path, ($root | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

function Invoke-GraftRetirement {
    $userHome = Get-SkillsHome
    $done = New-Object System.Collections.Generic.List[string]
    $previous = $ErrorActionPreference
    # PS 5.1 promotes native stderr to a terminating error under Stop; exit codes are the signal.
    $ErrorActionPreference = 'Continue'
    try {
        $removeMcp = {
            param($Root, $Key)
            $map = $Root.PSObject.Properties[$Key]
            if ($null -eq $map -or $map.Value -isnot [System.Management.Automation.PSCustomObject]) { return $false }
            $entry = $map.Value.PSObject.Properties['graft']
            if ($null -eq $entry -or -not (Test-GraftJsonEntry $entry.Value)) { return $false }
            $map.Value.PSObject.Properties.Remove('graft')
            return $true
        }
        if (Edit-GraftJsonFile -Path (Join-Path $userHome '.config\opencode\opencode.json') -Edit { param($r) & $removeMcp $r 'mcp' }) { $done.Add('OpenCode-MCP') }
        if (Edit-GraftJsonFile -Path (Join-Path $userHome '.gemini\config\mcp_config.json') -Edit { param($r) & $removeMcp $r 'mcpServers' }) { $done.Add('agy-MCP') }
        if (Edit-GraftJsonFile -Path (Join-Path $userHome '.claude\settings.json') -Edit {
                param($r)
                $hooksChanged = Edit-GraftHookEntry $r
                $otherChanged = Edit-GraftClaudeSetting $r
                $hooksChanged -or $otherChanged
            }) { $done.Add('Claude-hooks') }
        if (Edit-GraftJsonFile -Path (Join-Path $userHome '.codex\hooks.json') -Edit { param($r) Edit-GraftHookEntry $r }) { $done.Add('Codex-hooks') }

        $codexToml = Join-Path $userHome '.codex\config.toml'
        if ((Get-Command codex -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $codexToml) -and
            (Select-String -LiteralPath $codexToml -Pattern '^\[mcp_servers\.graft\]' -Quiet)) {
            try { & codex mcp remove graft *> $null; if ($LASTEXITCODE -eq 0) { $done.Add('Codex-MCP') } } catch { Write-Verbose "codex mcp remove graft: $($_.Exception.Message)" }
        }
        $claudeJson = Join-Path $userHome '.claude.json'
        if ((Get-Command claude -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $claudeJson) -and
            (Select-String -LiteralPath $claudeJson -Pattern '@nanonets/graft|"command": *"graft"' -Quiet)) {
            try { & claude mcp remove graft -s user *> $null; if ($LASTEXITCODE -eq 0) { $done.Add('Claude-MCP') } } catch { Write-Verbose "claude mcp remove graft: $($_.Exception.Message)" }
        }

        foreach ($relative in @('.claude\skills\graft', '.agents\skills\graft', '.gemini\skills\graft', '.gemini\antigravity-cli\skills\graft')) {
            $skill = Join-Path $userHome $relative
            $skillMd = Join-Path $skill 'SKILL.md'
            if ((Test-Path -LiteralPath $skillMd -PathType Leaf) -and (Select-String -LiteralPath $skillMd -Pattern '^name:\s*graft\s*$' -Quiet)) {
                Remove-Item -LiteralPath $skill -Recurse -Force -ErrorAction SilentlyContinue
                $done.Add("skill($relative)")
            }
        }
        $shims = @(@('.claude\helpers\graft-hooks.cjs', '.claude\helpers\graft-statusline.cjs', '.codex\hooks\graft') |
            ForEach-Object { Join-Path $userHome $_ } | Where-Object { Test-Path -LiteralPath $_ })
        if ($shims.Count -gt 0) {
            foreach ($shim in $shims) { Remove-Item -LiteralPath $shim -Recurse -Force -ErrorAction SilentlyContinue }
            $done.Add('hook-shims')
        }

        # The package: in the prefix the graft command lives in, else npm's default one.
        $graftCmd = Get-Command graft -ErrorAction SilentlyContinue
        $stateDir = Join-Path $userHome '.graft'
        if ((Get-Command npm -ErrorAction SilentlyContinue) -and ($graftCmd -or (Test-Path -LiteralPath $stateDir))) {
            # Windows layout: the command shim sits in the prefix, the package in <prefix>\node_modules.
            $nodeModules = ''
            $prefixArgs = @()
            if ($graftCmd -and $graftCmd.Source) {
                $shimDir = Split-Path -Parent $graftCmd.Source
                $candidate = Join-Path $shimDir 'node_modules'
                if (Test-Path -LiteralPath (Join-Path $candidate '@nanonets\graft')) { $nodeModules = $candidate; $prefixArgs = @('--prefix', $shimDir) }
            }
            if (-not $nodeModules) { try { $nodeModules = (& npm root -g 2>$null | Out-String).Trim() } catch { $nodeModules = '' } }
            $pkg = if ($nodeModules) { Join-Path $nodeModules '@nanonets\graft' } else { '' }
            if ($pkg -and (Test-Path -LiteralPath $pkg)) {
                $npmOutput = @(& npm uninstall -g @prefixArgs '@nanonets/graft' --loglevel=error 2>&1)
                if (Test-Path -LiteralPath $pkg) {
                    foreach ($line in $npmOutput) { Write-Host "    $line" }
                    Write-Host "  Warning: could not uninstall Graft (a running agent session may hold its files) - close agent sessions and re-run dot upgrade, or: npm uninstall -g @nanonets/graft" -ForegroundColor Yellow
                } else {
                    $done.Add('npm-package')
                }
            }
            # graft's own state (telemetry id, update check): only once the package is gone.
            if ($pkg -and -not (Test-Path -LiteralPath $pkg) -and (Test-Path -LiteralPath $stateDir)) {
                Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue
                $done.Add('~/.graft')
            }
        }
    } catch {
        Write-Host "  Warning: Graft retirement did not finish - $($_.Exception.Message)" -ForegroundColor Yellow
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($done.Count -gt 0) { Write-Host "  Retired Graft (dropped from the dotfiles): $($done -join ' ')" -ForegroundColor Green }
}

#-------------------------------------------------------------------------------
# Superpowers per harness - the PowerShell twins of codex_superpowers_installed_version,
# opencode_superpowers_refresh and friends in scripts/lib/agent-skills.sh.
# tests/superpowers_refresh_contract.sh executes both sets against the same stubs.
#-------------------------------------------------------------------------------

# A native command's lines under $ErrorActionPreference = 'Stop' (Windows PowerShell 5.1 turns
# its stderr into a terminating error): preference relaxed for the call, stderr dropped, strings
# out, nothing when the command is absent or fails.
function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments)
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { return @() }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return @(& $Command @Arguments 2>$null | ForEach-Object { "$_" }) } catch { return @() } finally { $ErrorActionPreference = $previous }
}

# The superpowers row of `codex plugin list`: `superpowers@<marketplace>  <status>  <version>
# <source>`, <status> being "installed, enabled", "installed, disabled" or "not installed".
# $null when no marketplace lists the plugin.
function Get-CodexSuperpowersRow {
    foreach ($row in (Invoke-NativeCommand -Command codex -Arguments @('plugin', 'list'))) {
        $m = [regex]::Match($row, '^superpowers@(\S+)\s+(installed(,\s*[a-z]+)?|not installed)\s+(\S+)')
        if ($m.Success) {
            return [pscustomobject]@{
                Marketplace = $m.Groups[1].Value
                Installed   = ($m.Groups[2].Value -notlike 'not *')
                Version     = $m.Groups[4].Value
            }
        }
    }
    return $null
}

# The installed version ('' when codex says "not installed" or lists no row). `dot up` reads it
# before `codex plugin add`: re-adding an installed plugin re-fetches it (an upgrade).
# The newest superpowers version in Codex's plugin cache ($CODEX_HOME or ~/.codex, then
# plugins\cache\<marketplace>\superpowers\<version>\ with a .codex-plugin manifest inside - the path
# `codex plugin add` prints as "Installed plugin root"); '' when nothing is cached. Twin of
# codex_superpowers_cached_version. -CodexHome is for tests.
function Get-CodexSuperpowersCachedVersion {
    param([string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }))
    $cache = Join-Path (Join-Path $CodexHome 'plugins') 'cache'
    if (-not (Test-Path -LiteralPath $cache)) { return '' }
    $versions = @()
    foreach ($m in @(Get-ChildItem -LiteralPath $cache -Directory -ErrorAction SilentlyContinue)) {
        $sp = Join-Path $m.FullName 'superpowers'
        if (-not (Test-Path -LiteralPath $sp)) { continue }
        foreach ($v in @(Get-ChildItem -LiteralPath $sp -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path -LiteralPath (Join-Path $v.FullName '.codex-plugin'))) { continue }
            $name = ($v.Name -split '-')[0]
            if ($name -match '^\d+\.\d+(\.\d+)?$') { $versions += $name }
        }
    }
    if ($versions.Count -eq 0) { return '' }
    return [string](@($versions | Sort-Object { [version]$_ }) | Select-Object -Last 1)
}
# The cache first: `codex plugin list` asks OpenAI's backend and took 19 s on a WSL `dot up`
# (2026-10-12). The CLI decides only when nothing is cached.
function Get-CodexSuperpowersInstalledVersion {
    param([string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }))
    $cached = Get-CodexSuperpowersCachedVersion -CodexHome $CodexHome
    if ($cached) { return $cached }
    $row = Get-CodexSuperpowersRow
    if ($row -and $row.Installed) { return [string]$row.Version }
    return ''
}

# The version the marketplace offers, installed or not ('' when none lists it).
function Get-CodexSuperpowersCatalogVersion {
    $row = Get-CodexSuperpowersRow
    if ($row) { return [string]$row.Version }
    return ''
}

# $true when agy lists superpowers among its imported plugins (`agy plugin list` prints a JSON
# document with an "imports" array of {"name": ...}).
function Test-AgySuperpowersInstalled {
    $text = (Invoke-NativeCommand -Command agy -Arguments @('plugin', 'list')) -join "`n"
    return [bool]($text -match '"name":\s*"superpowers"')
}

# The version of the plugin agy installed, from the plugin.json under its plugin store (best
# effort: the store moved once already, so every ~\.gemini\*\plugins\superpowers is tried).
function Get-AntigravitySuperpowersVersion {
    $gemini = Join-Path (Get-SkillsHome) '.gemini'
    $candidates = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $gemini -Directory -ErrorAction SilentlyContinue)) {
        $candidates += Join-Path (Join-Path (Join-Path (Join-Path $d.FullName 'plugins') 'superpowers') '.claude-plugin') 'plugin.json'
    }
    $candidates += Join-Path (Join-Path (Join-Path (Join-Path $gemini 'plugins') 'superpowers') '.claude-plugin') 'plugin.json'
    foreach ($f in $candidates) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $json = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            if ($json.PSObject.Properties['version']) { return [string]$json.version }
        } catch { Write-Verbose "unreadable plugin.json: $f" }
    }
    return ''
}

# The newest release-looking tag of a GitHub repo (X.Y or X.Y.Z after dropping a "<name>-"
# and/or "v" prefix: v7.0.0, lychee-v0.24.2, 0.20.1), via one `git ls-remote` - no API quota,
# the same proxy git itself uses. '' when unreachable.
function Get-GitHubLatestTag {
    param([string]$Repo)
    $versions = @()
    foreach ($line in (Invoke-NativeCommand -Command git -Arguments @('ls-remote', '--tags', '--refs', "https://github.com/$Repo.git"))) {
        $tag = ($line -replace '^.*refs/tags/', '') -replace '^[A-Za-z_-]*-?v?', ''
        if ($tag -match '^\d+\.\d+(\.\d+)?$') { $versions += $tag }
    }
    if ($versions.Count -eq 0) { return '' }
    return [string](@($versions | Sort-Object { [version]$_ }) | Select-Object -Last 1)
}

function Get-SuperpowersLatestVersion { return (Get-GitHubLatestTag -Repo 'obra/superpowers') }
# Asked once per process and reused by every Superpowers outcome line and the report (a background
# copy of update_ai_tools.ps1 - scripts/lib/ps-background.ps1 - has none of the main script's
# variables, so the cache lives here, not in a script variable).
$script:SuperpowersLatestVersionCache = $null
function Get-SuperpowersLatestVersionCached {
    if ($null -eq $script:SuperpowersLatestVersionCache) { $script:SuperpowersLatestVersionCache = [string](Get-SuperpowersLatestVersion) }
    return $script:SuperpowersLatestVersionCache
}

# Where OpenCode keeps the superpowers plugin it actually loads. For every `plugin` entry in
# opencode.json OpenCode installs the package into its OWN cache, <cache>\packages\<name>@<spec>\
# (package.json + lockfile + node_modules), on the first start that sees the entry, and reuses
# that directory for as long as it exists - a git spec is resolved once and pinned by the
# lockfile from then on. Nothing under ~\.config\opencode is consulted for it: the
# `npm install --prefix ~\.config\opencode` the updaters ran until 2026-10-10 refreshed a tree
# OpenCode never read. The spec is part of the path, separators included, so this is a search
# a few levels deep, not a glob. One path per directory (normally one); none before OpenCode's
# first start.
function Get-OpenCodeSuperpowersCacheDir {
    $roots = @()
    if ($env:XDG_CACHE_HOME) { $roots += Join-Path $env:XDG_CACHE_HOME 'opencode' }
    $roots += Join-Path (Join-Path (Get-SkillsHome) '.cache') 'opencode'
    if ($env:LOCALAPPDATA) { $roots += Join-Path (Join-Path $env:LOCALAPPDATA 'opencode') 'cache' }
    $dirs = @()
    foreach ($root in $roots) {
        $packages = Join-Path $root 'packages'
        if (-not (Test-Path -LiteralPath $packages)) { continue }
        $files = @(Get-ChildItem -LiteralPath $packages -Recurse -Depth 5 -File -Filter 'package.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like '*superpowers@*' -and $_.FullName -notlike '*node_modules*' })
        foreach ($f in $files) { if ($dirs -notcontains $f.DirectoryName) { $dirs += $f.DirectoryName } }
    }
    return @($dirs | Sort-Object)
}

# The Windows installer points opencode.json at a PATH install instead of a git spec (the git
# spec has documented OpenCode/Windows issues: Bun not finding git.exe, cache-path bugs), kept
# current with `npm install --prefix ~\.config\opencode`. That is the copy OpenCode loads there.
function Get-OpenCodeSuperpowersPathInstall {
    $dir = Join-Path (Join-Path (Join-Path (Join-Path (Get-SkillsHome) '.config') 'opencode') 'node_modules') 'superpowers'
    if (Test-Path -LiteralPath (Join-Path $dir 'package.json')) { return $dir }
    return ''
}

# The version OpenCode loads: the first cache directory, else the Windows path install ('' when
# neither exists).
function Get-OpenCodeSuperpowersVersion {
    $dir = @(Get-OpenCodeSuperpowersCacheDir) | Select-Object -First 1
    $f = ''
    if ($dir) { $f = Join-Path (Join-Path (Join-Path $dir 'node_modules') 'superpowers') 'package.json' }
    elseif (Get-OpenCodeSuperpowersPathInstall) { $f = Join-Path (Get-OpenCodeSuperpowersPathInstall) 'package.json' }
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { return '' }
    try {
        $json = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        if ($json.PSObject.Properties['version']) { return [string]$json.version }
    } catch { Write-Verbose "unreadable plugin.json: $f" }
    return ''
}

# Re-resolve the git dependency in every cache directory to upstream HEAD, in place: npm rewrites
# the lockfile and node_modules there, and OpenCode's next start loads the new copy.
# --ignore-scripts as OpenCode's own installer (@npmcli/arborist, ignoreScripts: true) does.
# $false when any directory failed; npm's own output is shown only then.
function Invoke-OpenCodeSuperpowersRefresh {
    $ok = $true
    foreach ($dir in @(Get-OpenCodeSuperpowersCacheDir)) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = @(& npm install --prefix $dir 'superpowers@github:obra/superpowers' --ignore-scripts --allow-git=all --loglevel=error --no-progress --fund=false --audit=false 2>&1 | ForEach-Object { "$_" })
            if ($LASTEXITCODE -ne 0) { $out | ForEach-Object { Write-Host "    $_" }; $ok = $false }
        } catch {
            Write-Host "    $($_.Exception.Message)"
            $ok = $false
        } finally {
            $ErrorActionPreference = $previous
        }
    }
    return $ok
}

# $true when a COMPLETE Playwright Chromium build is in its browser cache (PLAYWRIGHT_BROWSERS_PATH
# unless it is the literal "0", else %LOCALAPPDATA%\ms-playwright - ~\.cache\ms-playwright where
# LOCALAPPDATA is unset). Playwright marks a finished download with an INSTALLATION_COMPLETE file;
# a chromium-* directory without it is an interrupted one and must install again. `dot up` reads
# this before `npx playwright install`, which re-ran on every apply.
function Test-PlaywrightChromiumInstalled {
    $roots = @()
    if ($env:PLAYWRIGHT_BROWSERS_PATH -and $env:PLAYWRIGHT_BROWSERS_PATH -ne '0') {
        $roots += $env:PLAYWRIGHT_BROWSERS_PATH
    } else {
        if ($env:LOCALAPPDATA) { $roots += Join-Path $env:LOCALAPPDATA 'ms-playwright' }
        $roots += Join-Path (Join-Path (Get-SkillsHome) '.cache') 'ms-playwright'
    }
    foreach ($root in $roots) {
        $complete = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'chromium-*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'INSTALLATION_COMPLETE') })
        if ($complete.Count -gt 0) { return $true }
    }
    return $false
}

# One object per superpowers install Claude Code knows of (`claude plugin list --json`), the
# user-scope one included: Version, Scope, ProjectPath. Project- and local-scope installs are per
# repository and `claude plugin update` run elsewhere never touches them.
# Agent config probes (twins of claude_marketplace_known / claude_plugin_installed /
# mcp_registered in scripts/lib/agent-skills.sh): answers from the agents' own files instead of
# CLI round-trips - a no-op run paid `claude plugin install` and the `mcp get` probes every time
# (2026-10-11). $true / $false, or $null when the file is missing or unreadable: the caller then
# runs the CLI as before. -UserHome is for tests; it defaults to this user's home.
function Get-ClaudePluginsDir {
    param([string]$UserHome = $HOME)
    if ($env:CLAUDE_CONFIG_DIR) { return (Join-Path $env:CLAUDE_CONFIG_DIR 'plugins') }
    return (Join-Path (Join-Path $UserHome '.claude') 'plugins')
}
function Read-JsonFileOrNull {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) } catch { return $null }
}
function Test-ClaudeMarketplaceKnown {
    param([Parameter(Mandatory)][string]$Name, [string]$UserHome = $HOME)
    $d = Read-JsonFileOrNull -Path (Join-Path (Get-ClaudePluginsDir -UserHome $UserHome) 'known_marketplaces.json')
    if ($null -eq $d) { return $null }
    return [bool]($d.PSObject.Properties[$Name])
}
function Test-ClaudePluginInstalled {
    param([Parameter(Mandatory)][string]$Id, [string]$UserHome = $HOME)
    $d = Read-JsonFileOrNull -Path (Join-Path (Get-ClaudePluginsDir -UserHome $UserHome) 'installed_plugins.json')
    if ($null -eq $d) { return $null }
    # {"version": 2, "plugins": {...}} today; a flat {id: entries} before that. An entry is one
    # object or a list of them (one per scope/project); only USER scope counts as installed.
    $plugins = if ($d.PSObject.Properties['plugins']) { $d.plugins } else { $d }
    if (-not $plugins.PSObject.Properties[$Id]) { return $false }
    foreach ($e in @($plugins.$Id)) {
        if ($e.PSObject.Properties['scope'] -and [string]$e.scope -eq 'user') { return $true }
    }
    return $false
}
function Test-McpRegistered {
    param([Parameter(Mandatory)][ValidateSet('claude', 'codex')][string]$Agent,
          [Parameter(Mandatory)][string]$Server, [string]$UserHome = $HOME)
    if ($Agent -eq 'claude') {
        $f = if ($env:CLAUDE_CONFIG_DIR) { Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json' } else { Join-Path $UserHome '.claude.json' }
        $d = Read-JsonFileOrNull -Path $f
        if ($null -eq $d) { return $null }
        if (-not $d.PSObject.Properties['mcpServers']) { return $false }
        return [bool]($d.mcpServers.PSObject.Properties[$Server])
    }
    $f = if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'config.toml' } else { Join-Path (Join-Path $UserHome '.codex') 'config.toml' }
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $pattern = '^\[mcp_servers\."?' + [regex]::Escape($Server) + '"?\]'
    return [bool](Select-String -LiteralPath $f -Pattern $pattern -Quiet)
}

# $null signals the lookup itself failed (claude missing, a non-zero exit, invalid JSON, or a
# hang) - the caller must not read that the same as a genuinely empty list ("not installed").
# Twin of claude_superpowers_installs in scripts/lib/agent-skills.sh, which already made this
# distinction and already bounds the call at 60s via net_timeout_tty (2026-10-11: a hung
# `claude plugin list --json` read as "not installed" on a box with a real user-scope install,
# and separately sat blocked in state T for 17+ minutes under a plain `timeout` wrapper - SIGTTIN
# stopping a background-process-group command that still touches the tty). This Windows copy
# caught up on the first distinction in #380, but shipped with no bound on the call at all - a
# `dot upgrade --yes` on 2026-10-11 Windows logged a Claude Code "lookup failed" (rather than
# hanging the whole run), proving this call CAN return quickly, but nothing capped it if it
# didn't: the printed message already claimed "or timed out" for a timeout that did not exist
# yet. A background job, not a plain Process.Start, because `claude` can resolve to a .ps1 (this
# file's own test stub) as readily as an npm .cmd shim, and only PowerShell's own command
# resolution (which a job's script block gets, same as `&` in the foreground) handles both.
# The file first (Get-ClaudeSuperpowersInstallFromFile): Claude writes every install there with its
# version, scope and projectPath, so the answer is instant and the CLI is asked only when the file
# cannot say. -UserHome is for tests; it defaults to this user's home.
function Get-ClaudeSuperpowersInstallFromFile {
    param([string]$UserHome = $HOME)
    $d = Read-JsonFileOrNull -Path (Join-Path (Get-ClaudePluginsDir -UserHome $UserHome) 'installed_plugins.json')
    if ($null -eq $d) { return $null }
    $plugins = if ($d.PSObject.Properties['plugins']) { $d.plugins } else { $d }
    if ($null -eq $plugins -or $plugins -isnot [pscustomobject]) { return $null }
    $out = @()
    foreach ($prop in $plugins.PSObject.Properties) {
        if ($prop.Name -notlike 'superpowers@*') { continue }
        foreach ($e in @($prop.Value)) {
            if ($null -eq $e) { continue }
            $version = ''; if ($e.PSObject.Properties['version']) { $version = [string]$e.version }
            $scope = ''; if ($e.PSObject.Properties['scope']) { $scope = [string]$e.scope }
            $project = ''; if ($e.PSObject.Properties['projectPath']) { $project = [string]$e.projectPath }
            $out += [pscustomobject]@{ Version = $version; Scope = $scope; ProjectPath = $project }
        }
    }
    return $out
}
# Get-ClaudeSuperpowersUserVersion - the user-scope install's version (the one `dot upgrade`
# updates); '' when there is none or the lookup failed.
function Get-ClaudeSuperpowersUserVersion {
    param([string]$UserHome = $HOME)
    $installs = Get-ClaudeSuperpowersInstall -UserHome $UserHome
    if ($null -eq $installs) { return '' }
    foreach ($i in @($installs)) { if ($i.Scope -eq 'user') { return [string]$i.Version } }
    return ''
}
function Get-ClaudeSuperpowersInstall {
    param([int]$TimeoutSeconds = 60, [string]$UserHome = $HOME)
    $fromFile = Get-ClaudeSuperpowersInstallFromFile -UserHome $UserHome
    if ($null -ne $fromFile) { return @($fromFile) }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { return $null }
    $job = Start-Job -ScriptBlock {
        $ErrorActionPreference = 'Continue'
        # A script command that falls off the end without an explicit `exit` never touches
        # $LASTEXITCODE at all (it stays whatever it was, or - under Set-StrictMode - unset): reset
        # it first so a well-behaved success is never mistaken for "never ran".
        $global:LASTEXITCODE = 0
        $out = ((& claude plugin list --json 2>$null) | ForEach-Object { "$_" }) -join "`n"
        [pscustomobject]@{ Text = $out; ExitCode = $LASTEXITCODE }
    }
    $text = ''
    try {
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            return $null
        }
        $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
        if ($null -eq $result -or $result.ExitCode -ne 0) { return $null }
        $text = [string]$result.Text
    } catch { return $null } finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    if (-not $text.Trim()) { return @() }
    try { $items = @($text | ConvertFrom-Json) } catch { return $null }
    $out = @()
    foreach ($item in $items) {
        if (-not $item.PSObject.Properties['id'] -or ([string]$item.id) -notlike 'superpowers@*') { continue }
        $version = ''; if ($item.PSObject.Properties['version']) { $version = [string]$item.version }
        $scope = ''; if ($item.PSObject.Properties['scope']) { $scope = [string]$item.scope }
        $project = ''; if ($item.PSObject.Properties['projectPath']) { $project = [string]$item.projectPath }
        $out += [pscustomobject]@{ Version = $version; Scope = $scope; ProjectPath = $project }
    }
    return $out
}

# The outcome line under an "Updating Superpowers (<harness>)..." header (twin of
# superpowers_refresh_line): "is current (v)", "is v (upstream unreachable)", or "is v - <Behind>".
# No version known: '' (the caller prints nothing).
function Format-SuperpowersRefreshLine {
    param([string]$Harness, [string]$Version, [string]$Upstream, [string]$Behind = '')
    if (-not $Version) { return '' }
    if (-not $Upstream) { return "  Superpowers ($Harness) is $Version (upstream unreachable)" }
    if ($Version -eq $Upstream) { return "  Superpowers ($Harness) is current ($Version)" }
    return "  Superpowers ($Harness) is $Version - $Behind"
}

# One report line (twin of superpowers_version_line): a version equal to upstream is "current";
# an older one says "behind upstream vX" plus the note; '' reads as "not installed"; no upstream
# cannot judge.
function Format-SuperpowersVersionLine {
    param([string]$Harness, [string]$Version, [string]$Upstream, [string]$Note = '')
    if (-not $Version) { return "   ${Harness}: not installed" }
    if (-not $Upstream) { return "   ${Harness}: $Version (upstream unreachable)" }
    if ($Version -eq $Upstream) { return "   ${Harness}: $Version (current)" }
    $suffix = ''
    if ($Note) { $suffix = " ($Note)" }
    return "   ${Harness}: $Version - behind upstream v$Upstream$suffix"
}

# Superpowers per harness against upstream's latest release (twin of superpowers_report). Four
# install mechanisms are four ways to fall behind while every update step reports success.
# Read-only; every lookup degrades to "unknown" offline.
function Write-SuperpowersReport {
    param([string]$Glyph = '*', [string]$Upstream)
    # -Upstream: the caller already asked (the Claude Code step does); unset asks here.
    $upstream = if ($PSBoundParameters.ContainsKey('Upstream')) { $Upstream } else { Get-SuperpowersLatestVersion }
    $label = 'unreachable'
    if ($upstream) { $label = "v$upstream" }
    Write-Host "$Glyph Superpowers versions (upstream: ${label}):" -ForegroundColor Yellow
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        $installs = Get-ClaudeSuperpowersInstall
        if ($null -eq $installs) {
            Write-Host "   Claude Code: lookup failed (claude plugin list --json errored or timed out - re-run dot upgrade)"
        } else {
            $user = ''
            $stale = @()
            $gone = @()
            foreach ($i in @($installs)) {
                if ($i.Scope -eq 'user') { $user = $i.Version }
                # a deleted worktree leaves its install behind; "update inside each" cannot be followed there
                elseif ($i.ProjectPath -and -not (Test-Path -LiteralPath $i.ProjectPath)) { $gone += "$($i.Version) ($($i.Scope)) in $($i.ProjectPath)" }
                elseif ($upstream -and $i.Version -ne $upstream) { $stale += "$($i.Version) ($($i.Scope)) in $($i.ProjectPath)" }
            }
            Write-Host (Format-SuperpowersVersionLine -Harness 'Claude Code' -Version $user -Upstream $upstream -Note 're-run dot upgrade')
            if ($stale.Count -gt 0) { Write-Host "     project/local-scope installs behind: $($stale -join ', ') - inside each: 'claude plugin update superpowers@superpowers-marketplace', or 'claude plugin uninstall superpowers@superpowers-marketplace --scope <scope>' so the user-scope install applies" }
            if ($gone.Count -gt 0) { Write-Host "     stale installs (directory gone): $($gone -join ', ') - recreate the directory, run 'claude plugin uninstall superpowers@superpowers-marketplace --scope <scope>' inside it, then delete it" }
        }
    }
    if (Get-Command opencode -ErrorAction SilentlyContinue) {
        Write-Host (Format-SuperpowersVersionLine -Harness 'OpenCode' -Version (Get-OpenCodeSuperpowersVersion) -Upstream $upstream -Note 're-run dot upgrade')
    }
    if (Get-Command agy -ErrorAction SilentlyContinue) {
        Write-Host (Format-SuperpowersVersionLine -Harness 'Antigravity' -Version (Get-AntigravitySuperpowersVersion) -Upstream $upstream -Note 're-run dot upgrade')
    }
    if (Get-Command codex -ErrorAction SilentlyContinue) {
        $row = Get-CodexSuperpowersRow
        $installed = ''
        $catalog = ''
        if ($row) { $catalog = [string]$row.Version; if ($row.Installed) { $installed = [string]$row.Version } }
        # Codex installs only from a marketplace: when the catalog itself is behind upstream there
        # is nothing `codex plugin add` could fetch, and nothing for the dotfiles to do.
        # That is not a problem to act on, so it prints as "latest there", not as "behind".
        if ($catalog -and $installed -eq $catalog -and $upstream -and $installed -ne $upstream) {
            Write-Host "   Codex: $installed (marketplace latest - upstream v$upstream is not published there yet)"
        } else {
            $offer = 'nothing'; if ($catalog) { $offer = $catalog }
            Write-Host (Format-SuperpowersVersionLine -Harness 'Codex' -Version $installed -Upstream $upstream -Note "the marketplace offers $offer; re-run dot upgrade")
        }
    }
}
