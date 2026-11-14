#Requires -Version 5.1
<#
devtmp.ps1 - one known folder for build/test output, so Defender's cost for
freshly built executables is bounded (issue #227). Windows only. Reached as
`dot devtmp` from both PowerShell profiles; docs/devtmp.md.

  dot devtmp                    print the plan; change nothing
  dot devtmp apply              create the folder and `go env -w GOTMPDIR=...`
  dot devtmp run <cmd> [args]   run <cmd> with TMP/TEMP pointed at the folder
                                for THAT process only (nothing system-wide)

plan/apply also report whether the folder's volume is a Dev Drive, where
Defender scans asynchronously and the exclusion is unnecessary. Detection is
READ-ONLY (fsutil devdrv query, Get-Volume); a Dev Drive is never created,
trusted, mounted or enabled from here.

The folder comes from [data.devtmp] path in ~/.config/chezmoi/chezmoi.toml.
It holds build and test output ONLY: once excluded, nothing in it is scanned.

This script NEVER changes Defender. It prints the one command that does, for
the user to run from an admin shell (the exclusion cmdlet, see docs/devtmp.md).
That keeps the repo invariant "the dotfiles never touch Defender"
(tests/devtmp_contract.sh, tests/devtmp.ps1) and the rule that Defender
settings are changed by the user, not an agent. The configured path is refused
if it is a drive root, %TEMP%, the user profile, an account directory, or an
ancestor of any of them (Test-DevTmpPathSafe in scripts/lib/ps-common.ps1).

It runs inside the user's own shell via `dot`, so it never calls `exit`: it
reports through $global:LASTEXITCODE (0 ok, 1 not configured or unsafe path,
2 usage; `run` leaves the child's code).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\ps-common.ps1')

# --- Seams: every side effect lives in one of these so tests/devtmp.ps1 can
# replace it after dot-sourcing (DEVTMP_NO_MAIN=1).

# Current `go env GOTMPDIR`; empty when unset or when Go is not installed.
function Get-GoTmpDir {
    # Scope-local: on Windows PowerShell 5.1 any native stderr line (e.g. a Go
    # toolchain download notice) would otherwise throw under 'Stop'.
    $ErrorActionPreference = 'Continue'
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) { return '' }
    $value = & go env GOTMPDIR 2>$null
    if ($value) { return ([string]$value).Trim() }
    return ''
}

# Persistent, per-user, no admin: writes Go's own env file (go env -w).
# Returns $true only when GOTMPDIR was really written, so the caller never
# reports a setting that was skipped.
function Set-GoTmpDir {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $ErrorActionPreference = 'Continue'
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        Write-Host '  go not found - skipped GOTMPDIR (re-run after installing Go).' -ForegroundColor Yellow
        return $false
    }
    if ($PSCmdlet.ShouldProcess("GOTMPDIR=$Path", 'go env -w')) {
        & go env -w "GOTMPDIR=$Path"
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

# 8.3 short name -> long name (C:\Users\CARLIT~1 -> C:\Users\carlitos), so the
# profile/TEMP rules compare like with like. Only for paths that exist on
# Windows; anything else comes back unchanged, which keeps the string rules in
# ps-common.ps1 identical on every runner.
function Resolve-DevTmpLongPath {
    param([string]$Path)
    if (-not $Path -or $env:OS -ne 'Windows_NT' -or -not (Test-Path -LiteralPath $Path)) { return $Path }
    if (-not ('DevTmp.NativeMethods' -as [type])) {
        Add-Type -Namespace DevTmp -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint GetLongPathName(string shortPath, System.Text.StringBuilder longPath, uint bufferSize);
'@
    }
    $buffer = New-Object System.Text.StringBuilder 32768
    $length = [DevTmp.NativeMethods]::GetLongPathName($Path, $buffer, [uint32]$buffer.Capacity)
    if ($length -gt 0 -and $length -lt $buffer.Capacity) { return $buffer.ToString() }
    return $Path
}

function New-DevTmpDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if ($PSCmdlet.ShouldProcess($Path, 'create directory')) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

# A folder that cannot be created (missing drive, ACL) is a one-line refusal,
# not a raw terminating error; the caller stops when this returns $false.
function Initialize-DevTmpDirectory {
    param([Parameter(Mandatory)][string]$Path)
    try {
        New-DevTmpDirectory -Path $Path
        return $true
    } catch {
        Write-Host "dot devtmp: could not create '$Path': $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        return $false
    }
}

# Whether the configured folder's volume is a Dev Drive (issue #227, option 2).
# READ-ONLY: fsutil devdrv query is the only Dev Drive command this repo ever
# runs - creating, trusting or enabling one is the user's alone (the forbids in
# tests/devtmp_contract.sh hold that line). fsutil needs an admin shell, so a
# denied query falls back to the volume's file system: ReFS is the tell-tale of
# a Dev Drive on a dev box, reported as 'likely', never as fact.
#   'devdrive'  fsutil says a trusted Dev Drive (asynchronous Defender scans)
#   'likely'    fsutil denied or absent, and the volume is ReFS
#   'no'        fsutil says not a Dev Drive, or the volume is not ReFS
#   'unknown'   fsutil said something else (an untrusted Dev Drive, garbage),
#               or the volume could not be probed at all
# The drive root of a normalised Windows path, by STRING ONLY: the .ps1 twin
# runs on the Linux CI runner too, where [IO.Path]::GetPathRoot('E:\x') answers
# '' (no root on a Unix filesystem) and every root-derived probe would then
# silently degrade to 'unknown'. Empty when $Path carries no drive letter.
function Get-DevTmpDriveRoot {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.Length -ge 2 -and $Path[1] -eq ':' -and [char]::IsLetter($Path[0])) {
        return ($Path.Substring(0, 1) + ':\')
    }
    return ''
}

function Get-DevTmpDevDrive {
    param([Parameter(Mandatory)][string]$Path)
    $root = Get-DevTmpDriveRoot -Path $Path
    if (-not $root) { return 'unknown' }
    if (Get-Command fsutil -ErrorAction SilentlyContinue) {
        # A native command's stderr (the access-denied line when not elevated)
        # is not a PowerShell error; judge by exit code and output.
        $ErrorActionPreference = 'Continue'
        $out = & fsutil devdrv query $root 2>$null
        $text = (@($out) -join ' ').ToLowerInvariant()
        if ($LASTEXITCODE -eq 0 -and $text -notmatch 'access is denied|error 5') {
            # fsutil's own words are "developer volume" (captured on a real
            # trusted Dev Drive, 24H2); "dev drive" spellings are kept as a
            # compatibility net for other builds/locales of the same tool.
            if ($text -match 'trusted developer volume|trusted dev drive') { return 'devdrive' }
            if ($text -match 'not a developer volume|not a dev drive') { return 'no' }
            if ($text -match 'developer volume|dev drive') { return 'unknown' }
            return 'unknown'
        }
    }
    try {
        $letter = $root.Substring(0, 1)
        $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
        if ($volume -and $volume.FileSystemType -eq 'ReFS') { return 'likely' }
        return 'no'
    } catch {
        return 'unknown'
    }
}

function Write-DevTmpUsage {
    Write-Host 'usage: dot devtmp [plan | apply | run <command> [args...]]'
    Write-Host '  plan   (default)  print what would change; change nothing'
    Write-Host '  apply             create the folder and set GOTMPDIR (no admin needed)'
    Write-Host '  run <cmd> [args]  run <cmd> with TMP/TEMP set to the folder, for that process only'
}

function Invoke-DevTmp {
    param(
        [string[]]$Arguments = @(),
        [string]$ConfigPath = (Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml'),
        [string]$HomeDir = $env:USERPROFILE,
        [string[]]$TempDir = @($env:TEMP, $env:TMP)
    )
    $sub = if ($Arguments.Count -gt 0) { $Arguments[0] } else { 'plan' }
    if ($sub -notin 'plan', 'apply', 'run') {
        Write-DevTmpUsage
        $global:LASTEXITCODE = 2
        return
    }
    if ($sub -eq 'run' -and $Arguments.Count -lt 2) {
        Write-DevTmpUsage
        $global:LASTEXITCODE = 2
        return
    }

    $configured = Get-DevTmpPath -ConfigPath $ConfigPath
    if (-not $configured) {
        Write-Host 'dot devtmp: no folder configured. Set it in ~/.config/chezmoi/chezmoi.toml:' -ForegroundColor Yellow
        Write-Host '  [data.devtmp]'
        Write-Host '    path = "C:/dev/tmp"'
        Write-Host '  then run `chezmoi init` and `dot devtmp` again. See docs/devtmp.md.'
        $global:LASTEXITCODE = 1
        return
    }
    # Compare long names with long names: %TEMP% and the profile are often 8.3
    # short paths (C:\Users\CARLIT~1) for long user names.
    $verdict = Test-DevTmpPathSafe -Path (Resolve-DevTmpLongPath $configured) `
        -HomeDir (Resolve-DevTmpLongPath $HomeDir) `
        -TempDir @($TempDir | ForEach-Object { Resolve-DevTmpLongPath $_ }) `
        -AccountDir @(Get-AccountDir -ConfigPath $ConfigPath)
    if (-not $verdict.Safe) {
        Write-Host "dot devtmp: refusing '$configured': $($verdict.Reason)" -ForegroundColor Red
        Write-Host '  Pick a dedicated folder that holds build/test output only (docs/devtmp.md).'
        $global:LASTEXITCODE = 1
        return
    }
    $path = $verdict.Path
    # `run` never prints the exclusion, so it never needs the verdict either.
    $devdrive = if ($sub -eq 'run') { '' } else { Get-DevTmpDevDrive -Path $path }
    $devdriveRoot = Get-DevTmpDriveRoot -Path $path

    if ($sub -eq 'run') {
        $command = $Arguments[1]
        $commandArgs = @($Arguments | Select-Object -Skip 2)
        # Array-splatting passes every argument positionally, so a PowerShell
        # script/cmdlet/function would silently mis-bind its -Named parameters.
        # Only a native executable is run; resolve it before changing anything.
        $resolved = Get-Command $command -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $resolved) {
            Write-Host "dot devtmp: could not find '$command'." -ForegroundColor Red
            $global:LASTEXITCODE = 1
            return
        }
        if ($resolved.CommandType -ne 'Application') {
            Write-Host "dot devtmp: run takes a native executable (go, pwsh, cmd, ...), not '$command' ($($resolved.CommandType))." -ForegroundColor Red
            Write-Host '  For a PowerShell script: dot devtmp run pwsh -NoProfile -File <script> [args]'
            $global:LASTEXITCODE = 2
            return
        }
        if (-not (Initialize-DevTmpDirectory -Path $path)) { return }
        $saved = @{ TMP = $env:TMP; TEMP = $env:TEMP }
        try {
            $env:TMP = $path
            $env:TEMP = $path
            $global:LASTEXITCODE = 0
            # A child's stderr (go build/test errors) is output, not a PowerShell
            # error: under 'Stop' Windows PowerShell 5.1 would throw on its first line.
            $ErrorActionPreference = 'Continue'
            & $resolved @commandArgs
        } catch {
            Write-Host "dot devtmp: could not run '$command': $($_.Exception.Message)" -ForegroundColor Red
            $global:LASTEXITCODE = 1
        } finally {
            foreach ($name in 'TMP', 'TEMP') {
                if ($null -eq $saved[$name]) { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
                else { Set-Item "Env:\$name" $saved[$name] }
            }
        }
        return
    }

    $escaped = $path -replace "'", "''"
    $exclusionCommand = "Add-MpPreference -ExclusionPath '$escaped'"
    $current = Get-GoTmpDir

    if ($sub -eq 'apply') {
        if (-not (Initialize-DevTmpDirectory -Path $path)) { return }
        $goSet = Set-GoTmpDir -Path $path
        Write-Host "  Folder ready: $path" -ForegroundColor Green
        if ($goSet) {
            Write-Host "  GOTMPDIR set to $path (was: $(if ($current) { $current } else { '(unset)' }))" -ForegroundColor Green
        } else {
            Write-Host "  GOTMPDIR was NOT set (is Go installed? it stays $(if ($current) { $current } else { '(unset)' }))." -ForegroundColor Yellow
        }
    } else {
        Write-Host "dot devtmp plan  (nothing is changed; 'dot devtmp apply' does the no-admin part)"
        Write-Host "  folder     $path  $(if (Test-Path -LiteralPath $path) { '(exists)' } else { '(will be created)' })"
        Write-Host "  GOTMPDIR   $(if ($current) { $current } else { '(unset)' })  ->  $path"
        Write-Host '  TMP/TEMP   set per command only: dot devtmp run <cmd> [args]'
        if ($devdrive -eq 'devdrive') {
            Write-Host "  Dev Drive  yes - $devdriveRoot is a trusted Dev Drive; Defender already scans it"
            Write-Host '              asynchronously (performance mode), so no exclusion is needed'
        } elseif ($devdrive -eq 'likely') {
            Write-Host "  Dev Drive  maybe - the volume is ReFS; confirm from an admin shell:"
            Write-Host "                fsutil devdrv query $devdriveRoot"
        } elseif ($devdrive -eq 'unknown') {
            Write-Host "  Dev Drive  unknown (fsutil devdrv query $devdriveRoot from an admin shell says for sure)"
        } else {
            Write-Host '  Dev Drive  no'
        }
    }
    Write-Host ''
    if ($devdrive -eq 'devdrive') {
        Write-Host "Defender exclusion: NOT needed - $devdriveRoot is a trusted Dev Drive, Defender already"
        Write-Host 'scans it in asynchronous performance mode; excluding it would only reduce protection.'
    } else {
        Write-Host 'Defender exclusion - run this yourself from an ADMIN shell (this script never does):'
        Write-Host "  $exclusionCommand"
        Write-Host 'Everything under that folder is then unscanned: build and test output only.'
        if ($devdrive -eq 'likely') {
            Write-Host ''
            Write-Host "Note: the volume $devdriveRoot is ReFS - likely a Dev Drive, where the exclusion is"
            Write-Host "unnecessary. Confirm from an admin shell: fsutil devdrv query $devdriveRoot"
        }
    }
    $global:LASTEXITCODE = 0
}

# DEVTMP_NO_MAIN=1 keeps dispatch off: tests/devtmp.ps1 dot-sources this file
# and drives Invoke-DevTmp with the seams above overridden.
if (-not $env:DEVTMP_NO_MAIN) { Invoke-DevTmp -Arguments @($args) }
