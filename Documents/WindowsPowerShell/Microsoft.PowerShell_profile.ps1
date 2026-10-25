#-------------------------------------------------------------------------------
# Modern Tools Initialization
#-------------------------------------------------------------------------------
# starship/zoxide emit shell code that is designed to be eval'd - there is no
# non-iex integration. PSSA suppression is scoped to this wrapper so the rule
# stays live everywhere else.
function Initialize-ModernTool {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'starship/zoxide init output is designed to be eval-ed')]
    param([string]$InitScript)
    Invoke-Expression $InitScript
}
# Starship
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Initialize-ModernTool (&starship init powershell)
}

# Windows Terminal cwd reporting (OSC 9;9) - twin of the PowerShell 7
# profile's block: duplicate panes/tabs and the agent splits open here.
if ($env:WT_SESSION) {
    function Invoke-Starship-PreCommand {
        if ($PWD.Provider.Name -eq 'FileSystem') {
            $host.UI.Write("$([char]27)]9;9;`"$($PWD.ProviderPath)`"$([char]27)\")
        }
    }
}

# Zoxide
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Initialize-ModernTool (&zoxide init powershell | Out-String)
}

# Direnv: deliberately NOT initialized on Windows. Confirmed live on a
# real machine: with the hook installed, plain directory navigation
# triggered frequent "Select an app to open" ShellExecute popups the
# operator cannot dismiss permanently - and direnv isn't used on the
# Windows side anyway (the zsh/dot_zshrc hook covers WSL). The binary
# stays installed; nothing initializes it here, and starship's direnv
# module is disabled in starship.toml so nothing else spawns it either.

#-------------------------------------------------------------------------------
# OpenCode TUI clipboard - twin of the PowerShell 7 profile's block.
#-------------------------------------------------------------------------------
# Upstream's experimental flag (verified against 1.18.33: the binary parses
# "true"/"1" as its only truthy spellings and treats UNSET as true). Set to
# "false", highlighting a selection copies it on mouse-release with a "Copied
# to clipboard" toast - the same highlight-copies contract as Windows
# Terminal's copyOnSelect and VS Code's copyOnSelection. Unset, opencode
# keeps right-click-to-copy instead. Restart opencode after changing this.
$env:OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT = 'false'

#-------------------------------------------------------------------------------
# Chocolatey - lazy on purpose (twin of the PowerShell 7 profile's block).
# Importing chocolateyProfile (tab completion, refreshenv) measured ~320 ms on
# every shell start, and it only matters once you actually type `choco`. The
# first call imports the module globally, removes this shim, and forwards to
# the real exe - after that, `choco` and `refreshenv` behave stock. Until the
# first call there is no choco tab completion and no refreshenv; that is the
# trade. The variable is named $ChocolateyProfile on purpose: Chocolatey's setup
# (the install and every `choco upgrade chocolatey`) appends its eager block to
# $PROFILE unless that exact string is already in the file, and the appended
# block made the next `dot up` ask "has changed since chezmoi last wrote it?".
#-------------------------------------------------------------------------------
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path $ChocolateyProfile) {
    function choco {
        Remove-Item function:choco -ErrorAction SilentlyContinue
        Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1" -Global
        & "$env:ChocolateyInstall\choco.exe" @args
    }
}

#-------------------------------------------------------------------------------
# Aliases & Modern Tools
#-------------------------------------------------------------------------------
if (Get-Command eza -ErrorAction SilentlyContinue) {
    Set-Alias -Name ls -Value eza -Option AllScope -Force
    function ll { eza -l --icons --group-directories-first $args }
    function la { eza -la --icons --group-directories-first $args }
}

if (Get-Command bat -ErrorAction SilentlyContinue) {
    Set-Alias -Name cat -Value bat -Option AllScope -Force
}

if (Get-Command nvim -ErrorAction SilentlyContinue) {
    Set-Alias -Name vim -Value nvim -Option AllScope -Force
    Set-Alias -Name v -Value nvim -Option AllScope -Force
}

# OMZ-style Git Aliases
function gst { git status $args }
function gd { git diff $args }
function gl { git pull $args }
function gp { git push $args }
function gco { git checkout $args }
function ga { git add $args }
function gcam { git commit -am $args }
function gb { git branch $args }

# Cross-shell parity with dot_aliases.zsh - the portable subset (see the
# comment on the dot/dp block below for the source-of-truth rule).
# Deliberately NOT ported: `ni` (collides with pwsh's built-in New-Item
# alias), `ps`->procs and `top`->htop (would shadow Get-Process / need a
# TUI Windows doesn't have), the rm/mv/cp -i safety wrappers (pwsh prompts
# differently by design), and `vi` is added below rather than shadowing
# anything. `cd -` is pwsh 7-only - 5.1 has no `-` alias; use the
# `..`/`...`/`....` helpers below.
if (Get-Command eza -ErrorAction SilentlyContinue) {
    function lt { eza --tree --icons --level 2 @args }
    function lta { eza --tree --icons --level 2 -a @args }
}
if (Get-Command nvim -ErrorAction SilentlyContinue) {
    function vi { nvim @args }
}
function c { Clear-Host }
function h { Get-History @args }
function py { python @args }
function nr { npm run @args }
function nrd { npm run dev }
function nrb { npm run build }
function serve { python -m http.server 8000 }
function ff { Get-ChildItem -Recurse -File -Filter "$args" }
function path { $env:Path -split ';' }
# No `reload`: dot-sourcing $PROFILE inside a function defines everything in
# that function's scope, which is discarded on return. After installing or
# refreshing, restart the terminal instead.
function prof { nvim $PROFILE }
function get { curl.exe -sS @args }
function post { curl.exe -sS -X POST @args }
function devprofiles { devprofile list }
function agy { agy.exe --dangerously-skip-permissions @args }
# Process viewers via pstop (psmux/pstop, Chocolatey "pstop"). The choco
# package ships its own htop.exe shim on PATH, so htop needs NO alias here
# (a profile function would only shadow the real binary). Only top is
# wrapped - it has no shim. `ps` is deliberately left as pwsh's built-in
# Get-Process alias (procs stays available under its own name).
if (Get-Command pstop -ErrorAction SilentlyContinue) {
    function top { pstop @args }
}

# Dotfiles command family (dot CLI). `dot up` syncs
# state and NEVER upgrades (chezmoi update pulls without applying, init
# re-runs the config template on the pulled source - init does not fetch -
# then one apply runs with the fresh config). `dot upgrade` is the
# single upgrade owner (choco sweep + AI tools, live-session gated).
function dot {
    $sub = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
    $rest = @($args | Select-Object -Skip 1)
    $repoScripts = Join-Path $HOME '.local\share\chezmoi\scripts'
    switch ($sub) {
        'up' {
            # Where the time of a dot up goes: the installer prints its own sections, this adds the
            # parts around it (a 3m10s run showed 1m38s of installer timings and nothing for the rest).
            $upClock = [System.Diagnostics.Stopwatch]::StartNew()
            $upLap = 0.0
            $upParts = @()
            $upFormat = { param([double]$s) $w = [int][math]::Floor($s); if ($w -ge 60) { '{0}m{1:00}s' -f [math]::Floor($w / 60), ($w % 60) } else { "${w}s" } }
            # Pull WITHOUT applying, re-run the config template on the pulled source, then ONE
            # apply with the fresh config (applying before init ran the installer twice).
            chezmoi update --apply=false
            $upParts += 'pull ' + (& $upFormat ($upClock.Elapsed.TotalSeconds - $upLap)); $upLap = $upClock.Elapsed.TotalSeconds
            if ($LASTEXITCODE -ne 0) {
                # A feature branch merged (often squashed, as this repo's own PRs are) and
                # auto-deleted upstream leaves `git pull` nothing to merge into it - raw git
                # error, no hint (lived 2026-10-11: feat/mobile-dev's PR #352). fetch.prune
                # (on by default) already marked it [gone] by the time the pull failed.
                # The diagnostic's own `git` calls are native processes too, and would
                # overwrite $LASTEXITCODE with THEIR exit code by the time this returns -
                # save chezmoi's and restore it below, so the caller still sees chezmoi's.
                $updateExitCode = $LASTEXITCODE
                # Chained, not a single '.local\share\chezmoi' literal: Join-Path only applies
                # the current platform's separator between its own two arguments - an embedded
                # backslash in the second one is never reinterpreted as a separator on pwsh/Linux
                # (CI runs this profile's logic through pwsh there to test it for real).
                $src = Join-Path (Join-Path (Join-Path $HOME '.local') 'share') 'chezmoi'
                $curBranch = (git -C $src symbolic-ref --quiet --short HEAD 2>$null)
                $goneLine = (git -C $src status -sb 2>$null | Select-Object -First 1)
                if ($curBranch -and $goneLine -match '\[gone\]') {
                    $defaultBranch = (git -C $src symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null) -replace '^origin/', ''
                    Write-Host "dot up: '$curBranch' tracks a remote branch that's gone - it was likely merged and deleted upstream, so there's nothing left to pull into it." -ForegroundColor Yellow
                    if ($defaultBranch -and $curBranch -ne $defaultBranch) {
                        Write-Host "  Fix: git -C `"$src`" checkout $defaultBranch; git -C `"$src`" pull; git -C `"$src`" branch -D $curBranch" -ForegroundColor Yellow
                    }
                }
                $global:LASTEXITCODE = $updateExitCode
                return
            }
            chezmoi init
            $upParts += 'init ' + (& $upFormat ($upClock.Elapsed.TotalSeconds - $upLap)); $upLap = $upClock.Elapsed.TotalSeconds
            if ($LASTEXITCODE -ne 0) { return }
            chezmoi apply
            $upParts += 'apply ' + (& $upFormat ($upClock.Elapsed.TotalSeconds - $upLap)); $upLap = $upClock.Elapsed.TotalSeconds
            # New installs land in the registry PATH; this session only sees
            # them after a re-read (child installers keep their own PATH).
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            Write-Host ("  dot up took {0}: {1}" -f (& $upFormat $upClock.Elapsed.TotalSeconds), ($upParts -join ', ')) -ForegroundColor DarkGray
        }
        'upgrade'   { & (Join-Path $repoScripts 'dotupgrade.ps1') @rest }
        'backup'    { & (Join-Path $repoScripts 'dotbackup.ps1') @rest }
        'restore'   { & (Join-Path $repoScripts 'dotrestore.ps1') @rest }
        'doctor'    {
            $repair = @($rest | Where-Object { $_ -in '--fix', '-Fix' }).Count -gt 0
            $doctorArgs = @($rest | Where-Object { $_ -notin '--fix', '-Fix' })
            & (Join-Path $repoScripts 'dotfiles-doctor.ps1') -Fix:$repair @doctorArgs
        }
        'remote' { & (Join-Path $repoScripts 'remote-access.ps1') @rest }
        'ssh' { & (Join-Path $repoScripts 'dot-ssh.ps1') @rest }
        'devtmp' { & (Join-Path $repoScripts 'devtmp.ps1') @rest }
        'docker-compact' { & (Join-Path $repoScripts 'docker-compact.ps1') @rest }
        'version' { & (Join-Path $repoScripts 'dotversion.ps1') @rest }
        'ssh-fingerprints' { python (Join-Path $repoScripts 'ssh_fingerprints.py') @rest }
        default {
            $unknown = $sub -ne '' -and $sub -notin @('help', '-h', '--help')
            if ($unknown) {
                Write-Host "dot: unknown command '$sub'"
                Write-Host "  (a command added by a recent 'dot up' needs a new shell: this one loaded an older dot)"
            }
            Write-Host "dot - dotfiles command family"
            Write-Host ("  {0,-20}  {1}" -f 'dot ssh-fingerprints', 'preview agent fingerprint sync (--write to save)')
            Write-Host ("  {0,-20}  {1}" -f 'dot up', 'sync state (pull + apply + config re-init; never upgrades)')
            Write-Host ("  {0,-20}  {1}" -f 'dot upgrade', 'upgrade ALL tooling (choco + AI tools, session-gated)')
            Write-Host ("  {0,-20}  {1}" -f 'dot backup', 'encrypted portable backup')
            Write-Host ("  {0,-20}  {1}" -f 'dot restore', 'restore a backup')
            Write-Host ("  {0,-20}  {1}" -f 'dot doctor', 'dotfiles health check')
            Write-Host ("  {0,-20}  {1}" -f 'dot remote', 'remote-access setup/status/fix')
            Write-Host ("  {0,-20}  {1}" -f 'dot ssh', 'pick an SSH host and connect (--list, or a name)')
            Write-Host ("  {0,-20}  {1}" -f 'dot devtmp', 'build/test output folder for Defender (plan/apply/run)')
            Write-Host ("  {0,-20}  {1}" -f 'dot docker-compact', "shrink Docker Desktop's data disk (stops Docker)")
            Write-Host ("  {0,-20}  {1}" -f 'dot version', 'which version of the dotfiles repo this is')
            if ($unknown) { $global:LASTEXITCODE = 2 }
        }
    }
}

# devprofile switcher (not part of the dot family - kept as-is).
function dp { devprofile @args }

# Navigation - depth semantics match dot_aliases.zsh exactly (.. = 1 up,
# ... = 2 up, .... = 3 up). The old twin had `...` defined twice; the second
# (4-up) definition silently won, so `...` jumped four levels and 2-up was
# unreachable. (`cd -` is pwsh 7-only - it is not available in 5.1.)
function ~ { Set-Location ~ }

# wsl (twin of the PowerShell 7 profile's function): land in the WSL home
# directory instead of the /mnt/c mirror of the Windows cwd - the mirror's
# directory scans are slow (9p + AV) and starship times out on them
# ("Scanning current directory timed out"). Arguments pass through
# (wsl -d <distro> still works); `wsl --cd <dir>` overrides when wanted.
function wsl {
    wsl.exe --cd ~ @args
}

# Predictive IntelliSense (the greyed-out suggestion typed from command
# history) comes for free in pwsh 7.2+ - its own default PSReadLine (>=2.2)
# turns PredictionSource on by itself. Windows PowerShell 5.1 ships the
# ancient 2.0.0 forever and never turns this on even once a newer PSReadLine
# is later installed into the user's own module path (`Install-Module
# PSReadLine -Scope CurrentUser`, which 5.1's console host auto-loads in
# preference to the bundled one - verified directly, 2026-10-24) - it still
# has to be asked for here. Guarded: an old/absent PSReadLine has no
# -PredictionSource parameter at all. try/catch, not a $Host.UI check: that
# property reads true in hosts (this profile sourced non-interactively by
# this repo's own tooling, among others) where the feature still throws
# "doesn't support virtual terminal processing or it's redirected" -
# verified directly, 2026-10-24.
if ((Get-Module PSReadLine) -and (Get-Module PSReadLine).Version -ge [version]'2.2.0') {
    try { Set-PSReadLineOption -PredictionSource History -PredictionViewStyle InlineView -ErrorAction Stop }
    catch { Write-Verbose "PSReadLine prediction not enabled: $($_.Exception.Message)" }
}

# Path-like tokens autocd (twin of the PowerShell 7 profile's block,
# interactive via PSReadLine): PowerShell parses a bare token like
# ~\.local\share\chezmoi as a MODULE spec - "The module '~' could not be
# loaded" - and its command resolution never reaches CommandNotFoundAction
# for separator tokens (verified). The Enter handler rewrites such lines to
# Set-Location before accepting: zsh autocd, scoped to separator-containing
# tokens that exist as directories (no whitespace/quotes), so command typos
# and every other input are accepted unchanged.
if (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Chord Enter -ScriptBlock {
        $line = $null
        $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        $trimmed = $line.Trim()
        if ($trimmed -and $trimmed -notmatch '[\s"'']' -and $trimmed -match '[/\\]') {
            $candidate = if ($trimmed.StartsWith('~')) { Join-Path $HOME $trimmed.Substring(1) } else { $trimmed }
            if (Test-Path -LiteralPath $candidate -PathType Container -ErrorAction SilentlyContinue) {
                # Echoed as a short, honest "cd -LiteralPath '<path>'" line
                # (twin rationale: a silent Set-Location + InvokePrompt
                # re-render was tried and rejected - it re-runs the prompt
                # before its git segment resolves, littering the scrollback
                # with a "?" placeholder line).
                $escaped = $candidate.Replace("'", "''")
                [Microsoft.PowerShell.PSConsoleReadLine]::Delete(0, $line.Length)
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert("cd '$escaped'")
                [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
            }
        }
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }
}
function .. { Set-Location .. }
function ... { Set-Location ..\.. }
function .... { Set-Location ..\..\.. }

# Docker (dc family is the pwsh-native set; docker-clean/stop-all are the
# dot_aliases.zsh pair, mirrored here for full parity)
function d { docker $args }
function dc { docker compose $args }
function dcu { docker compose up -d $args }
function dcd { docker compose down $args }
function dcl { docker compose logs -f $args }
function dcp { docker compose ps $args }
# docker-clean/stop-all keep their dot_aliases.zsh names verbatim - the names
# ARE the cross-shell contract; PSSA's approved-verb rule is suppressed per
# function for exactly these two.
function docker-clean {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'name is alias-parity with dot_aliases.zsh')]
    param()
    docker system prune -af --volumes
}
function docker-stop-all {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'name is alias-parity with dot_aliases.zsh')]
    param()
    docker stop (docker ps -aq) 2>$null
}

# serena-clean (oraios/serena#2122) - twin of the PowerShell 7 profile's
# block: agy leaves serena shim+python trees running after exit; the next
# agy session's /mcp reload fails ("failed to stop mcp instance: serena:
# exit status 1") until they are gone. Close the agent CLIs first, then run
# it.
function serena-clean {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'name is alias-parity with docker-clean')]
    param()
    Get-Process serena -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
        Where-Object { $_.CommandLine -match 'serena' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

# clip-to-file (psmux#719) - twin of the PowerShell 7 profile's block: pastes
# into agent TUIs through psmux arrive as a raw blob, so substantial content
# goes via a file instead. Copies the highlighted text (already on the
# clipboard through copyOnSelect) to a timestamped file, puts the file path
# back on the clipboard, and prints it: in the agent, reference it as @<path>
# (or just paste the path) and the agent reads the content.
function clip-to-file {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'user-facing workflow name (clip-to-file), not an action verb')]
    param()
    $f = Join-Path $env:TEMP ("clip-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".txt")
    Get-Clipboard -Raw | Set-Content -NoNewline $f
    Set-Clipboard $f
    Write-Output $f
}

#-------------------------------------------------------------------------------
# Utilities
#-------------------------------------------------------------------------------
function devprofile {
    # Chezmoi places this in a standard location (e.g. ~/.local/bin or similar if we map it so).
    # For now, let's assume it's in a known scripts directory managed by chezmoi or just a function here.
    # Logic: We should really make devprofile available on PATH.
    # Fallback to local script if installed via dot_local/bin
    $ScriptPath = Join-Path $env:USERPROFILE ".local\bin\devprofile.ps1"
    if (Test-Path $ScriptPath) {
        # Splat: $args as one object[] cannot bind to devprofile.ps1's
        # [string]$Command (every `devprofile <cmd>` failed before the splat).
        & $ScriptPath @args
    } else {
        Write-Host "devprofile.ps1 not found at $ScriptPath" -ForegroundColor Red
    }
}

#-------------------------------------------------------------------------------
# PATH Additions
#-------------------------------------------------------------------------------
$UserNodeModules = Join-Path $env:APPDATA "npm"
if (Test-Path $UserNodeModules) {
    $env:Path = "$UserNodeModules;" + $env:Path
}

$LocalBin = Join-Path $env:USERPROFILE ".local\bin"
if (Test-Path $LocalBin) {
    if ($env:Path -notlike "*$LocalBin*") {
        $env:Path = "$LocalBin;" + $env:Path
    }
}

#-------------------------------------------------------------------------------
# SSH agent - top up with declared identities not already loaded
#-------------------------------------------------------------------------------
# Safety net for the load done by run_onchange_generate_identities (which sets
# the service to Automatic + Running and ssh-add's the declared keys). Covers a
# service that got cleared, or the generator not having re-run since an account
# was added. Only ADDS - never flushes. To remove a key: ssh-add -d ~/.ssh/<key>
# (or ssh-add -D for all); de-declaring the account does not evict it.
#
# Twin of the PowerShell 7 profile's block, cost discipline included: the
# normal case (agent already holds every declared key - it persists them
# across reboots) is one `ssh-add -l` plus a fingerprint compare against
# $SshAgentFingerprints, which the generator computes from the .pub files once
# per apply. Older generator output (no map yet) falls back to fingerprinting
# each key file itself - one ssh-keygen spawn per key, once, until the
# generator re-runs.
try {
    $__sshAgentIds = Join-Path $env:USERPROFILE ".ssh\agent-identities.ps1"
    if ((Test-Path $__sshAgentIds) -and (Get-Command ssh-add -ErrorAction SilentlyContinue)) {
        . $__sshAgentIds   # -> $SshAgentIdentities (+ $SshAgentFingerprints from newer generators)
        $__loaded = @(& ssh-add -l 2>$null)
        $__loadFps = @($__loaded | ForEach-Object { ($_ -split '\s+')[1] })
        $__missing = @(
            foreach ($__k in @($SshAgentIdentities)) {
                $__kp = Join-Path $env:USERPROFILE ".ssh\$__k"
                if (-not (Test-Path $__kp)) { continue }
                if ($SshAgentFingerprints -and $SshAgentFingerprints.Contains($__k)) {
                    # Fast path: compare against the generated fingerprint - no spawn.
                    if ($__loadFps -notcontains $SshAgentFingerprints[$__k]) { $__k }
                } else {
                    # Older generator output: fingerprint the key file (one spawn per key).
                    $__fpSrc = if (Test-Path "$__kp.pub") { "$__kp.pub" } else { $__kp }
                    $__fp = ((& ssh-keygen -lf $__fpSrc 2>$null) -split '\s+')[1]
                    if (-not ($__fp -and ($__loaded -match [regex]::Escape($__fp)))) { $__k }
                }
            }
        )
        foreach ($__k in $__missing) {
            $__kp = Join-Path $env:USERPROFILE ".ssh\$__k"
            # Never block a new shell - twin of the PowerShell 7 profile's guard:
            # ssh-add on a passphrase-protected key prompts on the console and
            # would hang every terminal at startup. `ssh-keygen -y -P ""` exits
            # non-zero on such a key without prompting (verified: 0 vs 255).
            & ssh-keygen -y -P '""' -f $__kp *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ssh-agent: $__k needs a passphrase - run: ssh-add `"$__kp`"" -ForegroundColor DarkYellow
                continue
            }
            & ssh-add $__kp 2>&1 | Out-Null
        }
    }
} catch { Write-Verbose "ssh-agent prewarm skipped: $($_.Exception.Message)" } finally {
    Remove-Variable __sshAgentIds,__loaded,__loadFps,__missing,__k,__kp,__fpSrc,__fp -ErrorAction SilentlyContinue
}
