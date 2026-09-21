#Requires -Version 5.1
# dot upgrade - the single owner of ALL tool upgrades.
# Spec: docs/superpowers/specs/2026-09-20-dot-cli-design.md
# `dot up` NEVER upgrades; this script does, with live-session guards.
$ErrorActionPreference = 'Continue'

# --- Elevation: choco upgrade needs admin; fail loudly, not degraded. ---
$__isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $__isAdmin) {
    Write-Host "dot upgrade requires an elevated PowerShell (choco upgrade needs it)." -ForegroundColor Red
    Write-Host "  Open a terminal as Administrator and re-run: dot upgrade" -ForegroundColor Yellow
    exit 1
}

Write-Host "dot upgrade - sweeping all tooling..." -ForegroundColor Cyan

# --- Live-session scan: defer dir-recreating upgrades while agent hosts run.
# npm -g / uv tool / choco opencode all delete+recreate package directories
# that live sessions resolve from at runtime (2026-09-20 live incidents:
# graft hook resolution, opencode lib-bkp, codex banner drift).
function Test-LiveProcess([string[]]$Names) {
    foreach ($n in $Names) { if (Get-Process $n -ErrorAction SilentlyContinue) { return $true } }
    return $false
}
$defer = @()
if (Test-LiveProcess @('codex'))  { $defer += 'codex' }
if (Test-LiveProcess @('opencode','claude','codex','agy')) { $defer += 'graft' }
if (Test-LiveProcess @('serena')) { $defer += 'serena' }
if (Test-LiveProcess @('opencode')) { $defer += 'opencode' }
$env:DOTUPGRADE_DEFER = ($defer -join ',')
if ($defer.Count -gt 0) {
    $__liveNames = (@(Get-Process opencode, claude, codex, agy, serena -ErrorAction SilentlyContinue) | ForEach-Object { $_.ProcessName } | Select-Object -Unique) -join ', '
    Write-Host "  Live agent session(s): $__liveNames - deferring: $($defer -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "  No live agent sessions - full sweep." -ForegroundColor Green
}

# --- 1. System packages: the choco upgrade all this command replaces. ---
if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Host "  Upgrading choco packages (choco upgrade all)..." -ForegroundColor Yellow
    choco upgrade all -y --no-progress
} else {
    Write-Host "  choco not found - skipping system packages." -ForegroundColor Yellow
}

# --- 1a. winget-managed apps (Build Tools, ChatGPT Work/Codex msstore,
# Win-CodexBar): same full-sweep premise as choco - upgrade everything
# winget knows, not just what this repo installed. --include-unknown: apps
# with undetermined installed versions are skipped without it.
if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host "  Upgrading winget packages (winget upgrade --all)..." -ForegroundColor Yellow
    try {
        & winget upgrade --all --include-unknown --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { Write-Host "  Warning: winget upgrade exited $LASTEXITCODE (store apps can require interactive agreement) - continuing" -ForegroundColor Red }
    } catch {
        Write-Host "  Warning: winget upgrade failed - continuing" -ForegroundColor Red
    }
} else {
    Write-Host "  winget not found - skipping winget packages." -ForegroundColor Yellow
}

# --- 2. AI tools: the update_ai_tools section, defer-aware. ---
& (Join-Path $PSScriptRoot 'update_ai_tools.ps1')

# --- Deferred report: what to re-run when quiet. ---
if ($defer.Count -gt 0) {
    Write-Host ""
    Write-Host "Deferred (live sessions): $($defer -join ', ')" -ForegroundColor Yellow
    Write-Host "  Re-run 'dot upgrade' with those sessions closed to pick them up." -ForegroundColor Yellow
} else {
    Write-Host "dot upgrade complete." -ForegroundColor Green
}
Remove-Item Env:\DOTUPGRADE_DEFER -ErrorAction SilentlyContinue
