#Requires -Version 5.1
<#
migrate-to-choco.ps1 - opt-in takeover of apps installed outside Chocolatey.

The chezmoi installer skips any managed choco package it finds already
installed by other means (winget, vendor installer) - "Skipping X - 'Y' is
already installed (not via Chocolatey)". Chocolatey cannot adopt an existing
installation; the only path to `choco upgrade all` coverage is
uninstall + reinstall. This script does that per app, with explicit
confirmation each time - NEVER automatically.

  Detect only:   pwsh -File migrate-to-choco.ps1 -ListOnly
  Migrate:       pwsh -File migrate-to-choco.ps1        (elevated, per-app Y/n)

Risk notes are per app; tailscale (live VPN - uninstalling drops your tailnet
connection mid-run) requires typing its name to proceed even after Y.

The package universe below mirrors every choco package the installer can
manage (keep in sync with run_onchange_install_packages.ps1.tmpl's
$packages lists - the contract test enforces the marker line both sides).
#>
param([switch]$ListOnly)

$ErrorActionPreference = 'Stop'

# Hard elevation gate (same contract as the installer: nothing runs degraded;
# admin is required for uninstall + choco install).
$__isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $__isAdmin -and -not $ListOnly) {
    Write-Host "migrate-to-choco requires an elevated terminal (uninstall + choco install)." -ForegroundColor Red
    Write-Host "  Re-run as Administrator, or use -ListOnly to just see candidates." -ForegroundColor Yellow
    exit 1
}

# Cross-generation PSModulePath guard (see run_onchange_generate_identities
# .ps1.tmpl): registry/Get-ItemProperty + Write-Host live in the in-box
# modules 5.1 fails to autoload under pwsh 7's inherited module path.
if ($PSVersionTable.PSVersion.Major -le 5) {
    $env:PSModulePath = (($env:PSModulePath -split ';') |
        Where-Object { $_ -and ($_ -notmatch '\\PowerShell\\[67]\\') }) -join ';'
    Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
}

# --- package universe: mirrors the installer's choco $packages lists -------
# MIGRATE-UNIVERSE-MARKER (kept in sync with run_onchange_install_packages.ps1.tmpl)
# The installer side carries the same marker via its advisory block.
$Universe = @(
    # core
    'gsudo', 'powershell-core', 'psmux', 'python', 'wsl2', 'tree', '7zip.install', 'cmake', 'ffmpeg',
    # modern_cli
    'bat', 'eza', 'fd', 'delta', 'starship', 'zoxide', 'direnv', 'lazygit', 'tealdeer', 'dust', 'duf', 'procs', 'shellcheck', 'shfmt', 'pstop',
    # fonts
    'nerd-fonts-meslo',
    # dev_desktop
    'qbittorrent', 'sharex', 'meld', 'wiztree', 'termius', 'vlc', 'handy',
    # remote_access
    'tailscale', 'cloudflared',
    # agent groups
    'act-cli', 'antigravity-cli', 'claude', 'antigravity', 'opencode-desktop'
)

$RiskNotes = @{
    'tailscale' = 'LIVE VPN - uninstalling drops your tailnet connection until choco reinstall completes. Requires typing the name to confirm.'
    'handy'     = 'Activation/settings may live in the install directory and can be lost.'
    'claude'    = 'App data stays in the profile; only the app itself is replaced.'
    'termius'   = 'Signed-in state lives in the profile; the app itself is replaced.'
}

# --- detection: same registry normalization as the installer ----------------
$uninstallEntries = @(
    Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { ($_.PSObject.Properties.Name -contains 'DisplayName') -and $_.DisplayName } |
        ForEach-Object {
            [PSCustomObject]@{
                Display          = $_.DisplayName
                Normalized       = ($_.DisplayName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
                UninstallString  = $_.UninstallString
                QuietUninstall   = $_.QuietUninstallString
            }
        }
)

$chocoManaged = @()
try { $chocoManaged = @(choco list 2>$null | ForEach-Object { ($_ -split '\|')[0].Trim() }) } catch {}

$candidates = @()
foreach ($pkg in $Universe) {
    if ($chocoManaged -contains $pkg) { continue }
    $normalized = ($pkg -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if ($normalized.Length -lt 3) { continue }
    $existing = $uninstallEntries | Where-Object { $_.Normalized -like "*$normalized*" } | Select-Object -First 1
    if ($existing) { $candidates += [PSCustomObject]@{ Pkg = $pkg; Entry = $existing } }
}

if (-not $candidates) {
    Write-Host 'No managed-package candidates installed outside Chocolatey. Nothing to do.'
    exit 0
}

Write-Host "Found $($candidates.Count) candidate(s) installed outside Chocolatey:" -ForegroundColor Cyan
foreach ($c in $candidates) {
    $risk = if ($RiskNotes[$c.Pkg]) { "  [risk: $($RiskNotes[$c.Pkg])]" } else { '' }
    Write-Host ("  {0,-16} {1}{2}" -f $c.Pkg, $c.Entry.Display, $risk)
}

if ($ListOnly) {
    Write-Host ''
    Write-Host 'List-only. To migrate (elevated, per-app confirmation): re-run without -ListOnly.'
    exit 0
}

# --- per-app migration --------------------------------------------------------
$migrated = @()
$skipped = @()
foreach ($c in $candidates) {
    Write-Host ''
    $answer = Read-Host ("Migrate '$($c.Pkg)' (uninstall '$($c.Entry.Display)' then choco install)? [y/N]")
    if ($answer -notmatch '^[Yy]') { $skipped += $c.Pkg; continue }

    if ($c.Pkg -eq 'tailscale') {
        $typed = Read-Host 'Type "tailscale" to confirm dropping the VPN during migration'
        if ($typed -ne 'tailscale') { $skipped += $c.Pkg; Write-Host '  - skipped (no typed confirmation)'; continue }
    }

    # Uninstall: prefer winget (knows silent flags), fall back to the
    # registry QuietUninstall/Uninstall string.
    $done = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  uninstalling via winget: $($c.Entry.Display)"
        winget uninstall --name "$($c.Entry.Display)" --silent --accept-source-agreements 2>$null
        if ($LASTEXITCODE -eq 0) { $done = $true }
    }
    if (-not $done) {
        $u = if ($c.Entry.QuietUninstall) { $c.Entry.QuietUninstall } else { $c.Entry.UninstallString }
        if ($u) {
            Write-Host "  uninstalling via registry string"
            # Best-effort common silent flags; vendor uninstallers vary.
            $cmd = $u -replace '/quiet', '/verysilent'
            cmd /c $cmd
            $done = $true
        }
    }
    if (-not $done) {
        Write-Host "  could not determine an uninstall path for '$($c.Entry.Display)' - skipping" -ForegroundColor Red
        $skipped += $c.Pkg
        continue
    }
    Start-Sleep -Seconds 3

    Write-Host "  choco install $($c.Pkg)"
    choco install $c.Pkg -y --no-progress
    if ($LASTEXITCODE -eq 0) {
        $migrated += $c.Pkg
        Write-Host "  migrated: $($c.Pkg)" -ForegroundColor Green
    } else {
        Write-Host "  choco install failed for $($c.Pkg) - it may need a manual install now" -ForegroundColor Red
        $skipped += $c.Pkg
    }
}

Write-Host ''
Write-Host "Migrated: $($migrated.Count) ($($migrated -join ', '))"
Write-Host "Skipped:  $($skipped.Count) ($($skipped -join ', '))"
