# scripts/lib/ps-timing.ps1 - where the time of a run goes. Twin of scripts/lib/timing.sh.
#
# A Windows `dot upgrade` took 13m03s and nothing said which part. The scripts put a mark at the
# start of each section; the end of the run prints the slowest ones and appends the same line to
# ~\.local\state\dotfiles\upgrade.log, so one run can be compared with the next.
#   Add-DotTimingMark -Name <n>      the previous section ends now, <n> starts now
#   Write-DotTimingSummary -Title t  close the open section, print "Timings (t, total): ..."
# Only sections of $env:DOT_TIMING_MIN_SECONDS (default 5) or more are listed, slowest first, at
# most six; the total always is.
#
# Two consumers, two ways in: scripts/lib/ps-common.ps1 dot-sources this file (dot upgrade:
# dotupgrade.ps1 and update_ai_tools.ps1 take it from there, and Read-DotAnswer there uses the
# marks to keep prompt time out of the work it interrupted); the Windows installer template
# inlines it with `{{ include }}` (it never dot-sources ps-common.ps1 - it renders as one
# self-contained script). Nothing here may depend on anything else in ps-common.ps1.
# tests/upgrade_timing_contract.sh executes it against a fake clock and pins both wirings.
$script:DotTimingNames = New-Object System.Collections.Generic.List[string]
$script:DotTimingSeconds = New-Object System.Collections.Generic.List[double]
$script:DotTimingLast = ''
$script:DotTimingFrom = [DateTime]::MinValue
$script:DotTimingStart = [DateTime]::MinValue

function Get-DotTimingNow { return [DateTime]::UtcNow }

function Add-DotTimingMark {
    param([Parameter(Mandatory)][string]$Name)
    $now = Get-DotTimingNow
    if ($script:DotTimingStart -eq [DateTime]::MinValue) { $script:DotTimingStart = $now }
    if ($script:DotTimingLast) {
        $script:DotTimingNames.Add($script:DotTimingLast)
        $script:DotTimingSeconds.Add(($now - $script:DotTimingFrom).TotalSeconds)
    }
    $script:DotTimingLast = $Name
    $script:DotTimingFrom = $now
}

# 125 -> 2m05s, 45 -> 45s
function Format-DotDuration {
    param([Parameter(Mandatory)][double]$Seconds)
    $whole = [int][math]::Floor($Seconds)
    if ($whole -ge 60) { return ('{0}m{1:00}s' -f [math]::Floor($whole / 60), ($whole % 60)) }
    return ('{0}s' -f $whole)
}

function Write-DotTimingSummary {
    param([string]$Title = 'run', [string]$LogPath)
    $now = Get-DotTimingNow
    if ($script:DotTimingLast) {
        $script:DotTimingNames.Add($script:DotTimingLast)
        $script:DotTimingSeconds.Add(($now - $script:DotTimingFrom).TotalSeconds)
        $script:DotTimingLast = ''
    }
    if ($script:DotTimingNames.Count -eq 0) { return }
    $min = 5
    if ($env:DOT_TIMING_MIN_SECONDS -and $null -ne ($env:DOT_TIMING_MIN_SECONDS -as [int])) { $min = [int]$env:DOT_TIMING_MIN_SECONDS }
    # a section can recur (work resumes after "your answers"): its parts add up
    $sums = [ordered]@{}
    for ($i = 0; $i -lt $script:DotTimingNames.Count; $i++) {
        $name = $script:DotTimingNames[$i]
        if ($sums.Contains($name)) { $sums[$name] += $script:DotTimingSeconds[$i] } else { $sums[$name] = $script:DotTimingSeconds[$i] }
    }
    $rows = @()
    foreach ($name in $sums.Keys) {
        if ($sums[$name] -ge $min) { $rows += [pscustomobject]@{ Name = $name; Seconds = $sums[$name] } }
    }
    $top = @($rows | Sort-Object -Property Seconds -Descending | Select-Object -First 6 |
        ForEach-Object { '{0} {1}' -f $_.Name, (Format-DotDuration -Seconds $_.Seconds) })
    $total = Format-DotDuration -Seconds ($now - $script:DotTimingStart).TotalSeconds
    $text = "Timings ($Title, $total)"
    if ($top.Count -gt 0) { $text += ': ' + ($top -join ', ') }
    Write-Host "  $text"
    if (-not $LogPath) { $LogPath = Join-Path $HOME '.local\state\dotfiles\upgrade.log' }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
        Add-Content -LiteralPath $LogPath -Value ("=== {0} {1}" -f (Get-Date -Format s), $text)
    }
    catch { Write-Verbose "timing log unavailable: $($_.Exception.Message)" }
    $script:DotTimingNames.Clear()
    $script:DotTimingSeconds.Clear()
    $script:DotTimingStart = [DateTime]::MinValue
}
