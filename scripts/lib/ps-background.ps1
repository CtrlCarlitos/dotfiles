# scripts/lib/ps-background.ps1 - run independent update sections side by side, print them in order.
#
# `dot upgrade` ran its AI-tool updates one after another: Playwright 18 s, agent-browser 13 s, Serena
# 13 s, Superpowers 12 s, Claude Code 9 s, Superpowers (OpenCode) 7 s - 1m43s in a run where each step
# only waits for the network. Most of them touch nothing the others touch, so they can overlap.
#
# A section of scripts/update_ai_tools.ps1 is the text between two `Add-DotTimingMark -Name '...'` lines.
# Invoke-DotBackgroundUnit starts a second copy of that script with -OnlySection <names>; the copy runs
# just those sections (Get-DotSectionText) and writes what they print to its stdout. The sections stay
# where they are, each opened with `if (-not (Show-DotBackgroundSection '<name>')) {`: when a unit
# started for that name, Show-DotBackgroundSection waits for it and replays its output right there (so
# the output reads in the same order as a serial run) and the body is skipped; when none did - the
# knob is off, the copy would not start - it runs in place, exactly as before. In the copy no unit is
# registered, so the same line lets the body run.
#
# The copy writes through Write-DotBackgroundHost (an alias for Write-Host there): every call becomes
# one record line, so the colours survive the trip. Anything else it prints (native tool output) is a
# plain line and replays as plain text. No prompt may live in a section started this way: the copy has
# no console input.
#
#   DOT_PARALLEL_AI_TOOLS=0   run everything in order, in this process (debugging)
#
# Dot-sourced by scripts/lib/ps-common.ps1 for update_ai_tools.ps1; tests/dot_upgrade_parallel_contract.sh
# executes it. Nothing here may depend on the rest of ps-common.ps1 but Stop-ProcessTree.
$script:DotBackgroundUnits = @{}
$script:DotBackgroundLog = ''
$script:DotBackgroundMark = [string][char]0x1e
$script:DotBackgroundNewline = [string][char]0x1f

# What Write-Host does in a background copy: one record line "<RS>H<RS>color<RS>N|L<RS>text".
function Write-DotBackgroundHost {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object,
        [string]$ForegroundColor = '',
        [string]$BackgroundColor = '',
        [switch]$NoNewline,
        [object]$Separator = ' '
    )
    $null = $BackgroundColor   # accepted so callers can pass it; the replay does not use it
    $text = (@($Object | ForEach-Object { "$_" }) -join "$Separator") -replace "`r?`n", $script:DotBackgroundNewline
    $ending = 'L'
    if ($NoNewline) { $ending = 'N' }
    $mark = $script:DotBackgroundMark
    [Console]::Out.WriteLine($mark + 'H' + $mark + $ForegroundColor + $mark + $ending + $mark + $text)
}

# In the background copy, before each section it runs: tells the replay where that section's output starts.
function Write-DotBackgroundSectionStart {
    param([Parameter(Mandatory)][string]$Name)
    $mark = $script:DotBackgroundMark
    [Console]::Out.WriteLine($mark + 'S' + $mark + $Name)
}

# The sections of a script by timing mark: name -> its text (the lines after the mark, up to the next one).
function Get-DotSectionText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Name)
    $result = [ordered]@{}
    $current = ''
    $buffer = New-Object System.Collections.Generic.List[string]
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match "^Add-DotTimingMark -Name '([^']+)'\s*$") {
            if ($current -and ($Name -contains $current)) { $result[$current] = ($buffer -join "`n") }
            $current = $Matches[1]
            $buffer.Clear()
            continue
        }
        if ($current) { $buffer.Add($line) }
    }
    if ($current -and ($Name -contains $current)) { $result[$current] = ($buffer -join "`n") }
    return $result
}

# Start a second copy of <Script> for <Section> names. $false when it did not start (the sections then
# run in place).
function Invoke-DotBackgroundUnit {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string[]]$Section,
        [int]$TimeoutSeconds = 900
    )
    if ($env:DOT_PARALLEL_AI_TOOLS -eq '0') { return $false }
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Script + '" -OnlySection "' + ($Section -join '|') + '"'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $process.StandardInput.Close()
        $unit = [pscustomobject]@{
            Process = $process
            Out = $process.StandardOutput.ReadToEndAsync()
            Err = $process.StandardError.ReadToEndAsync()
            Started = [DateTime]::UtcNow
            Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            Sections = $Section
            Parsed = $null
        }
        foreach ($name in $Section) { $script:DotBackgroundUnits[$name] = $unit }
        return $true
    } catch {
        Write-Verbose "background start failed: $($_.Exception.Message)"
        return $false
    }
}

# Wait for the unit, split what it printed into one list of records per section, note its time in the log.
function Wait-DotBackgroundUnit {
    param([Parameter(Mandatory)]$Unit)
    $remaining = [int][Math]::Max(1, ($Unit.Deadline - [DateTime]::UtcNow).TotalMilliseconds)
    $timedOut = -not $Unit.Process.WaitForExit($remaining)
    if ($timedOut) {
        try { Stop-ProcessTree -Id $Unit.Process.Id } catch { Write-Verbose "stopping the background copy failed: $($_.Exception.Message)" }
        $null = $Unit.Process.WaitForExit(5000)
    } else {
        $Unit.Process.WaitForExit()
    }
    $text = ''
    if ($Unit.Out.Wait(5000)) { $text = $Unit.Out.Result }
    $errorText = ''
    if ($Unit.Err.Wait(5000)) { $errorText = $Unit.Err.Result }
    $groups = @{}
    $current = $Unit.Sections[0]
    $groups[$current] = New-Object System.Collections.Generic.List[string]
    $mark = $script:DotBackgroundMark
    $started = 0
    $allLines = @($text -split "`r?`n")
    while ($allLines.Count -gt 0 -and -not $allLines[$allLines.Count - 1]) { $allLines = @($allLines | Select-Object -First ($allLines.Count - 1)) }
    foreach ($line in $allLines) {
        if ($line.StartsWith($mark + 'S' + $mark)) {
            $started++
            $current = $line.Substring(3)
            if (-not $groups.ContainsKey($current)) { $groups[$current] = New-Object System.Collections.Generic.List[string] }
            continue
        }
        if ($line -or $groups[$current].Count -gt 0) { $groups[$current].Add($line) }
    }
    $seconds = ([DateTime]::UtcNow - $Unit.Started).TotalSeconds
    $exitCode = 0
    if (-not $timedOut) { $exitCode = $Unit.Process.ExitCode }
    $Unit.Parsed = [pscustomobject]@{ Groups = $groups; ErrorText = $errorText; TimedOut = $timedOut; ExitCode = $exitCode; Seconds = $seconds; Started = $started; ErrorShown = $false }
}

function Write-DotBackgroundRecord {
    param([string]$Line)
    $mark = $script:DotBackgroundMark
    if (-not $Line.StartsWith($mark + 'H' + $mark)) { Write-Host $Line; return }
    $parts = $Line.Substring(3).Split([char]0x1e)
    $color = $parts[0]
    $noNewline = ($parts[1] -eq 'N')
    $text = ($parts[2..($parts.Count - 1)] -join $mark) -replace [regex]::Escape($script:DotBackgroundNewline), "`n"
    $arguments = @{ Object = $text }
    if ($color) { $arguments['ForegroundColor'] = $color }
    if ($noNewline) { $arguments['NoNewline'] = $true }
    Write-Host @arguments
}

# $true when a unit ran <Name> - its output is shown here, so the caller skips the body; $false when the
# caller must run the section itself.
function Show-DotBackgroundSection {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:DotBackgroundUnits.ContainsKey($Name)) { return $false }
    $unit = $script:DotBackgroundUnits[$Name]
    if (-not $unit.Parsed) { Wait-DotBackgroundUnit -Unit $unit }
    $result = $unit.Parsed
    # A copy that died before it began any section did none of its work: say so, and let the caller run
    # the section here instead of skipping it.
    if (-not $result.TimedOut -and $result.ExitCode -ne 0 -and $result.Started -eq 0) {
        foreach ($errorLine in ($result.ErrorText -split "`r?`n" | Where-Object { $_ })) { Write-Host "  $errorLine" -ForegroundColor Red }
        Write-Host "  Warning: the background copy for $($unit.Sections -join ' / ') failed (exit code $($result.ExitCode)) - running it here" -ForegroundColor Yellow
        foreach ($sectionName in $unit.Sections) { $script:DotBackgroundUnits.Remove($sectionName) }
        return $false
    }
    if ($result.Groups.ContainsKey($Name)) {
        foreach ($line in $result.Groups[$Name]) { Write-DotBackgroundRecord -Line $line }
    }
    $isLast = ($Name -eq $unit.Sections[$unit.Sections.Count - 1])
    if ($isLast -and -not $result.ErrorShown) {
        $result.ErrorShown = $true
        foreach ($errorLine in ($result.ErrorText -split "`r?`n" | Where-Object { $_ })) { Write-Host "  $errorLine" -ForegroundColor Red }
        if ($result.TimedOut) {
            Write-Host "  Warning: $($unit.Sections -join ' / ') did not finish in time - stopped" -ForegroundColor Red
        } elseif ($result.ExitCode -ne 0) {
            Write-Host "  Warning: $($unit.Sections -join ' / ') ended with exit code $($result.ExitCode)" -ForegroundColor Red
        }
        # Its own time, for the log: the section's timing mark only counts the wait for it.
        try {
            $logPath = $script:DotBackgroundLog
            if (-not $logPath) { $logPath = Join-Path $HOME '.local\state\dotfiles\upgrade.log' }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null
            Add-Content -LiteralPath $logPath -Value ("=== {0} background {1} ran {2}" -f (Get-Date -Format s), ($unit.Sections -join ' + '), (Format-DotDuration -Seconds $result.Seconds))
        } catch { Write-Verbose "background timing log unavailable: $($_.Exception.Message)" }
    }
    return $true
}
