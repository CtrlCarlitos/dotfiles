#Requires -Version 5.1
# dot upgrade - the single owner of ALL tool upgrades.
# Runs on demand via `dot upgrade` (the dot command family in the shell
# profiles). `dot up` NEVER upgrades; this script does, with live-session guards.
$ErrorActionPreference = 'Continue'

# Shared helpers (scripts/lib/ps-common.ps1, issue #123).
. (Join-Path $PSScriptRoot 'lib\ps-common.ps1')

# --- Elevation: choco upgrade needs admin; fail loudly, not degraded. ---
if (-not (Test-IsAdmin)) {
    Write-Host "dot upgrade requires an elevated PowerShell (choco upgrade needs it)." -ForegroundColor Red
    Write-Host "  Open a terminal as Administrator and re-run: dot upgrade" -ForegroundColor Yellow
    exit 1
}

Write-Host "dot upgrade - sweeping all tooling..." -ForegroundColor Cyan
Add-DotTimingMark -Name 'sessions and Codex daemon'

# --- Live-session scan: defer dir-recreating upgrades while agent hosts run.
# npm -g / uv tool / choco opencode all delete+recreate package directories
# that live sessions resolve from at runtime (2026-09-20 live incidents:
# graft hook resolution, opencode lib-bkp, codex banner drift).
# Test-LiveProcess / Get-LiveAgentProcess: scripts/lib/ps-common.ps1 (path-aware: Codex's
# app-server daemon and Claude Desktop are not sessions).
#
# On an interactive console the operator is first offered the chance to stop the blocking
# sessions (never this shell's own ancestry); whatever stays running still defers.
$agentNames = @('opencode', 'claude', 'codex', 'agy', 'serena')
$stoppedSessions = @(Invoke-LiveSessionStop -Name $agentNames -ExcludeId @(Get-AncestorProcessId))
if ($stoppedSessions.Count -gt 0) { Start-Sleep -Seconds 1 }
# Codex's app-server daemon is not a session but keeps running the release it started with;
# with no Codex session left it is stopped so the next start is the upgraded version.
if (-not (Test-LiveProcess @('codex'))) {
    $daemonsStopped = Stop-CodexDaemon
    if ($daemonsStopped -gt 0) { Write-Host "  Stopped Codex's app-server daemon (it restarts on demand, on the new version)." -ForegroundColor Yellow }
}
$defer = @()
if (Test-LiveProcess @('codex'))  { $defer += 'codex' }
if (Test-LiveProcess @('opencode','claude','codex','agy')) { $defer += 'graft' }
if (Test-LiveProcess @('serena')) { $defer += 'serena' }
if (Test-LiveProcess @('opencode')) { $defer += 'opencode' }
$env:DOTUPGRADE_DEFER = ($defer -join ',')
if ($defer.Count -gt 0) {
    $__liveNames = (@(Get-LiveAgentProcess -Name opencode, claude, codex, agy, serena) | ForEach-Object { $_.ProcessName } | Select-Object -Unique) -join ', '
    Write-Host "  Live agent session(s): $__liveNames - deferring: $($defer -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "  No live agent sessions - full sweep." -ForegroundColor Green
}

# --- Desktop shortcuts: installers drop them on every upgrade. With
# [data.upgrade] desktop_shortcuts = false, snapshot now and delete only the
# NEW ones after the sweeps. Per-installer switches do not exist for a
# `choco upgrade all` / `winget upgrade --all` sweep.
$dropDesktopShortcuts = Test-DesktopShortcutsDisabled
$shortcutsBefore = @()
if ($dropDesktopShortcuts) { $shortcutsBefore = @(Get-DesktopShortcut) }

Add-DotTimingMark -Name 'Docker Desktop'
# --- Docker Desktop: its installer cannot replace a running app, so an available upgrade used to
# do nothing without a word. When one is pending and Docker Desktop is up, offer to stop it (same
# rule as the agent sessions above); whichever manager owns the package then upgrades it.
$dockerKept = $false
$dockerPendingVersion = ''
# Docker Desktop is winget's (Docker's own EXE installer, current releases). A machine that
# still has Chocolatey's MSI copy cannot be upgraded by winget and lags behind: say how to move.
$dockerOwner = Get-DockerDesktopOwner
if ($dockerOwner -eq 'choco') {
    Write-Host "  Docker Desktop is still Chocolatey's (its package lags Docker's releases, and winget will not upgrade it). To move it to winget and keep your data, see docs/windows.md (Docker Desktop through winget)." -ForegroundColor Yellow
}
if (@(Get-DockerDesktopProcess).Count -gt 0) {
    $dockerPendingVersion = Get-DockerDesktopUpgrade -Owner $dockerOwner
    if ($dockerPendingVersion) { $dockerKept = -not (Invoke-DockerDesktopStopOffer -Version $dockerPendingVersion -ExcludeId @(Get-AncestorProcessId)) }
}

Add-DotTimingMark -Name 'choco'
# --- 1. System packages: the choco upgrade all this command replaces. ---
if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Host "  Upgrading choco packages (choco upgrade all)..." -ForegroundColor Yellow
    $chocoArguments = @(Get-ChocoUpgradeArgument -KeepDockerDesktop:$dockerKept)
    if (($chocoArguments -join ' ') -match '--except=\S*claude') {
        Write-Host "  claude (Desktop) left out of this sweep - a claude.exe is running, and the package's installer force-kills every claude.exe (Claude Code sessions included). Close them and re-run to take it." -ForegroundColor Yellow
    }
    $null = Invoke-ChocoUpgradeAll -Arguments $chocoArguments   # it prints its own warning on a non-zero exit
} else {
    Write-Host "  choco not found - skipping system packages." -ForegroundColor Yellow
}

Add-DotTimingMark -Name 'winget'
# --- 1a. winget-managed apps (Build Tools, ChatGPT Work/Codex msstore,
# Win-CodexBar): same full-sweep premise as choco - upgrade everything
# winget knows, not just what this repo installed. --include-unknown: apps
# with undetermined installed versions are skipped without it.
if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host "  Upgrading winget packages (winget upgrade --all)..." -ForegroundColor Yellow
    $wingetRunningNote = ''
    if ($dockerKept) { $wingetRunningNote = "Docker Desktop $dockerPendingVersion waits because Docker Desktop is running: close it and re-run, or run: winget upgrade Docker.DockerDesktop" }
    $wingetHold = @()
    if ($dockerKept) { $wingetHold = @('Docker.DockerDesktop') }   # running: its installer would fail mid-sweep
    $null = Invoke-WingetUpgradeAll -RunningNote $wingetRunningNote -HoldId $wingetHold   # it prints its own summary and warnings
} else {
    Write-Host "  winget not found - skipping winget packages." -ForegroundColor Yellow
}

Add-DotTimingMark -Name 'VS Code extensions'
# --- 1b. VS Code extensions: `dot up` only installs missing ones (no --force); updates are
# this command's job. Skipped quietly when VS Code is absent; a failure never aborts.
if (Get-Command code -ErrorAction SilentlyContinue) {
    Write-Host "  Updating VS Code extensions..." -ForegroundColor Yellow
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & code --update-extensions *> $null
        if ($LASTEXITCODE -ne 0) { Write-Host "  VS Code extension update exited with code $LASTEXITCODE - continuing" -ForegroundColor Yellow }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

Add-DotTimingMark -Name 'AI tools'
# --- 2. AI tools: the update_ai_tools section, defer-aware. ---
& (Join-Path $PSScriptRoot 'update_ai_tools.ps1')

if ($dropDesktopShortcuts) {
    $removedShortcuts = @(Remove-NewDesktopShortcut -Before $shortcutsBefore)
    if ($removedShortcuts.Count -gt 0) {
        Write-Host "  Removed $($removedShortcuts.Count) new desktop shortcut(s) (desktop_shortcuts = false):" -ForegroundColor Yellow
        foreach ($removed in $removedShortcuts) { Write-Host "    $removed" }
    }
}

Write-DotTimingSummary -Title 'dot upgrade'
# --- Deferred report: what to re-run when quiet. ---
if ($defer.Count -gt 0) {
    Write-Host ""
    Write-Host "Deferred (live sessions): $($defer -join ', ')" -ForegroundColor Yellow
    Write-Host "  Re-run 'dot upgrade' with those sessions closed to pick them up." -ForegroundColor Yellow
} else {
    Write-Host "dot upgrade complete." -ForegroundColor Green
}
Remove-Item Env:\DOTUPGRADE_DEFER -ErrorAction SilentlyContinue
