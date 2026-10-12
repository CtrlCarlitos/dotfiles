# scripts/lib/ps-heartbeat.ps1 - a 'still working' line and per-package times for long installs.
#
# Shared by the sweeps in scripts/lib/ps-common.ps1 (dot upgrade) and, inlined with {{ include }}, by
# the Windows installer template (dot up), which never dot-sources ps-common.ps1. Needs only
# Format-DotDuration from scripts/lib/ps-timing.ps1, which both consumers load first.
# A sweep prints nothing while an installer downloads: a 21-minute Ollama upgrade (2026-10-11, slow
# ISP) looked like a hang. Open-DotHeartbeat starts a second runspace that writes
# "  <tool> is working on <package> (4m10s so far)..." straight to the console whenever the sweep has
# printed nothing for DOT_HEARTBEAT_SECONDS (default 30; 0 = off; DOT_WINGET_HEARTBEAT_SECONDS is the
# older name, still read). The sweep sets $beat.State.Package and calls $beat.State.Quiet.Restart()
# after every line it shows; Close-DotHeartbeat ends it.
function Get-DotHeartbeatInterval {
    foreach ($value in @($env:DOT_HEARTBEAT_SECONDS, $env:DOT_WINGET_HEARTBEAT_SECONDS)) {
        if ("$value" -match '^\d+$') { return [int]$value }
    }
    return 30
}

function Open-DotHeartbeat {
    param([Parameter(Mandatory)][string]$Tool)
    $state = [hashtable]::Synchronized(@{ Stop = $false; Quiet = [System.Diagnostics.Stopwatch]::StartNew(); Total = [System.Diagnostics.Stopwatch]::StartNew(); Package = '' })
    $runspace = $null
    $handle = $null
    $every = Get-DotHeartbeatInterval
    if ($every -gt 0) {
        try {
            $runspace = [powershell]::Create()
            $null = $runspace.AddScript({
                param($State, $Every, $Tool)
                while (-not $State.Stop) {
                    Start-Sleep -Milliseconds 250
                    if ($State.Stop) { break }
                    if ($State.Quiet.Elapsed.TotalSeconds -ge $Every) {
                        $total = [int]$State.Total.Elapsed.TotalSeconds
                        $what = if ($State.Package) { "working on $($State.Package)" } else { 'still running' }
                        [Console]::WriteLine(('  {0} is {1} ({2}m{3:00}s so far)...' -f $Tool, $what, [math]::Floor($total / 60), ($total % 60)))
                        $State.Quiet.Restart()
                    }
                }
            }).AddArgument($state).AddArgument($every).AddArgument($Tool)
            $handle = $runspace.BeginInvoke()
        }
        catch { Write-Verbose "$Tool heartbeat unavailable: $($_.Exception.Message)"; $runspace = $null }
    }
    return [pscustomobject]@{ State = $state; Runspace = $runspace; Handle = $handle }
}

function Close-DotHeartbeat {
    param($Beat)
    if ($null -eq $Beat) { return }
    $Beat.State.Stop = $true
    if ($Beat.Runspace) {
        try { $null = $Beat.Runspace.EndInvoke($Beat.Handle) } catch { Write-Verbose "heartbeat ended badly: $($_.Exception.Message)" }
        $Beat.Runspace.Dispose()
    }
}

# Which package took the time, and whether it was the network (download) or the installer. Only the
# packages of 30 s or more are listed, on one line, also appended to upgrade.log.
# Package: objects with Name, Start, DownloadEnd, End (UTC DateTime or $null).
function Write-DotPackageTiming {
    param([Parameter(Mandatory)][string]$Tool, $Package, [string]$LogPath)
    # a foreach, not @($Package | ...): PowerShell 7 fails to bind @() over a List of custom objects
    $slow = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Package) {
        if (-not $entry -or -not $entry.End -or ($entry.End - $entry.Start).TotalSeconds -lt 30) { continue }
        $text = '{0} {1}' -f $entry.Name, (Format-DotDuration -Seconds ($entry.End - $entry.Start).TotalSeconds)
        if ($entry.DownloadEnd) { $text += ' (download {0}, install {1})' -f (Format-DotDuration -Seconds ($entry.DownloadEnd - $entry.Start).TotalSeconds), (Format-DotDuration -Seconds ($entry.End - $entry.DownloadEnd).TotalSeconds) }
        $slow.Add($text)
    }
    if ($slow.Count -eq 0) { return }
    $line = "$Tool packages: " + ($slow -join ', ')
    Write-Host "  $line"
    if ($LogPath) { Add-Content -LiteralPath $LogPath -Value ("=== {0} {1}" -f (Get-Date -Format s), $line) }
}
