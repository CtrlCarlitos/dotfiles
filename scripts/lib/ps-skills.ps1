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

function Test-SkillsUpToDate {
    param([string]$Repo, [string[]]$Skills, [string[]]$Agents)

    $script:SkillsPendingKey = "$Repo|$($Skills -join ' ')|$($Agents -join ' ')"
    $script:SkillsPendingHead = Get-SkillsRemoteHead -Repo $Repo
    if ($env:DOT_SKILLS_FORCE -eq '1') { return $false }
    foreach ($skill in $Skills) {
        if (-not (Test-Path -LiteralPath (Join-Path (Get-SkillsHome) ".claude\skills\$skill\SKILL.md") -PathType Leaf)) { return $false }
        if (-not (Test-Path -LiteralPath (Join-Path (Get-SkillsHome) ".agents\skills\$skill\SKILL.md") -PathType Leaf)) { return $false }
    }
    if (-not $script:SkillsPendingHead) { return $false }
    $state = Get-SkillsSourceStatePath
    if (-not (Test-Path -LiteralPath $state -PathType Leaf)) { return $false }
    foreach ($line in @(Get-Content -LiteralPath $state)) {
        $parts = $line -split "`t"
        if ($parts.Count -eq 2 -and $parts[0] -ceq $script:SkillsPendingKey) {
            return ($parts[1] -ceq $script:SkillsPendingHead)
        }
    }
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
        Write-Host "  ${Label}: installed"
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
