#Requires -Version 5.1
<#
devdrive.ps1 - create and measure a Windows Dev Drive, the systematic half of
issue #227 (docs/devdrive.md; the quick win is `dot devtmp`). Windows only.
Reached as `dot devdrive` from both PowerShell profiles.

  dot devdrive                                   status + what create would do
  dot devdrive create [-SizeGB N] [-Letter X] [-FromDrive C]
                                                 ADMIN: shrink the source partition
                                                 online by N GB, create one partition
                                                 in the freed space, format it as a
                                                 Dev Drive (ReFS), trust it. Every
                                                 step behind ShouldProcess (-WhatIt
                                                 works); the partition route only -
                                                 no VHDX, no Windows features.
  dot devdrive measure [-Seconds N]              ADMIN: generate a Go bench module,
                                                 record a Defender performance trace
                                                 while it loops through
                                                 `dot devtmp run`, and write the
                                                 report. Needs [data.devtmp] first.

Defender preferences are NEVER changed here, not even printed-and-run: any
exclusion the report suggests cleaning up is PRINTED as a Remove-MpPreference
line for the user (tests/devdrive_contract.sh holds that line, the devtmp
rule). Recordings and reports (New-MpPerformanceRecording /
Get-MpPerformanceReport) are diagnostics and run only in `measure`, from the
user's admin shell. fsutil devdrv trust is volume attestation, part of create
and announced. Exit codes report through $global:LASTEXITCODE: 0 ok,
1 refused (not admin, letter taken, shrink impossible, devtmp unconfigured),
2 usage.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\ps-common.ps1')

# --- Seams: every side effect lives in one of these so tests/devdrive.ps1
# can replace them after dot-sourcing (DEVDRIVE_NO_MAIN=1).

function Test-DevDriveAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# One volume as a letter/fs pair, or $null. Probed per letter (C..Z) so the
# tests (and any host without the Storage module) see one cheap call per drive.
function Get-DevDriveVolume {
    param([Parameter(Mandatory)][char]$Letter)
    $v = Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue
    if ($v) { return [pscustomobject]@{ Letter = $Letter; FileSystemType = [string]$v.FileSystemType } }
    return $null
}

# Trusted per fsutil devdrv query - the authoritative answer, admin only.
# Non-admin (access denied) falls back to the ReFS tell-tale: 'maybe'.
function Test-DevDriveTrusted {
    param([Parameter(Mandatory)][char]$Letter)
    if (-not (Get-Command fsutil -ErrorAction SilentlyContinue)) { return 'maybe' }
    $ErrorActionPreference = 'Continue'
    $out = & fsutil devdrv query "$Letter`:" 2>$null
    $text = (@($out) -join ' ').ToLowerInvariant()
    if ($LASTEXITCODE -eq 0 -and $text -notmatch 'access is denied|error 5') {
        if ($text -match 'trusted developer volume|trusted dev drive') { return 'yes' }
        if ($text -match 'not a developer volume|not a dev drive') { return 'no' }
        return 'unknown'
    }
    return 'maybe'
}

function Invoke-DevDriveShrink {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][char]$Letter, [Parameter(Mandatory)][long]$TargetSize)
    if ($PSCmdlet.ShouldProcess("$Letter`:", "shrink the partition to $([int]($TargetSize/1GB)) GB (online, files untouched)")) {
        Resize-Partition -DriveLetter $Letter -Size $TargetSize
    }
}

function Invoke-DevDriveNewPartition {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$DiskNumber, [Parameter(Mandatory)][char]$Letter)
    if ($PSCmdlet.ShouldProcess("disk $DiskNumber", "create one partition in the freed space, letter $Letter")) {
        New-Partition -DiskNumber $DiskNumber -UseMaximumSize -DriveLetter $Letter
    }
}

function Invoke-DevDriveFormat {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][char]$Letter)
    if ($PSCmdlet.ShouldProcess("$Letter`:", 'format the NEW partition as a Dev Drive (ReFS)')) {
        Format-Volume -DriveLetter $Letter -DevDrive -NewFileSystemLabel DevDrive
    }
}

# Volume attestation: without it the async-AV policy is not honored. Announced,
# exit-checked, but not fatal - the verify step at the end tells the truth.
function Invoke-DevDriveTrust {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][char]$Letter)
    if ($PSCmdlet.ShouldProcess("$Letter`:", 'trust the Dev Drive (fsutil devdrv trust)')) {
        $ErrorActionPreference = 'Continue'
        & fsutil devdrv trust "$Letter`:"
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

# The bench: 20 small packages + 4 heavy ones (net/http, crypto/tls linked
# in), so every pass produces ~24 fresh unsigned test binaries - the workload
# whose Defender cost issue #227 measured. Sources only; no network.
function Write-DevDriveBench {
    param([Parameter(Mandatory)][string]$Path)
    $enc = New-Object System.Text.UTF8Encoding($false)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    [IO.File]::WriteAllText((Join-Path $Path 'go.mod'), "module devdrivebench`n`ngo 1.27`n", $enc)
    for ($i = 0; $i -lt 20; $i++) {
        $name = 'p{0:d2}' -f $i
        $dir = Join-Path $Path $name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $src = "package $name`n`nimport (`n    `"fmt`"`n    `"strconv`"`n    `"strings`"`n)`n`nfunc Label(n int) string {`n    parts := make([]string, 0, n)`n    for i := 0; i < n; i++ {`n        parts = append(parts, strconv.Itoa(i)+`"-`"+strings.Repeat(`"x`", i%7))`n    }`n    return strings.Join(parts, `",`")`n}`n`nfunc Describe(n int) string { return fmt.Sprintf(`"$name/%d: %s`", n, Label(n)) }`n"
        $test = "package $name`n`nimport (`n    `"strings`"`n    `"testing`"`n)`n`nfunc TestLabelNotEmpty(t *testing.T) {`n    if Label(12) == `"`" { t.Fatal(`"empty`") }`n}`n`nfunc TestLabelHasParts(t *testing.T) {`n    if !strings.Contains(Label(8), `"5-`") { t.Fatal(`"missing part`") }`n}`n"
        [IO.File]::WriteAllText((Join-Path $dir "$name.go"), $src, $enc)
        [IO.File]::WriteAllText((Join-Path $dir "$name`_test.go"), $test, $enc)
    }
    for ($i = 0; $i -lt 4; $i++) {
        $name = 'h{0:d2}' -f $i
        $dir = Join-Path $Path $name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $src = "package $name`n`nimport (`n    `"compress/gzip`"`n    `"crypto/tls`"`n    `"crypto/x509`"`n    `"net/http`"`n    `"text/template`"`n)`n`nvar (`n    _ = http.Get`n    _ = http.DefaultClient`n    _ = tls.ClientHelloInfo{}`n    _ = x509.CertPool{}`n    _ = gzip.BestCompression`n    _ = template.New`n)`n`nfunc Marker(n int) string { return `"$name`" }`n"
        $test = "package $name`n`nimport `"testing`"`n`nfunc TestMarker(t *testing.T) {`n    if Marker(1) != `"$name`" { t.Fatal(`"marker`") }`n}`n"
        [IO.File]::WriteAllText((Join-Path $dir "$name.go"), $src, $enc)
        [IO.File]::WriteAllText((Join-Path $dir "$name`_test.go"), $test, $enc)
    }
}

# The workload runs in its OWN window (the recording blocks this one until
# ENTER), looping `dot devtmp run go test` over the bench: warm once, then
# full -count=1 passes until -Seconds elapses.
function Invoke-DevDriveWorkload {
    param([Parameter(Mandatory)][string]$BenchPath, [Parameter(Mandatory)][int]$Seconds)
    $devtmp = Join-Path $PSScriptRoot 'devtmp.ps1'
    $loop = Join-Path (Split-Path -Parent $BenchPath) 'workload.ps1'
    $template = @'
param([string]$Dir, [int]$Seconds)
Set-Location $Dir
$devtmp = '__DEVTMP__'
$sw = [Diagnostics.Stopwatch]::StartNew()
$i = 0
& $devtmp run go test ./... | Out-Null
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    & $devtmp run go test -count=1 ./... | Out-Null
    $i++
    Write-Host ("  pass $i done (" + [int]$sw.Elapsed.TotalSeconds + "s)")
}
Write-Host 'WORKLOAD DONE - press ENTER in the recording window'
'@
    [IO.File]::WriteAllText($loop, $template.Replace('__DEVTMP__', $devtmp), (New-Object System.Text.ASCIIEncoding))
    Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $loop, '-Dir', $BenchPath, '-Seconds', "$Seconds")
}

function Invoke-DevDriveRecord {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if ($PSCmdlet.ShouldProcess($Path, 'record the Defender performance trace (ENTER stops and saves)')) {
        New-MpPerformanceRecording -RecordTo $Path
    }
}

function Get-DevDriveReportText {
    param([Parameter(Mandatory)][string]$EtlPath)
    $r = Get-MpPerformanceReport -Path $EtlPath -TopProcesses 10 -TopFiles 10 -TopExtensions 10
    $txt = New-Object System.Text.StringBuilder
    $null = $txt.AppendLine('devdrive (TopProcesses 10)')
    $null = $txt.AppendLine(($r.TopProcesses | Format-Table -AutoSize | Out-String -Width 240))
    $null = $txt.AppendLine('devdrive (TopFiles 10)')
    $null = $txt.AppendLine(($r.TopFiles | Format-Table -AutoSize | Out-String -Width 240))
    $null = $txt.AppendLine('devdrive (TopExtensions 10)')
    $null = $txt.AppendLine(($r.TopExtensions | Format-Table -AutoSize | Out-String -Width 240))
    return $txt.ToString()
}

function Get-DevDriveExclusionPath {
    try { return @((Get-MpPreference).ExclusionPath) } catch { return @() }
}

function Write-DevDriveUsage {
    Write-Host 'usage: dot devdrive [plan | create | measure] [options]'
    Write-Host '  plan                        print status and what create would do'
    Write-Host '  create [-SizeGB N] [-Letter X] [-FromDrive C]'
    Write-Host '                              ADMIN: shrink, create, format and trust the Dev Drive'
    Write-Host '  measure [-Seconds N]        ADMIN: bench + Defender recording + report (needs dot devtmp)'
}

function Invoke-DevDrive {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$Arguments = @(),
        [int]$SizeGB = 100,
        [string]$Letter = 'V',
        [string]$FromDrive = 'C',
        [int]$Seconds = 120,
        [string]$DevTmpConfigPath = '',
        [string]$BenchPath = '',
        [string]$OutDir = ''
    )
    $sub = if ($Arguments.Count -gt 0) { $Arguments[0] } else { 'plan' }
    if ($sub -notin 'plan', 'create', 'measure') {
        Write-DevDriveUsage
        $global:LASTEXITCODE = 2
        return
    }
    # named options can also ride in $Arguments (-SizeGB 50 ...) after the sub
    for ($i = 1; $i -lt $Arguments.Count; $i = $i + 2) {
        switch ($Arguments[$i]) {
            '-SizeGB' { $SizeGB = [int]$Arguments[$i + 1] }
            '-Letter' { $Letter = $Arguments[$i + 1] }
            '-FromDrive' { $FromDrive = $Arguments[$i + 1] }
            '-Seconds' { $Seconds = [int]$Arguments[$i + 1] }
            default { Write-DevDriveUsage; $global:LASTEXITCODE = 2; return }
        }
    }
    $letterChar = $Letter[0]
    $fromChar = $FromDrive[0]

    if ($sub -eq 'plan') {
        Write-Host 'dot devdrive plan'
        $found = $false
        foreach ($code in 65..90) {   # A..Z as codes: 5.1 has no char range operator
            $l = [char]$code
            $vol = Get-DevDriveVolume -Letter $l
            if (-not $vol) { continue }
            $mark = $vol.FileSystemType
            if ($vol.FileSystemType -eq 'ReFS') {
                $verdict = Test-DevDriveTrusted -Letter $l
                $mark = switch ($verdict) {
                    'yes'     { "Dev Drive (trusted)" }
                    'no'      { 'ReFS (not a Dev Drive)' }
                    'unknown' { 'ReFS (untrusted or unknown Dev Drive)' }
                    default   { 'ReFS - likely a Dev Drive (confirm from an admin shell)' }
                }
                if ($verdict -ne 'no') { $found = $true }
            }
            Write-Host ("  {0}: {1}" -f $l, $mark)
        }
        if ($found) {
            Write-Host 'Create nothing: a Dev Drive is already present (see docs/devdrive.md).'
        } else {
            Write-Host '  no Dev Drive found.'
            Write-Host ("create would: shrink {0}: by {1} GB (online, files untouched) -> new {2}: Dev Drive," -f $FromDrive, $SizeGB, $Letter)
            Write-Host '  then trust it. Run from an ADMIN shell: dot devdrive create'
        }
        Write-Host '  Measured trade-off: performance mode reschedules the scans, it does not remove them (docs/devdrive.md).'
        $global:LASTEXITCODE = 0
        return
    }

    if (-not (Test-DevDriveAdmin)) {
        Write-Host "dot devdrive ${sub}: needs an admin shell. Open one and rerun." -ForegroundColor Red
        $global:LASTEXITCODE = 1
        return
    }

    if ($sub -eq 'create') {
        if (Get-DevDriveVolume -Letter $letterChar) {
            Write-Host "dot devdrive: refusing letter ${Letter}: a volume is already there." -ForegroundColor Red
            $global:LASTEXITCODE = 1
            return
        }
        $src = Get-Partition -DriveLetter $fromChar
        $supported = Get-PartitionSupportedSize -DiskNumber $src.DiskNumber -PartitionNumber $src.PartitionNumber
        $target = [long]($src.Size - ($SizeGB * 1GB))
        if ($target -lt $supported.SizeMin) {
            $reclaimable = [int](($src.Size - $supported.SizeMin) / 1GB)
            Write-Host "dot devdrive: cannot shrink ${FromDrive}: by ${SizeGB} GB - only ${reclaimable} GB reclaimable (unmovable files?)." -ForegroundColor Red
            $global:LASTEXITCODE = 1
            return
        }
        Write-Host ("dot devdrive create: shrinking {0}: to {1} GB, creating {2}: ({3} GB Dev Drive)." -f $FromDrive, [int]($target / 1GB), $Letter, $SizeGB)
        Write-Host '  The shrink is online and touches no file; the format wipes only the NEW partition.'
        Invoke-DevDriveShrink -Letter $fromChar -TargetSize $target
        Invoke-DevDriveNewPartition -DiskNumber $src.DiskNumber -Letter $letterChar
        Invoke-DevDriveFormat -Letter $letterChar
        Invoke-DevDriveTrust -Letter $letterChar | Out-Null
        Write-Host ''
        if ((Test-DevDriveTrusted -Letter $letterChar) -eq 'yes') {
            Write-Host "  ${Letter}: is a trusted Dev Drive." -ForegroundColor Green
        } else {
            Write-Host "  ${Letter}: formatted, but trust did not confirm - run: fsutil devdrv trust ${Letter}:" -ForegroundColor Yellow
        }
        Write-Host "  Point Go at it (docs/devdrive.md): [data.devtmp] path = `"${Letter}:/dev/tmp`", go env -w GOCACHE=${Letter}:\gocache"
        $global:LASTEXITCODE = 0
        return
    }

    # measure
    # Lazy default: $env:USERPROFILE does not exist on the Linux CI runner, and
    # a param default evaluates on every call that omits it (the devtmp twin's
    # lesson). Resolve the real path only when measuring, on Windows.
    if (-not $DevTmpConfigPath) { $DevTmpConfigPath = Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml' }
    $devtmpPath = Get-DevTmpPath -ConfigPath $DevTmpConfigPath
    if (-not $devtmpPath) {
        Write-Host 'dot devdrive measure: no [data.devtmp] folder configured - `dot devtmp` first (docs/devtmp.md).' -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        return
    }
    if (-not $BenchPath) { $BenchPath = Join-Path ([IO.Path]::GetTempPath()) 'devdrive-bench\src' }
    if (-not $OutDir) { $OutDir = Join-Path ([IO.Path]::GetTempPath()) 'devdrive-measure' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    if (-not (Test-Path (Join-Path $BenchPath 'go.mod'))) { Write-DevDriveBench -Path $BenchPath }
    Write-Host "dot devdrive measure: bench at $BenchPath, ${Seconds}s window, report in $OutDir"
    Write-Host '  A workload window opens; press ENTER in THIS window when it says WORKLOAD DONE.'
    Invoke-DevDriveWorkload -BenchPath $BenchPath -Seconds $Seconds
    Start-Sleep -Seconds 2
    $etl = Join-Path $OutDir 'devdrive.etl'
    Invoke-DevDriveRecord -Path $etl
    Get-DevDriveReportText -EtlPath $etl | Set-Content -Path (Join-Path $OutDir 'devdrive-report.txt')
    Write-Host "  report: $(Join-Path $OutDir 'devdrive-report.txt')"
    $exclusions = @(Get-DevDriveExclusionPath)
    if ($exclusions.Count -gt 0) {
        Write-Host ''
        Write-Host 'Path exclusions present. If one covers the Dev Drive it is pointless now (async mode)'
        Write-Host 'and removing it is yours to run, your call:'
        foreach ($p in $exclusions) {
            $escaped = $p -replace "'", "''"
            $exclusionNote = "Remove-MpPreference -ExclusionPath '$escaped'"
            Write-Host "  $exclusionNote"
        }
    }
    $global:LASTEXITCODE = 0
}

# DEVDRIVE_NO_MAIN=1 keeps dispatch off: tests/devdrive.ps1 dot-sources this
# file and drives Invoke-DevDrive with the seams above overridden.
if (-not $env:DEVDRIVE_NO_MAIN) { Invoke-DevDrive -Arguments @($args) }
