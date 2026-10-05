#Requires -Version 5.1
# scripts/lib/ps-common.ps1 - shared PowerShell helpers for the repo's plain
# .ps1 scripts (issue #123). Dot-source relative to the consumer:
#
#     . (Join-Path $PSScriptRoot 'lib\ps-common.ps1')
#
# NOT dot-sourced by:
#   - install.ps1 / install.sh: one-liner bootstraps that download themselves
#     and nothing else - no repo on disk to source from.
#   - the run_onchange/run_once .ps1 templates: chezmoi renders them as
#     self-contained scripts (they inline their own copies at render time;
#     tests/ps_modulepath_contract.sh and tests/windows_elevation_contract.sh
#     pin the literal guard/elevation text in those template files).
#
# A helper without a second consumer today is still worth one definition:
# Update-SessionPath has ten copies across the templates and bootstraps, all
# of which are exactly the files that cannot source this lib - this is the
# canonical shape for the next plain script that needs it.

# Cross-generation PSModulePath guard: chezmoi runs .ps1 scripts with Windows
# PowerShell 5.1; when an apply was launched from pwsh 7, the inherited module
# path makes 5.1 resolve Core builds of in-box modules and fail with "module
# could not be loaded" (confirmed live on Set-Acl in generate_identities
# during a fresh Windows install). Strip the Core module dirs under 5.1 so
# in-box modules resolve. Idempotent; safe on pwsh 7 (no-op there).
# (Renamed from Use-InBoxModules: PSUseSingularNouns wants a singular noun.)
function Repair-InBoxModulePath {
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $env:PSModulePath = (($env:PSModulePath -split ';') |
            Where-Object { $_ -and ($_ -notmatch '\\PowerShell\\[67]\\') }) -join ';'
        Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
    }
}

# True when the current session is elevated. Pure .NET - no module autoload,
# safe before Repair-InBoxModulePath.
function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Rebuild this session's PATH from the Machine + User registry state, so a
# freshly-installed tool's shim resolves without a new terminal. Supports
# -WhatIf/-Confirm (PSUseShouldProcessForStateChangingFunctions): the rewrite
# only happens when ShouldProcess confirms.
function Update-SessionPath {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $machineUserPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ($PSCmdlet.ShouldProcess('$env:Path', "rebuild from Machine+User registry state")) {
        $env:Path = $machineUserPath
    }
}

# True when [data.upgrade] desktop_shortcuts = false is set in the chezmoi
# config: the operator does not want installers' desktop shortcuts to survive
# `dot upgrade`. Absent or any other value = leave shortcuts alone (the
# default). Plain line scan, like the other config reads in scripts/:
# `chezmoi data` would resolve its own config path (docs/invariants.md #5).
function Test-DesktopShortcutsDisabled {
    param([string]$ConfigPath = (Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml'))
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
    $inUpgrade = $false
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -match '^\s*\[data\.upgrade\]\s*$') { $inUpgrade = $true; continue }
        if ($inUpgrade -and $line -match '^\s*\[') { $inUpgrade = $false }
        if ($inUpgrade -and $line -match '^\s*desktop_shortcuts\s*=\s*false\s*(#.*)?$') { return $true }
    }
    return $false
}

# Shortcut files (*.lnk, *.url) on this user's Desktop and the Public Desktop.
# GetFolderPath follows OneDrive-redirected Desktops. Returns full paths.
function Get-DesktopShortcut {
    param([string[]]$Directory = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')))
    $dirs = $Directory |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
        Select-Object -Unique
    foreach ($dir in $dirs) {
        Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.lnk', '.url' } |
            ForEach-Object { $_.FullName }
    }
}

# Delete the shortcuts that exist now but not in $Before (a Get-DesktopShortcut
# snapshot taken ahead of the upgrade). Shortcuts that were already there are
# never touched. Returns the removed paths.
function Remove-NewDesktopShortcut {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Before = @(), [string[]]$Directory)
    $known = @{}
    foreach ($path in $Before) { $known[$path.ToLowerInvariant()] = $true }
    $scan = if ($PSBoundParameters.ContainsKey('Directory')) { @(Get-DesktopShortcut -Directory $Directory) } else { @(Get-DesktopShortcut) }
    foreach ($path in $scan) {
        if ($known.ContainsKey($path.ToLowerInvariant())) { continue }
        if ($PSCmdlet.ShouldProcess($path, 'remove new desktop shortcut')) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            $path
        }
    }
}

# --- dot devtmp (#227) -------------------------------------------------------
# Config reads are plain line scans, like Test-DesktopShortcutsDisabled:
# `chezmoi data` would resolve its own config path (docs/invariants.md #5).

# [data.devtmp] path = "C:/dev/tmp" (basic or literal string) -> the string, or
# $null when the table, the key, or a non-empty value is absent.
function Get-DevTmpPath {
    param([string]$ConfigPath = (Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml'))
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    $inTable = $false
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -match '^\s*\[data\.devtmp\]\s*$') { $inTable = $true; continue }
        if ($inTable -and $line -match '^\s*\[') { $inTable = $false }
        if ($inTable -and $line -match '^\s*path\s*=\s*(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')\s*(#.*)?$') {
            $value = if ($Matches[1]) { $Matches[1] -replace '\\\\', '\' } else { $Matches[2] }
            if ($value) { return $value }
            return $null
        }
    }
    return $null
}

# Every entry of every `dirs = [...]` line inside a [[data.accounts]] block
# (the template emits dirs on ONE line). Home-relative as written.
function Get-AccountDir {
    param([string]$ConfigPath = (Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml'))
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return }
    $inAccount = $false
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -match '^\s*\[\[data\.accounts\]\]\s*$') { $inAccount = $true; continue }
        if ($inAccount -and $line -match '^\s*\[') { $inAccount = $false }
        if ($inAccount -and $line -match '^\s*dirs\s*=\s*\[(.*)\]\s*(#.*)?$') {
            foreach ($m in [regex]::Matches($Matches[1], '"((?:[^"\\]|\\.)*)"')) { $m.Groups[1].Value }
        }
    }
}

# Absolute drive path -> canonical `X:\a\b`; anything else -> $null. Pure string
# logic on purpose: [IO.Path]::GetFullPath treats `C:\x` as relative on Linux,
# and tests/devtmp.ps1 must give the same verdict on every runner.
function ConvertTo-DevTmpNormalPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    $p = $Path.Trim().Trim('"') -replace '/', '\'
    if ($p -notmatch '^[A-Za-z]:\\') { return $null }
    $drive = $p.Substring(0, 2).ToUpperInvariant()
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($seg in $p.Substring(2).Split('\')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') { if ($parts.Count -gt 0) { $parts.RemoveAt($parts.Count - 1) }; continue }
        $parts.Add($seg)
    }
    if ($parts.Count -eq 0) { return "$drive\" }
    return "$drive\" + ($parts -join '\')
}

# $Ancestor equals $Path or contains it. Compared on whole segments, so
# C:\Users\u is NOT an ancestor of C:\Users\u-dev (a bare StartsWith says it is).
function Test-DevTmpAncestor {
    param([string]$Ancestor, [string]$Path)
    $a = if ($Ancestor.EndsWith('\')) { $Ancestor } else { $Ancestor + '\' }
    $p = if ($Path.EndsWith('\')) { $Path } else { $Path + '\' }
    return $p.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)
}

# The refusal rules for a Defender-excluded folder: it must be an absolute drive
# path, and must not be a drive root, the user profile or an ancestor of it,
# %TEMP% / %TMP% or an ancestor of either, or an account directory or an ancestor
# of one. Home is checked before TEMP: TEMP normally lives under the profile, so
# C:\Users must report the profile. An unknown profile or temp refuses.
# -AccountDir entries are home-relative (as in chezmoi.toml) or absolute.
function Test-DevTmpPathSafe {
    param(
        [string]$Path,
        [string]$HomeDir,
        [string[]]$TempDir,
        [string[]]$AccountDir = @()
    )
    $norm = ConvertTo-DevTmpNormalPath -Path $Path
    $refuse = {
        param([string]$why)
        [pscustomobject]@{ Safe = $false; Path = $norm; Reason = $why }
    }
    if (-not $norm) { return & $refuse 'must be an absolute drive path such as C:\dev\tmp' }
    # Defender expands wildcards and environment variables inside -ExclusionPath,
    # so `C:\Users\*` is a blanket exclusion no literal check below could see.
    if ($norm -match '[*?%<>|"]') { return & $refuse 'it contains a wildcard or variable character (* ? % < > | ") that Defender expands' }
    if ($norm.Length -eq 3) { return & $refuse 'a drive root would exclude the whole drive' }
    # A rule that cannot be evaluated refuses; it never silently passes.
    $homeNorm = ConvertTo-DevTmpNormalPath -Path $HomeDir
    if (-not $homeNorm) { return & $refuse 'cannot tell where your user profile is, so a blanket exclusion cannot be ruled out' }
    $tempNorms = @($TempDir | ForEach-Object { ConvertTo-DevTmpNormalPath -Path $_ } | Where-Object { $_ })
    if ($tempNorms.Count -eq 0) { return & $refuse 'cannot tell where %TEMP% is, so a blanket exclusion cannot be ruled out' }
    if (Test-DevTmpAncestor -Ancestor $norm -Path $homeNorm) {
        return & $refuse 'it contains your user profile (a blanket exclusion)'
    }
    foreach ($tempNorm in $tempNorms) {
        if (Test-DevTmpAncestor -Ancestor $norm -Path $tempNorm) {
            return & $refuse 'it contains %TEMP% (a blanket exclusion)'
        }
    }
    foreach ($dir in $AccountDir) {
        $full = if ($dir -match '^[A-Za-z]:[\\/]') { $dir } else { "$homeNorm\$dir" }
        $dirNorm = ConvertTo-DevTmpNormalPath -Path $full
        if ($dirNorm -and (Test-DevTmpAncestor -Ancestor $norm -Path $dirNorm)) {
            return & $refuse "it contains the account directory '$dir' (your source checkouts)"
        }
    }
    [pscustomobject]@{ Safe = $true; Path = $norm; Reason = '' }
}

# --- Live agent sessions (dot upgrade) ---------------------------------------------------
# `dot upgrade` defers upgrades that delete and recreate package directories a running
# agent session resolves from. It used to match process NAMES only, so two things that are
# not sessions kept deferring codex and graft: Codex's shared app-server daemon (it runs
# its OWN release copy under ~\.codex\packages\app-server-daemon\, not the npm-global CLI
# the upgrade replaces) and Claude Desktop (an Electron app, ~10 claude.exe processes under
# AnthropicClaude\; it is not Claude Code). A process whose path cannot be read (an
# elevated process seen from a normal shell) still counts: when in doubt, defer.
$script:NonSessionPathPattern = @{
    claude = @('\\AnthropicClaude\\')
    codex  = @('\\\.codex\\packages\\app-server-daemon\\')
}

function Get-LiveAgentProcess {
    param([string[]]$Name)
    foreach ($n in $Name) {
        foreach ($process in @(Get-Process $n -ErrorAction SilentlyContinue)) {
            $path = $null
            try { $path = $process.Path } catch { $path = $null }
            if ($path -and $script:NonSessionPathPattern.ContainsKey($n)) {
                $ignored = $false
                foreach ($pattern in $script:NonSessionPathPattern[$n]) {
                    if ($path -match $pattern) { $ignored = $true }
                }
                if ($ignored) { continue }
            }
            $process
        }
    }
}

function Test-LiveProcess {
    param([string[]]$Names)
    return [bool](@(Get-LiveAgentProcess -Name $Names).Count -gt 0)
}

# Codex's shared app-server daemon keeps running the release it started with, so after a
# Codex CLI upgrade it can stay several versions behind until something restarts it. It is
# not a session (see above) and restarts on demand, so `dot upgrade` stops it before
# replacing the CLI. Only the daemon's own processes are matched, never a CLI session.
function Get-CodexDaemonProcess {
    foreach ($process in @(Get-Process codex -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $process.Path } catch { $path = $null }
        if ($path -and $path -match $script:NonSessionPathPattern['codex'][0]) { $process }
    }
}

# Returns the number of daemon processes it stopped (0 when none was running).
function Stop-CodexDaemon {
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$TimeoutSeconds = 20)
    $running = @(Get-CodexDaemonProcess)
    if ($running.Count -eq 0) { return 0 }
    if (-not $PSCmdlet.ShouldProcess('Codex app-server daemon', 'Stop')) { return 0 }
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if ($codex) {
        try {
            $proc = Start-Process -FilePath $codex.Source -ArgumentList 'app-server', 'daemon', 'stop' -WindowStyle Hidden -PassThru -ErrorAction Stop
            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) { $proc.Kill() }
        } catch { Write-Verbose "codex app-server daemon stop failed: $($_.Exception.Message)" }
    }
    # The polite stop did not take (or the CLI is too old to have it): the daemon is safe to end.
    foreach ($left in @(Get-CodexDaemonProcess)) {
        try { Stop-Process -Id $left.Id -Force -ErrorAction Stop } catch { Write-Verbose "daemon pid $($left.Id): $($_.Exception.Message)" }
    }
    return $running.Count
}

# --- Offering to stop live sessions (dot upgrade) ----------------------------------------
# Deferring is the safe default, but it leaves the tool un-upgraded until the operator
# closes things by hand and re-runs. On an interactive console `dot upgrade` instead lists
# what is blocking and asks. The invoker's own ancestry (this shell, the terminal, and the
# agent session that launched `dot upgrade`) is never offered: stopping it would end the
# very command that is asking. Those processes still defer their tools.
function Get-AncestorProcessId {
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    $id = $PID
    while ($id -gt 0 -and $ids.Add($id)) {
        $row = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if (-not $row) { break }
        $id = [int]$row.ParentProcessId
    }
    return @($ids)
}

function Get-StoppableAgentProcess {
    param([string[]]$Name, [int[]]$ExcludeId = @())
    return @(Get-LiveAgentProcess -Name $Name | Where-Object { $ExcludeId -notcontains $_.Id })
}

function Test-InteractiveConsole {
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected)
}

# Ask the window to close, then take the whole process tree down (Serena leaves language
# server children behind otherwise). Console agents have no window, so they go straight to
# the tree kill.
function Stop-AgentProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Process, [int]$GraceSeconds = 5)
    if (-not $PSCmdlet.ShouldProcess("$($Process.ProcessName) (pid $($Process.Id))", 'Stop process tree')) { return $false }
    $closing = $false
    try { $closing = [bool]$Process.CloseMainWindow() } catch { $closing = $false }
    if ($closing -and $Process.WaitForExit($GraceSeconds * 1000)) { return $true }
    & taskkill /PID $Process.Id /T /F *> $null
    return $true
}

function Format-LiveProcess {
    param($Process)
    $started = ''
    try { $started = ", started $($Process.StartTime.ToString('HH:mm'))" } catch { $started = '' }
    return "$($Process.ProcessName) (pid $($Process.Id)$started)"
}

# Returns the processes it stopped. Nothing is stopped unless the operator says so;
# DOTUPGRADE_NO_PROMPT=1 and a non-interactive console both keep today's defer-and-report.
function Invoke-LiveSessionStop {
    param([string[]]$Name, [int[]]$ExcludeId = @())
    if ($env:DOTUPGRADE_NO_PROMPT -eq '1') { return @() }
    $procs = @(Get-StoppableAgentProcess -Name $Name -ExcludeId $ExcludeId)
    if ($procs.Count -eq 0) { return @() }
    if (-not (Test-InteractiveConsole)) { return @() }

    Write-Host "  These sessions block part of the upgrade:" -ForegroundColor Yellow
    foreach ($p in $procs) { Write-Host "    $(Format-LiveProcess $p)" }
    Write-Host "  Stopping one ends that session; unsaved context is lost unless it can be resumed." -ForegroundColor Yellow
    $answer = (Read-Host "  Stop them so everything upgrades now? [y] all  [s] choose each  [N] keep and defer").Trim().ToLower()

    $chosen = @()
    if ($answer -eq 'y') {
        $chosen = $procs
    } elseif ($answer -eq 's') {
        foreach ($p in $procs) {
            $each = (Read-Host "    Stop $(Format-LiveProcess $p)? [y/N]").Trim().ToLower()
            if ($each -eq 'y') { $chosen += $p }
        }
    }
    $stopped = @()
    foreach ($p in $chosen) {
        if (Stop-AgentProcess -Process $p) { $stopped += $p }
    }
    if ($stopped.Count -gt 0) {
        Write-Host "  Stopped $($stopped.Count) process(es); re-scanning." -ForegroundColor Green
    }
    return $stopped
}

# --- "Is it already current?" (dot upgrade) ----------------------------------------------
# `graft upgrade` ran every time (0.21.1 -> 0.21.1 took 41 s on WSL) and the codex
# `npm install -g` another ~9 s. Ask first; anything unknown (empty answers, an unreachable
# registry) means "not current", so the install still happens exactly as before.
$script:NpmCurrentVersion = ''

# True when the globally installed <Package> is already the registry's latest. On True,
# $script:NpmCurrentVersion holds the version.
function Test-NpmGlobalCurrent {
    param([Parameter(Mandatory)][string]$Package)

    $script:NpmCurrentVersion = ''
    $previous = $ErrorActionPreference
    # PS 5.1 promotes native stderr to a terminating error under Stop; the answer is the signal.
    $ErrorActionPreference = 'Continue'
    try {
        $have = ''
        $listing = ((npm ls -g $Package --depth=0 --json 2>$null) | Out-String).Trim()
        if ($listing) {
            $parsed = $listing | ConvertFrom-Json
            $deps = $parsed.PSObject.Properties['dependencies']
            if ($null -ne $deps -and $null -ne $deps.Value -and $null -ne $deps.Value.PSObject.Properties[$Package]) {
                $have = "$($deps.Value.PSObject.Properties[$Package].Value.version)"
            }
        }
        $want = ((npm view $Package version 2>$null) | Out-String).Trim()
        if ($have -and $have -eq $want) {
            $script:NpmCurrentVersion = $have
            return $true
        }
        return $false
    }
    catch { return $false }
    finally { $ErrorActionPreference = $previous }
}

# `graft version` prints "graft <installed>" and "latest: <published>" (or "latest:
# unreachable (offline?)"). Returns the version when both agree, else ''.
function Get-GraftCurrentVersion {
    param([string]$VersionOutput)

    $installed = ''
    $latest = ''
    if ($VersionOutput -match '(?m)^graft (\d[^\s]*)') { $installed = $Matches[1] }
    # Online: "latest on npm: 0.21.1 <check> up to date"; offline: "latest: unreachable (offline?)".
    if ($VersionOutput -match '(?m)^latest(?: on npm)?: (\d[^\s]*)') { $latest = $Matches[1] }
    if ($installed -and $installed -eq $latest) { return $installed }
    return ''
}

# graft's own `graft upgrade` dies on Windows with "spawnSync npm ENOENT" (npm is npm.cmd
# there and the upgrade spawns it without a shell). It only wraps `npm install -g`, so run
# that directly. npm 12 skips install scripts unless allow-listed, so the installer's
# allow-list (agents.yaml) goes into NPM_CONFIG_ALLOW_SCRIPTS for the call only. Returns
# npm's exit code.
function Invoke-GraftNpmInstall {
    param([Parameter(Mandatory)][string]$AllowScripts)

    $previousAllow = $env:NPM_CONFIG_ALLOW_SCRIPTS
    $previousPreference = $ErrorActionPreference
    # PS 5.1 promotes native stderr to a terminating error under Stop; the exit code is the signal.
    $ErrorActionPreference = 'Continue'
    try {
        $env:NPM_CONFIG_ALLOW_SCRIPTS = $AllowScripts
        npm install -g '@nanonets/graft@latest' --loglevel=error --no-progress
        return [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
        if ($null -eq $previousAllow) { Remove-Item Env:NPM_CONFIG_ALLOW_SCRIPTS -ErrorAction SilentlyContinue }
        else { $env:NPM_CONFIG_ALLOW_SCRIPTS = $previousAllow }
    }
}

# The `choco upgrade all` argument list. Chocolatey's `claude` package (Claude Desktop) ends
# its installer with `taskkill /F /IM claude.exe /T`, which kills EVERY claude.exe - and
# Claude Code's CLI has the same image name, so a live Claude Code session dies with it
# (seen in the dot upgrade log: "Terminating Claude process..."). While any claude.exe is
# running that one package is left out of the sweep; the next quiet dot upgrade takes it.
function Get-ChocoUpgradeArgument {
    $chocoArguments = @('upgrade', 'all', '-y', '--no-progress')
    if (@(Get-Process claude -ErrorAction SilentlyContinue).Count -gt 0) {
        $chocoArguments += '--except=claude'
    }
    return $chocoArguments
}

# --- choco, summarised --------------------------------------------------------------------
# `choco upgrade all` printed ~100 lines of "<package> vX is the latest version available"
# on every run, burying the two or three packages that changed. --limit-output prints one
# machine-readable line per package (name|installed|available|pinned): those are collected
# instead of echoed, everything a package's own installer says still streams live (a hung
# or prompting installer stays visible), the FULL output goes to the log, and the sweep
# ends with a summary. A non-zero exit prints the tail so the failing package is on screen.
function Invoke-ChocoUpgradeAll {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$LogPath)

    if (-not $LogPath) { $LogPath = Join-Path $HOME '.local\state\dotfiles\upgrade.log' }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
        # keep one previous generation instead of growing without bound
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 2MB) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
        }
        Add-Content -LiteralPath $LogPath -Value ("=== {0} choco {1}" -f (Get-Date -Format s), ($Arguments -join ' '))
    }
    catch { $LogPath = $null; Write-Verbose "upgrade log unavailable: $($_.Exception.Message)" }

    $packageLines = New-Object System.Collections.Generic.List[string]
    $allLines = New-Object System.Collections.Generic.List[string]
    & choco @Arguments --limit-output 2>&1 | ForEach-Object {
        $line = "$_"
        $allLines.Add($line)
        if ($LogPath) { Add-Content -LiteralPath $LogPath -Value $line }
        if ($line -match '^[^|\s][^|]*\|[^|]*\|[^|]*\|[^|]*$') { $packageLines.Add($line) } else { Write-Host $line }
    }
    $code = [int]$LASTEXITCODE

    $summary = Get-ChocoUpgradeSummary -Lines $packageLines
    if ($summary.Upgraded.Count -gt 0) {
        Write-Host ("  Upgraded {0} of {1}: {2}" -f $summary.Upgraded.Count, $summary.Checked, ($summary.Upgraded -join ', ')) -ForegroundColor Green
    }
    elseif ($summary.Checked -gt 0) {
        Write-Host ("  Nothing to upgrade ({0} packages checked)" -f $summary.Checked)
    }
    # 1641 / 3010: success, a restart is needed
    if ($code -eq 1641 -or $code -eq 3010) {
        Write-Host "  A restart is needed to finish one of the upgrades." -ForegroundColor Yellow
    }
    elseif ($code -ne 0) {
        Write-Host "  Warning: choco exited $code - the last lines of its output:" -ForegroundColor Red
        $allLines | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" }
    }
    if ($LogPath) { Write-Host "  (full output: $LogPath)" -ForegroundColor DarkGray }
    return $code
}

# name|installed|available|pinned lines -> how many were checked and which changed.
function Get-ChocoUpgradeSummary {
    param([string[]]$Lines)

    $upgraded = @()
    $checked = 0
    foreach ($line in @($Lines)) {
        $parts = $line -split '\|'
        if ($parts.Count -lt 3) { continue }
        $checked++
        if ($parts[1] -and $parts[2] -and $parts[1] -ne $parts[2]) { $upgraded += ("{0} ({1} -> {2})" -f $parts[0], $parts[1], $parts[2]) }
    }
    return [pscustomobject]@{ Checked = $checked; Upgraded = @($upgraded) }
}
