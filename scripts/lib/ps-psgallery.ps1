# scripts/lib/ps-psgallery.ps1 - install or update a PowerShell Gallery module from the package catalog
# (field `psgallery` in .chezmoidata/packages.yaml: PSScriptAnalyzer).
#
# One copy for both shells. Windows PowerShell 5.1 and pwsh 7 keep separate per-user module folders,
# but pwsh 7 also searches 5.1's (Documents\WindowsPowerShell\Modules) and 5.1 never searches pwsh 7's.
# So the work always runs in a `powershell.exe` child, whichever shell called: `dot up`'s installer runs
# under 5.1, `dot upgrade` under whichever shell the operator typed it in, and an `Install-Module` from
# pwsh 7 would land where 5.1 cannot see it. The child starts with 5.1's own module path: one spawned
# from pwsh 7 inherits pwsh 7's, and would count a pwsh-7-only copy as installed.
#
# Inlined into the installer with {{ include }} (it never loads ps-common.ps1) and dot-sourced by
# scripts/lib/ps-common.ps1. Nothing here may depend on anything else in ps-common.ps1.

# Windows PowerShell 5.1's default module path: the user's, then the machine's two.
function Get-WindowsPowerShellModulePath {
    $paths = @()
    $docs = [Environment]::GetFolderPath('MyDocuments')
    # .NET answers '' when the Documents known folder cannot be resolved (always, off Windows):
    # the user's path is still the one 5.1's Install-Module -Scope CurrentUser falls back to.
    if (-not $docs -and $HOME) { $docs = Join-Path $HOME 'Documents' }
    if ($docs) { $paths += Join-Path (Join-Path $docs 'WindowsPowerShell') 'Modules' }
    if ($env:ProgramFiles) { $paths += Join-Path (Join-Path $env:ProgramFiles 'WindowsPowerShell') 'Modules' }
    if ($env:SystemRoot) { $paths += Join-Path $env:SystemRoot 'system32\WindowsPowerShell\v1.0\Modules' }
    return ($paths -join ';')
}

# Install-PSGalleryModule -Name <module> [-Upgrade]
#   without -Upgrade (`dot up`): install when missing, otherwise leave it alone - no network;
#   with -Upgrade (`dot upgrade`): update when installed and behind the Gallery; never install.
# Prints one line when something happened or failed, and returns the outcome word:
# present, absent, current, installed, upgraded or failed. Never throws.
function Install-PSGalleryModule {
    param([Parameter(Mandatory)][string]$Name, [switch]$Upgrade)
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
        Write-Host "  Warning: '$Name' is not a PowerShell module name - skipping" -ForegroundColor Red
        return 'failed'
    }
    if (-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        Write-Host "  Windows PowerShell (powershell.exe) not found - skipping $Name" -ForegroundColor Red
        return 'failed'
    }
    $upgradeFlag = '$false'
    if ($Upgrade) { $upgradeFlag = '$true' }
    # Outcome words on stdout, never `exit`: the last word is the answer. TLS 1.2 and the NuGet
    # provider check as the PSReadLine step: -ListAvailable only looks, because 5.1's plain
    # Get-PackageProvider bootstraps a missing NuGet behind an interactive prompt (#430).
    $child = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$name = '__NAME__'
$upgrade = __UPGRADE__
try {
    $have = Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending | Select-Object -First 1
    if ($have -and -not $upgrade) { "present $($have.Version)"; return }
    if (-not $have -and $upgrade) { 'absent'; return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    $latest = (Find-Module -Name $name -Repository PSGallery).Version
    if ($have -and [version]"$($have.Version)" -ge [version]"$latest") { "current $($have.Version)"; return }
    Install-Module -Name $name -RequiredVersion $latest -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck
    if ($have) { "upgraded $($have.Version) $latest" } else { "installed $latest" }
} catch {
    "failed $($_.Exception.Message)"
}
'@
    $child = $child.Replace('__NAME__', $Name).Replace('__UPGRADE__', $upgradeFlag)
    # -EncodedCommand: Windows PowerShell 5.1 strips the quotes inside a native argument.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
    $previousModulePath = $env:PSModulePath
    $previousPreference = $ErrorActionPreference
    # Native stderr throws under Stop on Windows PowerShell 5.1 (docs/invariants.md #12).
    $ErrorActionPreference = 'Continue'
    $out = @()
    try {
        $env:PSModulePath = Get-WindowsPowerShellModulePath
        $out = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | ForEach-Object { "$_" })
    } catch {
        $out = @("failed $($_.Exception.Message)")
    } finally {
        $env:PSModulePath = $previousModulePath
        $ErrorActionPreference = $previousPreference
    }
    $answer = @($out | Where-Object { $_ -match '^(present|absent|current|installed|upgraded|failed)\b' } | Select-Object -Last 1)
    if ($answer.Count -eq 0) { $answer = @("failed no answer from powershell.exe: $(($out | Select-Object -Last 3) -join ' ')") }
    $word, $rest = "$($answer[0])" -split ' ', 2
    switch ($word) {
        'current' { Write-Host "  $Name is current ($rest)" }
        'installed' { Write-Host "  Installed $Name $rest (PowerShell Gallery)" -ForegroundColor Green }
        'upgraded' { $from, $to = "$rest" -split ' ', 2; Write-Host "  $Name upgraded $from -> $to" -ForegroundColor Green }
        'failed' { Write-Host "  Warning: $Name (PowerShell Gallery) failed - $rest - continuing" -ForegroundColor Red }
    }
    return $word
}
