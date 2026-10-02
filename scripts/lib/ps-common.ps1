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
