#Requires -Version 5.1
<#
Behavioral test for `dot devdrive` (#227 follow-up): plan/create/measure in
scripts/devdrive.ps1. Runs on any pwsh and on Windows PowerShell 5.1; Windows
objects (volumes, partitions, fsutil, the Defender recording cmdlets) are
stubbed, so nothing here formats a volume, shrinks a partition, or touches
Defender. The Add/Remove/Set-MpPreference stubs are a trap that must never
fire: preference changes are printed, never run.
#>
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'scripts/lib/ps-common.ps1')

function Fail([string]$m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("devdrive-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Get-ScratchConfig([string]$Body) {
    $p = Join-Path $Tmp ([IO.Path]::GetRandomFileName() + '.toml')
    [IO.File]::WriteAllText($p, $Body, $Utf8NoBom)
    return $p
}

$env:DEVDRIVE_NO_MAIN = '1'
. (Join-Path $RepoRoot 'scripts/devdrive.ps1')

# --- stubs: volume state, the destructive cmdlets, fsutil, the recording.
$script:calls = New-Object System.Collections.Generic.List[string]
$script:mpCalls = New-Object System.Collections.Generic.List[string]
$script:volumes = @(
    @{ Letter = 'C'; Fs = 'NTFS' }
    @{ Letter = 'E'; Fs = 'NTFS' }
)
$script:trusted = @{}                 # letter -> $true/$false
$script:fsutilWorks = $false          # non-admin: query denied
$script:isAdmin = $false
$script:srcSize = 2TB
$script:srcMin = 50GB
$script:exclusions = @()
$script:reportRows = @('go.exe', 'MrKnee - the row the report must carry')
$script:recordedTo = ''

function global:Get-Volume {
    [CmdletBinding()] param([char]$DriveLetter)
    foreach ($v in $script:volumes) { if ($v.Letter[0] -eq $DriveLetter) {
        return [pscustomobject]@{ DriveLetter = $DriveLetter; FileSystemType = $v.Fs; FileSystemLabel = 'stub' }
    } }
    return $null
}
function global:Get-Partition {
    [CmdletBinding()] param([char]$DriveLetter)
    [pscustomobject]@{ DriveLetter = $DriveLetter; DiskNumber = 1; PartitionNumber = 3; Size = $script:srcSize }
}
function global:Get-PartitionSupportedSize {
    [CmdletBinding()] param([int]$DiskNumber, [int]$PartitionNumber)
    if ($DiskNumber -le 0 -or $PartitionNumber -le 0) { throw "no such partition $DiskNumber`:$PartitionNumber" }
    [pscustomobject]@{ SizeMin = $script:srcMin; SizeMax = $script:srcSize }
}
function global:Resize-Partition {
    [CmdletBinding()] param([char]$DriveLetter, [long]$Size)
    $script:calls.Add("shrink $DriveLetter to $Size")
}
function global:New-Partition {
    [CmdletBinding()] param([int]$DiskNumber, [switch]$UseMaximumSize, [char]$DriveLetter)
    $script:calls.Add("new-partition disk=$DiskNumber letter=$DriveLetter max=$UseMaximumSize")
    [pscustomobject]@{ DriveLetter = $DriveLetter; PartitionNumber = 5 }
}
function global:Format-Volume {
    [CmdletBinding()] param([char]$DriveLetter, [switch]$DevDrive, [string]$NewFileSystemLabel)
    $script:calls.Add("format $DriveLetter devdrive=$DevDrive label=$NewFileSystemLabel")
}
function global:fsutil {
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    if ($Rest -contains 'trust') { $script:calls.Add(('fsutil ' + ($Rest -join ' '))); $global:LASTEXITCODE = 0; return }
    if (-not $script:fsutilWorks) { $global:LASTEXITCODE = 1; return 'Error 5: Access is denied.' }
    $letter = [string]($Rest | Select-Object -Last 1)
    $global:LASTEXITCODE = 0
    if ($script:trusted[$letter.TrimEnd('\', ':')]) { return 'This is a trusted developer volume.' }
    return 'This is not a developer volume.'
}
function global:New-MpPerformanceRecording {
    [CmdletBinding()] param([string]$RecordTo)
    $script:recordedTo = $RecordTo
    $script:calls.Add('record')
    # the real one blocks until Enter; the stub returns immediately
}
function global:Get-MpPerformanceReport {
    [CmdletBinding()] param([string]$Path, [int]$TopProcesses, [int]$TopFiles, [int]$TopExtensions)
    $script:lastReportArgs = "path=$Path top=$TopProcesses/$TopFiles/$TopExtensions"
    [pscustomobject]@{
        TopProcesses = @($script:reportRows | ForEach-Object { [pscustomobject]@{ ProcessPath = $_; TotalDuration = 1234 } })
        TopFiles     = @()
        TopExtensions = @()
    }
}
function global:Add-MpPreference { $script:mpCalls.Add('Add-MpPreference') }
function global:Remove-MpPreference { $script:mpCalls.Add('Remove-MpPreference') }
function global:Set-MpPreference { $script:mpCalls.Add('Set-MpPreference') }
function Test-DevDriveAdmin { $script:isAdmin }
function Get-DevDriveExclusionPath { $script:exclusions }
function Invoke-DevDriveWorkload {
    param([string]$BenchPath, [int]$Seconds)
    $script:lastBench = $BenchPath
    $script:calls.Add("workload $Seconds")
}

function Reset-DevDriveStub {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('devdrive stub state', 'reset')) {
        $script:calls.Clear(); $script:mpCalls.Clear(); $script:recordedTo = ''; $script:lastReportArgs = ''
        $script:volumes = @(@{ Letter = 'C'; Fs = 'NTFS' }, @{ Letter = 'E'; Fs = 'NTFS' })
        $script:trusted = @{}; $script:fsutilWorks = $false; $script:isAdmin = $false
        $script:srcSize = 2TB; $script:srcMin = 50GB; $script:exclusions = @()
    }
}
function Invoke-Dd([string[]]$Cmd) {
    $script:calls.Clear(); $script:mpCalls.Clear()
    $global:LASTEXITCODE = $null
    $out = & { Invoke-DevDrive -Arguments $Cmd } *>&1 | Out-String
    return $out
}

# --- [1] plan, no admin, NTFS-only: status + what create would do, changes nothing.
$out = Invoke-Dd @('plan')
if ($global:LASTEXITCODE -ne 0) { Fail "[1] plan exit code $global:LASTEXITCODE" }
if ($script:calls.Count -ne 0) { Fail "[1] plan must change nothing, did: $($script:calls -join '; ')" }
foreach ($needle in 'no Dev Drive', '100 GB', 'V:') {
    if ($out -notmatch [regex]::Escape($needle)) { Fail "[1] plan must mention '$needle', got:`n$out" }
}
Write-Host '  ok: plan reports status and the create plan, changes nothing'

# --- [2] plan with a trusted Dev Drive present: recognized, both spellings real.
Reset-DevDriveStub
$script:volumes += @{ Letter = 'V'; Fs = 'ReFS' }
$script:fsutilWorks = $true; $script:trusted['V'] = $true
$out = Invoke-Dd @('plan')
if ($out -notmatch [regex]::Escape('V: Dev Drive (trusted)')) { Fail "[2] a trusted Dev Drive must be listed, got:`n$out" }
Write-Host '  ok: plan recognizes a trusted Dev Drive'

# --- [3] create without admin: refused, nothing called.
Reset-DevDriveStub
$out = Invoke-Dd @('create')
if ($global:LASTEXITCODE -ne 1) { Fail "[3] create without admin must exit 1, got $global:LASTEXITCODE" }
if ($script:calls.Count -ne 0) { Fail "[3] create without admin must change nothing" }
if ($out -notmatch 'admin') { Fail "[3] create must say it needs an admin shell" }
Write-Host '  ok: create refuses without an admin shell'

# --- [4] create with -WhatIf: the whole plan, zero destructive calls.
Reset-DevDriveStub
$script:isAdmin = $true
$null = Invoke-DevDrive -Arguments @('create') -WhatIf
if ($script:calls.Count -ne 0) { Fail "[4] -WhatIf must run nothing, did: $($script:calls -join '; ')" }
$script:isAdmin = $false
Write-Host '  ok: create -WhatIf touches nothing'

# --- [5] create, admin + confirmed: shrink -> partition -> format -> trust, in order,
# and the shrink target is exactly (current size - requested GB).
Reset-DevDriveStub
$script:isAdmin = $true
$out = & { Invoke-DevDrive -Arguments @('create', '-SizeGB', '50') } *>&1 | Out-String
if ($global:LASTEXITCODE -ne 0) { Fail "[5] create exit $global:LASTEXITCODE`n$out" }
$expected = @(
    ('shrink C to ' + (2TB - 50GB))
    'new-partition disk=1 letter=V max=True'
    'format V devdrive=True label=DevDrive'
    'fsutil devdrv trust V:'
)
if ($script:calls.Count -ne $expected.Count) {
    Fail "[5] call sequence: got $($script:calls.Count) steps ($($script:calls -join ' | ')), want $($expected.Count)"
}
for ($j = 0; $j -lt $expected.Count; $j++) {
    if ("$($script:calls[$j])" -ne "$($expected[$j])") {
        Fail "[5] step $($j+1): got '$($script:calls[$j])', want '$($expected[$j])'"
    }
}
$script:isAdmin = $false
Write-Host '  ok: create shrinks, partitions, formats and trusts in order'

# --- [6] create when the source cannot shrink enough: refused, nothing called.
Reset-DevDriveStub
$script:isAdmin = $true
$script:srcMin = 2TB - 10GB   # only 10 GB reclaimable
$out = & { Invoke-DevDrive -Arguments @('create') } *>&1 | Out-String
if ($global:LASTEXITCODE -ne 1) { Fail "[6] an impossible shrink must exit 1, got $global:LASTEXITCODE" }
if ($script:calls.Count -ne 0) { Fail "[6] an impossible shrink must change nothing" }
if ($out -notmatch 'shrink') { Fail "[6] the refusal must say why (shrink), got:`n$out" }
$script:isAdmin = $false
Write-Host '  ok: an impossible shrink is refused before anything runs'

# --- [7] the taken letter: create onto an in-use letter is refused.
Reset-DevDriveStub
$script:isAdmin = $true
$out = & { Invoke-DevDrive -Arguments @('create', '-Letter', 'E') } *>&1 | Out-String
if ($global:LASTEXITCODE -ne 1) { Fail "[7] an in-use letter must exit 1, got $global:LASTEXITCODE" }
if ($script:calls.Count -ne 0) { Fail "[7] an in-use letter must change nothing" }
$script:isAdmin = $false
Write-Host '  ok: an in-use drive letter is refused'

# --- [8] measure without devtmp configured: one pointer, exit 1.
Reset-DevDriveStub
$script:isAdmin = $true
$badCfg = Get-ScratchConfig "[data.packages]`ncore = true`n"
$out = & { Invoke-DevDrive -Arguments @('measure') -DevTmpConfigPath $badCfg } *>&1 | Out-String
if ($global:LASTEXITCODE -ne 1) { Fail "[8] measure without devtmp must exit 1, got $global:LASTEXITCODE" }
if ($out -notmatch 'devtmp') { Fail "[8] measure must point at dot devtmp" }
if ($script:calls.Count -ne 0) { Fail "[8] measure without devtmp must change nothing" }
$script:isAdmin = $false
Write-Host '  ok: measure without a configured devtmp folder points there and stops'

# --- [9] measure, configured: bench written, one recording, the report carries
# the TopProcesses rows, and any Defender exclusion is PRINTED (Remove-MpPreference
# as text), never run.
Reset-DevDriveStub
$script:isAdmin = $true
$script:exclusions = @('C:\dev\tmp')
$bench = Join-Path $Tmp 'bench'
$outDir = Join-Path $Tmp 'out'
$cfg = Get-ScratchConfig "[data.devtmp]`npath = 'C:/dev/tmp'`n"
$out = & { Invoke-DevDrive -Arguments @('measure', '-Seconds', '5') -DevTmpConfigPath $cfg -BenchPath $bench -OutDir $outDir } *>&1 | Out-String
if ($global:LASTEXITCODE -ne 0) { Fail "[9] measure exit $global:LASTEXITCODE`n$out" }
if ($script:mpCalls.Count -ne 0) { Fail "[9] a Defender preference change RAN: $($script:mpCalls -join '; ')" }
if ($out -notmatch [regex]::Escape('Remove-MpPreference -ExclusionPath')) { Fail "[9] the found exclusion must be printed as a command, got:`n$out" }
if (-not (Test-Path (Join-Path $bench 'go.mod'))) { Fail '[9] the bench module was not generated' }
$heavySrc = Join-Path $bench 'h00\h00.go'
if (-not (Test-Path $heavySrc)) { Fail '[9] the heavy package source is missing' }
if ((Get-Content $heavySrc -Raw) -notmatch 'net/http') { Fail '[9] the heavy package must link net/http' }
$pkgs = @(Get-ChildItem $bench -Directory).Count
if ($pkgs -lt 20) { Fail "[9] the bench must have the package set, found $pkgs" }
if ($script:calls -notcontains 'record') { Fail "[9] no recording was taken: $($script:calls -join '; ')" }
if ($script:calls -notcontains 'workload 5') { Fail "[9] the workload did not run for 5s: $($script:calls -join '; ')" }
$report = @(Get-ChildItem $outDir -Filter '*.txt')
if ($report.Count -ne 1) { Fail "[9] exactly one report txt expected, found $($report.Count)" }
$txt = Get-Content $report[0].FullName -Raw
if ($txt -notmatch [regex]::Escape('MrKnee - the row the report must carry')) { Fail "[9] the report must carry the TopProcesses rows, got:`n$txt" }
if ($txt -notmatch 'TotalDuration') { Fail "[9] the report must show the duration column" }
$script:isAdmin = $false
Write-Host '  ok: measure generates the bench, records once, prints (never runs) exclusions'

# --- [10] usage: unknown subcommand -> usage + exit 2, nothing changed.
Reset-DevDriveStub
$out = Invoke-Dd @('frobnicate')
if ($global:LASTEXITCODE -ne 2) { Fail "[10] unknown subcommand must exit 2, got $global:LASTEXITCODE" }
if ($out -notmatch 'usage') { Fail '[10] unknown subcommand must print usage' }
if ($script:calls.Count -ne 0) { Fail '[10] unknown subcommand must change nothing' }
Write-Host '  ok: usage errors are exit 2 and change nothing'

Remove-Item Env:\DEVDRIVE_NO_MAIN -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'PASS: devdrive plan/create/measure' -ForegroundColor Green
