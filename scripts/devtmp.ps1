#Requires -Version 5.1
<#
devtmp.ps1 - one known folder for build/test output, so Defender's cost for
freshly built executables is bounded (issue #227). Windows only. Reached as
`dot devtmp` from both PowerShell profiles; docs/devtmp.md.

  dot devtmp                    print the plan; change nothing
  dot devtmp apply              create the folder and `go env -w GOTMPDIR=...`
  dot devtmp run <cmd> [args]   run <cmd> with TMP/TEMP pointed at the folder
                                for THAT process only (nothing system-wide)

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
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) { return '' }
    $value = & go env GOTMPDIR 2>$null
    if ($value) { return ([string]$value).Trim() }
    return ''
}

# Persistent, per-user, no admin: writes Go's own env file (go env -w).
function Set-GoTmpDir {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        Write-Host '  go not found - skipped GOTMPDIR (re-run after installing Go).' -ForegroundColor Yellow
        return
    }
    if ($PSCmdlet.ShouldProcess("GOTMPDIR=$Path", 'go env -w')) {
        & go env -w "GOTMPDIR=$Path"
    }
}

function New-DevTmpDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if ($PSCmdlet.ShouldProcess($Path, 'create directory')) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
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
        [string]$TempDir = $env:TEMP
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
    $verdict = Test-DevTmpPathSafe -Path $configured -HomeDir $HomeDir -TempDir $TempDir -AccountDir @(Get-AccountDir -ConfigPath $ConfigPath)
    if (-not $verdict.Safe) {
        Write-Host "dot devtmp: refusing '$configured': $($verdict.Reason)" -ForegroundColor Red
        Write-Host '  Pick a dedicated folder that holds build/test output only (docs/devtmp.md).'
        $global:LASTEXITCODE = 1
        return
    }
    $path = $verdict.Path

    if ($sub -eq 'run') {
        New-DevTmpDirectory -Path $path
        $command = $Arguments[1]
        $commandArgs = @($Arguments | Select-Object -Skip 2)
        $saved = @{ TMP = $env:TMP; TEMP = $env:TEMP }
        try {
            $env:TMP = $path
            $env:TEMP = $path
            $global:LASTEXITCODE = 0
            & $command @commandArgs
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
        New-DevTmpDirectory -Path $path
        Set-GoTmpDir -Path $path
        Write-Host "  Folder ready: $path" -ForegroundColor Green
        Write-Host "  GOTMPDIR set to $path (was: $(if ($current) { $current } else { '(unset)' }))" -ForegroundColor Green
    } else {
        Write-Host "dot devtmp plan  (nothing is changed; 'dot devtmp apply' does the no-admin part)"
        Write-Host "  folder     $path  $(if (Test-Path -LiteralPath $path) { '(exists)' } else { '(will be created)' })"
        Write-Host "  GOTMPDIR   $(if ($current) { $current } else { '(unset)' })  ->  $path"
        Write-Host '  TMP/TEMP   set per command only: dot devtmp run <cmd> [args]'
    }
    Write-Host ''
    Write-Host 'Defender exclusion - run this yourself from an ADMIN shell (this script never does):'
    Write-Host "  $exclusionCommand"
    Write-Host 'Everything under that folder is then unscanned: build and test output only.'
    $global:LASTEXITCODE = 0
}

# DEVTMP_NO_MAIN=1 keeps dispatch off: tests/devtmp.ps1 dot-sources this file
# and drives Invoke-DevTmp with the seams above overridden.
if (-not $env:DEVTMP_NO_MAIN) { Invoke-DevTmp -Arguments @($args) }
