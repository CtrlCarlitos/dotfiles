#Requires -Version 5.1
# dot upgrade - the single owner of ALL tool upgrades.
# Runs on demand via `dot upgrade` (the dot command family in the shell
# profiles). `dot up` NEVER upgrades; this script does, with live-session guards.
$ErrorActionPreference = 'Continue'

# Shared helpers (scripts/lib/ps-common.ps1, issue #123).
. (Join-Path $PSScriptRoot 'lib\ps-common.ps1')
# Native tools print UTF-8; PowerShell decodes their output with the console's OEM code page,
# so a captured "..." came out as "three CP437 characters" (2026-10-07). Process-local, as in the installer.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { Write-Verbose "console encoding unchanged: $($_.Exception.Message)" }

# --- Elevation: choco upgrade needs admin; fail loudly, not degraded. ---
if (-not (Test-IsAdmin)) {
    Write-Host "dot upgrade requires an elevated PowerShell (choco upgrade needs it)." -ForegroundColor Red
    Write-Host "  Open a terminal as Administrator and re-run: dot upgrade" -ForegroundColor Yellow
    exit 1
}

# dot upgrade --yes: answer "yes" to its questions up front (stop the sessions and desktop
# apps; stop Docker Desktop for its upgrade), for a run nobody stays to watch. Without it each
# question takes its safe default ("no") after DOTUPGRADE_PROMPT_TIMEOUT seconds (60).
# A script-scope flag, not an environment variable: dot upgrade runs inside the operator's
# shell, and an env var would outlive an interrupted run and answer later questions too.
foreach ($arg in $args) {
    switch -Regex ($arg) {
        '^(-y|--yes|-Yes)$' { $script:DotAnswerYes = $true }
        '^(-h|--help|-Help)$' {
            Write-Host 'dot upgrade [--yes]   upgrade all tooling; --yes answers its questions with yes'
            Write-Host '  Unanswered questions take their default (no) after DOTUPGRADE_PROMPT_TIMEOUT seconds (60; 0 = wait).'
            exit 0
        }
    }
}
Write-Host "dot upgrade - sweeping all tooling..." -ForegroundColor Cyan
# Two marks, so the Timings line says which half is slow: the scan and the stop, then the
# Codex daemon and the defer scan (one "sessions and Codex daemon" mark hid it).
Add-DotTimingMark -Name 'sessions (scan and stop)'

# --- Live-session scan: defer dir-recreating upgrades while agent hosts run.
# npm -g / uv tool / choco opencode all delete+recreate package directories
# that live sessions resolve from at runtime (2026-09-20 live incidents:
# opencode lib-bkp, codex banner drift).
# Test-LiveProcess / Get-LiveAgentProcess: scripts/lib/ps-common.ps1 (path-aware: Codex's
# app-server daemon and Claude Desktop are not sessions).
#
# On an interactive console the operator is first offered the chance to stop the blocking
# sessions (never this shell's own ancestry); whatever stays running still defers.
$agentNames = @('opencode', 'claude', 'codex', 'agy', 'serena')
$ancestorWatch = [System.Diagnostics.Stopwatch]::StartNew()
$ancestorIds = @(Get-AncestorProcessId)
if ($ancestorWatch.Elapsed.TotalSeconds -gt 2) {
    Write-Host ("    finding this shell's own processes took {0:N1}s" -f $ancestorWatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
}
$stoppedSessions = @(Invoke-LiveSessionStop -Name $agentNames -ExcludeId $ancestorIds)
if ($stoppedSessions.Count -gt 0) { Start-Sleep -Seconds 1 }
Add-DotTimingMark -Name 'Codex daemon and defer scan'
# Codex's app-server daemon is not a session but keeps running the release it started with;
# with no Codex session left it is stopped so the next start is the upgraded version.
if (-not (Test-LiveProcess @('codex'))) {
    $daemonsStopped = Stop-CodexDaemon
    if ($daemonsStopped -gt 0) { Write-Host "  Stopped Codex's app-server daemon (it restarts on demand, on the new version)." -ForegroundColor Yellow }
}
$defer = @()
if (Test-LiveProcess @('codex'))  { $defer += 'codex' }
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
if ($dropDesktopShortcuts) { $shortcutsBefore = @(Get-DesktopShortcutBaseline) }

Add-DotTimingMark -Name 'network check'
# A slow link (under DOT_SLOW_MBPS, default 50 Mbit/s) is said up front; the operator may leave the
# big downloaders (choco, winget) out of this run or stop. --yes and an unanswered question continue.
$networkChoice = Invoke-DotNetworkCheck
if ($networkChoice -eq 'stop') {
    Write-Host "  Stopped at your request - nothing was upgraded. Re-run when the connection is better." -ForegroundColor Yellow
    exit 0
}
$skipPackageSweeps = ($networkChoice -eq 'skip')

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
# Where Docker Desktop ran from, kept so the run can start it again when it was the one to stop it.
$dockerExePath = ''
$dockerStopped = $false
if (-not $skipPackageSweeps -and @(Get-DockerDesktopProcess).Count -gt 0) {
    try { $dockerExePath = [string](@(Get-DockerDesktopProcess)[0].Path) } catch { $dockerExePath = '' }
    $dockerPendingVersion = Get-DockerDesktopUpgrade -Owner $dockerOwner
    if ($dockerPendingVersion) {
        $dockerKept = -not (Invoke-DockerDesktopStopOffer -Version $dockerPendingVersion -ExcludeId @(Get-AncestorProcessId))
        $dockerStopped = -not $dockerKept
    }
}

Add-DotTimingMark -Name 'choco'
# --- 1. System packages: the choco upgrade all this command replaces. ---
if ($skipPackageSweeps) {
    Write-Host "  Skipping choco packages (slow network, your choice)." -ForegroundColor Yellow
} elseif (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Host "  Upgrading choco packages (choco upgrade all)..." -ForegroundColor Yellow
    $chocoArguments = @(Get-ChocoUpgradeArgument -KeepDockerDesktop:$dockerKept)
    if (($chocoArguments -join ' ') -match '--except=\S*claude') {
        Write-Host "  claude (Desktop) left out of this sweep - a claude.exe is running, and the package's installer force-kills every claude.exe (Claude Code sessions included). Close them and re-run to take it." -ForegroundColor Yellow
    }
    $null = Invoke-ChocoUpgradeAll -Arguments $chocoArguments   # it prints its own warning on a non-zero exit
} else {
    Write-Host "  choco not found - skipping system packages." -ForegroundColor Yellow
}

Add-DotTimingMark -Name 'VS Code'
# --- VS Code: same story as Docker Desktop - its installer refuses to run while Code.exe is up
# (exit code 1, and a bare "Still pending" afterwards). Checked HERE, right before the winget sweep
# and not at the start: the choco sweep above takes minutes, and VS Code can be opened meanwhile
# (2026-10-10: the early check saw nothing and the installer then ran into a running VS Code).
# Probed only when VS Code is running; the offer closes it (--yes answers it), or the sweep holds
# VS Code out and says why. A probe that finds nothing while VS Code runs also holds it out:
# a held package with no upgrade pending costs nothing, a failed installer costs a re-run.
$vsCodeKept = $false
$vsCodePendingVersion = ''
if (-not $skipPackageSweeps -and @(Get-Process -Name 'Code' -ErrorAction SilentlyContinue).Count -gt 0 -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    $vsCodePendingVersion = Get-WingetPackageUpgrade -Id 'Microsoft.VisualStudioCode'
    if ($vsCodePendingVersion) { $vsCodeKept = -not (Invoke-VsCodeUpgradeOffer -Version $vsCodePendingVersion -ExcludeId @(Get-AncestorProcessId)) }
    else { $vsCodeKept = $true }
}

Add-DotTimingMark -Name 'winget'
# --- 1a. winget-managed apps (Build Tools, ChatGPT Work/Codex msstore,
# Win-CodexBar): same full-sweep premise as choco - upgrade everything
# winget knows, not just what this repo installed. --include-unknown: apps
# with undetermined installed versions are skipped without it.
if ($skipPackageSweeps) {
    Write-Host "  Skipping winget packages (slow network, your choice)." -ForegroundColor Yellow
} elseif (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host "  Upgrading winget packages (winget upgrade --all)..." -ForegroundColor Yellow
    # Node stays on versions.node_major, like Linux/WSL and macOS (read now, so a bump in the repo
    # moves Windows on the next run without waiting for the installer).
    $nodeMajor = 0
    try { $nodeMajor = [int]((chezmoi execute-template '{{ .versions.node_major }}' | Out-String).Trim()) } catch { Write-Verbose "node_major probe failed: $($_.Exception.Message)" }
    if ($nodeMajor -gt 0 -and -not (Set-NodeLtsPin -Major $nodeMajor)) {
        Write-Host "  Warning: could not pin Node.js to $nodeMajor.x in winget - it may move to a newer LTS" -ForegroundColor Yellow
    }
    $wingetRunningNotes = @()
    if ($dockerKept) { $wingetRunningNotes += "Docker Desktop $dockerPendingVersion waits because Docker Desktop is running: close it and re-run, or run: winget upgrade Docker.DockerDesktop" }
    if ($vsCodeKept) { $wingetRunningNotes += "VS Code$(if ($vsCodePendingVersion) { " $vsCodePendingVersion" }) waits because VS Code is running: close it and re-run, or run: winget upgrade Microsoft.VisualStudioCode" }
    $wingetRunningNote = $wingetRunningNotes -join ' '
    $wingetHold = @()
    if ($dockerKept) { $wingetHold += 'Docker.DockerDesktop' }   # running: its installer would fail mid-sweep
    if ($vsCodeKept) { $wingetHold += 'Microsoft.VisualStudioCode' }   # running: Inno Setup exits 1
    # A live opencode session holds its binary open; replacing it races the running process.
    if (@($defer) -contains 'opencode') { $wingetHold += 'SST.opencode' }
    # Claude Desktop and Claude Code share the process name claude.exe, and its installer closes
    # claude.exe (Chocolatey's force-killed every one, Claude Code sessions included). While any
    # OTHER one runs, Claude Desktop waits for the next run - the same rule the choco sweep keeps.
    # $ancestorIds excludes THIS shell's own ancestry: a `dot upgrade` run from a Claude Code
    # session is itself a claude.exe, and counting it held Claude Desktop out of every single
    # run regardless of whether Claude Desktop (or any other session) was actually open
    # (2026-10-11) - the live-session scan above already offered to close everything else.
    # Probed for a pending upgrade first, like Docker Desktop/VS Code above: a claude.exe simply
    # being open held Claude Desktop out (and warned about it) on every run even when nothing was
    # going to be upgraded anyway (2026-10-11 live log: the warning printed right before "Nothing
    # to upgrade in winget").
    if (@(Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $ancestorIds -notcontains $_.Id }).Count -gt 0) {
        $claudeDesktopPendingVersion = Get-WingetPackageUpgrade -Id 'Anthropic.Claude'
        if ($claudeDesktopPendingVersion) {
            $wingetHold += 'Anthropic.Claude'
            Write-Host "  Claude Desktop $claudeDesktopPendingVersion held out of this sweep - a claude.exe is running and its installer closes every claude.exe (Claude Code sessions included). Close them and re-run to take it." -ForegroundColor Yellow
        }
    }
    $null = Invoke-WingetUpgradeAll -RunningNote $wingetRunningNote -HoldId $wingetHold   # it prints its own summary and warnings
} else {
    Write-Host "  winget not found - skipping winget packages." -ForegroundColor Yellow
}

Add-DotTimingMark -Name 'WSL'
# --- 1a2. WSL updates itself: no package manager owns it (catalog note on wsl2). A running distro
# keeps the old version until WSL restarts; nothing is shut down here.
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    Write-Host "  Updating WSL (wsl --update)..." -ForegroundColor Yellow
    $previousWslUtf8 = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'   # wsl.exe writes UTF-16 otherwise (a NUL between every letter)
    # Shown as it arrives, with a "still running" line: a real update took 3 minutes (2026-10-12) with
    # nothing printed until it ended, which looked like a hang.
    $wslBeat = Open-DotHeartbeat -Tool 'wsl --update'
    try {
        & wsl.exe --update 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | ForEach-Object {
            Write-Host "  $_"
            $wslBeat.State.Quiet.Restart()
        }
        if ($LASTEXITCODE -ne 0) { Write-Host "  wsl --update exited with code $LASTEXITCODE - continuing" -ForegroundColor Yellow }
    } finally {
        Close-DotHeartbeat -Beat $wslBeat
        $env:WSL_UTF8 = $previousWslUtf8
    }
}

Add-DotTimingMark -Name 'VS Code extensions'
# --- 1b. VS Code extensions: `dot up` only installs missing ones (no --force); updates are
# this command's job. Skipped quietly when VS Code is absent; a failure never aborts.
# Run in the background, alongside the AI tools below (nothing after it depends on it); waited
# for, with a 5-minute limit, before the summary.
# What `code --update-extensions` did, in one line: "up to date", "N updated" with the names,
# or its output when neither can be read. It used to print nothing on success, so a run never
# said whether anything moved.
function Write-VSCodeExtensionsReport {
    param([string[]]$Lines)
    $text = @($Lines | Where-Object { $_ -and $_ -notmatch 'DeprecationWarning|trace-deprecation' })
    if (@($text | Where-Object { $_ -match 'No extension to update' }).Count -gt 0) {
        Write-Host "  VS Code extensions: up to date"
        return
    }
    $updated = @()
    foreach ($l in $text) { if ($l -match "Extension '([^']+)' (v\S+) was successfully (updated|installed)") { $updated += "$($Matches[1]) $($Matches[2])" } }
    if ($updated.Count -gt 0) {
        Write-Host "  VS Code extensions: $($updated.Count) updated - $($updated -join ', ')"
    } else {
        Write-Host "  VS Code extensions: updated"
        $text | ForEach-Object { Write-Host "    $_" }
    }
}

$vsCodeExtensionUpdate = $null
$vsCodeExtOut = $null
$vsCodeExtErr = $null
$codeCommand = Get-Command code -ErrorAction SilentlyContinue
if ($codeCommand) {
    Write-Host "  Updating VS Code extensions (in the background)..." -ForegroundColor Yellow
    try {
        $vsCodeExtOut = [IO.Path]::GetTempFileName()
        $vsCodeExtErr = [IO.Path]::GetTempFileName()
        $vsCodeExtensionUpdate = Start-Process -FilePath $codeCommand.Source -ArgumentList '--update-extensions' -WindowStyle Hidden -PassThru -RedirectStandardOutput $vsCodeExtOut -RedirectStandardError $vsCodeExtErr
        # Windows PowerShell 5.1 (.NET Framework - what `dot upgrade` actually runs under;
        # PowerShell 7/pwsh never showed this in testing): Start-Process -PassThru never turns on
        # the Process object's exited-event bookkeeping, and without it .ExitCode stays
        # unreadable forever even once HasExited is already true ("exited with code  -
        # continuing", 2026-10-12 and again 2026-10-13 after an unrelated fix). Confirmed by
        # reproducing it directly under powershell.exe, not pwsh (2026-10-13); EnableRaisingEvents
        # turns that bookkeeping on and is the actual fix - set before any wait, since the
        # process could in principle exit before this line runs otherwise.
        $vsCodeExtensionUpdate.EnableRaisingEvents = $true
    } catch {
        Write-Host "  VS Code extension update did not start ($($_.Exception.Message)) - continuing" -ForegroundColor Yellow
    }
}

Add-DotTimingMark -Name 'AI tools'
# --- 2. AI tools: the update_ai_tools section, defer-aware. ---
& (Join-Path $PSScriptRoot 'update_ai_tools.ps1')

if ($vsCodeExtensionUpdate) {
    Add-DotTimingMark -Name 'VS Code extensions (waiting)'
    if (-not $vsCodeExtensionUpdate.WaitForExit(300000)) {
        Write-Host "  VS Code extension update still running after 5 minutes - left to finish on its own" -ForegroundColor Yellow
    } else {
        # Redirected output: WaitForExit(Int32) can return before ExitCode (and the redirected
        # streams) have actually settled - .NET's own documented caveat for this overload - so
        # the parameterless overload (which blocks until that settles, returning at once since
        # the process has already exited) runs before ExitCode is read.
        $vsCodeExtensionUpdate.WaitForExit()
        # The real cause of the blank exit code (above: EnableRaisingEvents) should keep this
        # branch from firing at all now. Kept as a fallback - ExitCode still $null for some
        # other reason reports itself as unreadable instead of printing blank.
        $vsCodeExitCode = $vsCodeExtensionUpdate.ExitCode
        if ($vsCodeExitCode -eq 0) {
            $vsCodeExtLines = @()
            foreach ($f in @($vsCodeExtOut, $vsCodeExtErr)) { if ($f -and (Test-Path -LiteralPath $f)) { $vsCodeExtLines += @(Get-Content -LiteralPath $f) } }
            Write-VSCodeExtensionsReport -Lines $vsCodeExtLines
        } else {
            $why = if ($null -eq $vsCodeExitCode) { "exited, but its exit code could not be read" } else { "exited with code $vsCodeExitCode" }
            Write-Host "  VS Code extension update $why - continuing" -ForegroundColor Yellow
            if ($vsCodeExtErr -and (Test-Path -LiteralPath $vsCodeExtErr)) { Get-Content -LiteralPath $vsCodeExtErr | Where-Object { $_ } | ForEach-Object { Write-Host "    $_" } }
        }
    }
    foreach ($f in @($vsCodeExtOut, $vsCodeExtErr)) { if ($f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
}

# Docker Desktop was stopped for its upgrade (its containers with them): start it again, after the
# sweeps and the WSL update that it depends on. Containers with a restart policy come back with it.
if ($dockerStopped) {
    Add-DotTimingMark -Name 'Docker Desktop restart'
    if (Resume-DockerDesktop -Path $dockerExePath) {
        Write-Host "  Docker Desktop started again (it was stopped for its upgrade)." -ForegroundColor Green
    } else {
        Write-Host "  Docker Desktop was stopped for its upgrade and could not be started again from here: start it from the Start menu." -ForegroundColor Yellow
    }
}

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
