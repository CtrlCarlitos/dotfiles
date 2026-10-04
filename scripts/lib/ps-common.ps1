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
    if ($VersionOutput -match '(?m)^latest: (\d[^\s]*)') { $latest = $Matches[1] }
    if ($installed -and $installed -eq $latest) { return $installed }
    return ''
}
