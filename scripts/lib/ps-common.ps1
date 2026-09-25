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
