#Requires -Version 5.1
<#
Behavioral tests for scripts/dotfiles-doctor.ps1 - the Windows twin of
tests/dotfiles_doctor.sh. Same five scenarios, run against a real pwsh with
HOME/USERPROFILE pointed at fixture dirs. Skips when chezmoi is absent.
#>
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Doctor = Join-Path $RepoRoot 'scripts/dotfiles-doctor.ps1'

if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
    Write-Host 'SKIP: chezmoi not installed'
    exit 0
}

$script:Failed = @()
function Fail([string]$m) { $script:Failed += $m; Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function New-ValidConfig {
    # SupportsShouldProcess (PSUseShouldProcessForStateChangingFunctions); in
    # this harness ShouldProcess always confirms, so behavior is unchanged.
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$homeDir)
    $dir = Join-Path $homeDir '.config/chezmoi'
    if (-not $PSCmdlet.ShouldProcess($dir, 'create valid test config')) { return }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    @'
primaryName = "Probe User"
primaryEmail = "probe@example.com"
primaryUsername = "probe"
primaryKey = "id_probe"

[data.packages]
core = true
modern_cli = false
fonts = false
agent_toolkit = false
opencode_cli = false
opencode_desktop = false
claude_cli = false
claude_desktop = false
chatgpt_cli = false
chatgpt_desktop = false
antigravity_cli = false
antigravity_desktop = false
dev_desktop = false
remote_access = false
remote_access_server = false
guardrail = true
mobile_dev = false
'@ | Set-Content -Path (Join-Path $dir 'chezmoi.toml') -Encoding utf8
}

function Invoke-Doctor([string]$homeDir, [switch]$Fix) {
    $env:HOME = $homeDir
    $env:USERPROFILE = $homeDir
    $env:CHEZMOI_CONFIG_DIR = $null
    $invokeArgs = @('-NoProfile', '-File', $Doctor)
    if ($Fix) { $invokeArgs += '-Fix' }
    $out = & pwsh @invokeArgs 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("df-doc-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$cp1252 = [System.Text.Encoding]::GetEncoding(1252)

# [1] Valid config passes.
$h = Join-Path $Tmp 'valid'; New-Item -ItemType Directory -Force -Path $h | Out-Null
New-ValidConfig $h
$r = Invoke-Doctor $h
if ($r.Code -ne 0) { Fail "[1] valid config should pass: $($r.Out)" }
if ($r.Out -notmatch 'config-utf8') { Fail "[1] utf-8 check not reported: $($r.Out)" }
# The repo version rides along with every doctor run (same line as `dot version`),
# informational only: never a warn/error, so it cannot fail a valid config.
if ($r.Out -notmatch '(?m)^(ok|skip)\s+dotfiles-version\s') { Fail "[1] dotfiles-version not reported: $($r.Out)" }
Write-Host '  ok: valid config passes'

# [2] cp1252: detected, -Fix converts, re-run passes.
$h = Join-Path $Tmp 'cp1252'; New-Item -ItemType Directory -Force -Path $h | Out-Null
New-ValidConfig $h
$cfg = Join-Path $h '.config/chezmoi/chezmoi.toml'
[IO.File]::WriteAllText($cfg, ([IO.File]::ReadAllText($cfg) + "  # saved by an ANSI editor $($cp1252.GetString([byte[]]@(0x97))) oops`n"), $cp1252)
$r = Invoke-Doctor $h
if ($r.Code -eq 0) { Fail '[2] cp1252 config must fail' }
$r = Invoke-Doctor $h -Fix
if ($r.Code -ne 0) { Fail "[2] -Fix must succeed on pure cp1252: $($r.Out)" }
$r = Invoke-Doctor $h
if ($r.Code -ne 0) { Fail '[2] config should pass after -Fix' }
Write-Host '  ok: cp1252 detected and fixed'

# [3] Mixed encodings: -Fix refuses.
$h = Join-Path $Tmp 'mixed'; New-Item -ItemType Directory -Force -Path $h | Out-Null
New-ValidConfig $h
$cfg = Join-Path $h '.config/chezmoi/chezmoi.toml'
$text = [IO.File]::ReadAllText($cfg) + "  # valid utf-8 em dash $($cp1252.GetString([byte[]]@(0xE2,0x80,0x94))) here`n"
[IO.File]::WriteAllText($cfg, $text, $utf8NoBom)
$text = [IO.File]::ReadAllText($cfg) + "  # stray cp1252 byte $($cp1252.GetString([byte[]]@(0x97))) here`n"
[IO.File]::WriteAllText($cfg, $text, $cp1252)  # whole-file cp1252 rewrite of a mixed-content string
$r = Invoke-Doctor $h
if ($r.Code -eq 0) { Fail '[3] mixed encoding must fail' }
$r = Invoke-Doctor $h -Fix
if ($r.Code -eq 0) { Fail '[3] -Fix must refuse mixed encodings' }
if ($r.Out -notmatch 'MIXED') { Fail "[3] mixed not reported: $($r.Out)" }
$r = Invoke-Doctor $h
if ($r.Code -eq 0) { Fail '[3] mixed file must still fail after refused fix' }
Write-Host '  ok: mixed encodings refused'

# [4] Missing prompted key: named in output, exit 1.
$h = Join-Path $Tmp 'missing'; New-Item -ItemType Directory -Force -Path $h | Out-Null
New-ValidConfig $h
$cfg = Join-Path $h '.config/chezmoi/chezmoi.toml'
(Get-Content $cfg) | Where-Object { $_ -notmatch '^guardrail = ' } | Set-Content $cfg -Encoding utf8
$r = Invoke-Doctor $h
if ($r.Code -eq 0) { Fail '[4] missing key must fail' }
if ($r.Out -notmatch 'guardrail') { Fail "[4] missing key not named: $($r.Out)" }
Write-Host '  ok: missing prompted key reported'

# [5] Unparseable TOML.
$h = Join-Path $Tmp 'broken'; New-Item -ItemType Directory -Force -Path $h | Out-Null
New-ValidConfig $h
Add-Content (Join-Path $h '.config/chezmoi/chezmoi.toml') 'this is not toml [[[' -Encoding utf8
$r = Invoke-Doctor $h
if ($r.Code -eq 0) { Fail '[5] unparseable config must fail' }
Write-Host '  ok: unparseable config reported'

# [6] In-apply mode: sub-chezmoi checks skipped (state-lock deadlock twin).
$h = Join-Path $Tmp 'inapply'; New-Item -ItemType Directory -Force -Path $h | Out-Null
New-ValidConfig $h
$env:HOME = $h; $env:USERPROFILE = $h; $env:CHEZMOI_CONFIG_DIR = $null; $env:DOTFILES_DOCTOR_IN_APPLY = '1'
$out6 = & pwsh -NoProfile -File $Doctor 2>&1 | Out-String
$rc6 = $LASTEXITCODE
$env:DOTFILES_DOCTOR_IN_APPLY = $null
if ($rc6 -ne 0) { Fail "[6] in-apply run should pass: $out6" }
if ($out6 -notmatch 'in-apply mode') { Fail "[6] in-apply skips not reported: $out6" }
if ($out6 -match 'chezmoi loads the config') { Fail '[6] in-apply must not invoke chezmoi data (state lock)' }
Write-Host '  ok: in-apply mode skips chezmoi-invoking checks'

# [7] python3 (Windows only): the Microsoft Store stub shadows the shim. Fake
# interpreters (.cmd) in fixture dirs on a controlled PATH; LOCALAPPDATA points
# at a fixture so "WindowsApps" is a directory we own. Never touches real Python.
if ($env:OS -eq 'Windows_NT') {
    $h = Join-Path $Tmp 'py3'
    $wapps = Join-Path $h 'AppData\Local\Microsoft\WindowsApps'
    $shimDir = Join-Path $h 'shimbin'
    $otherDir = Join-Path $h 'otherbin'
    New-Item -ItemType Directory -Force -Path $wapps, $shimDir, $otherDir | Out-Null
    New-ValidConfig $h

    function Write-FakePython([string]$dir, [string[]]$lines) {
        [IO.File]::WriteAllText((Join-Path $dir 'python3.cmd'), (($lines -join "`r`n") + "`r`n"), $utf8NoBom)
    }
    $stub = @('@echo off', 'echo Python was not found; run without arguments to install from the Microsoft Store.', 'exit /b 9009')
    $real = @('@echo off', 'echo Python 3.14.8')
    $junk = @('@echo off', 'echo something else entirely', 'exit /b 1')

    $origPath = $env:PATH
    # The machine's own python3 (a managed shim, or a Store stub) must not leak in.
    $cleanDirs = $origPath -split ';' | Where-Object {
        $_ -and -not (Test-Path (Join-Path $_ 'python3.cmd')) -and -not (Test-Path (Join-Path $_ 'python3.exe')) -and -not (Test-Path (Join-Path $_ 'python3'))
    }
    function Invoke-Py3Doctor([string[]]$front, [switch]$Fix, [switch]$InApply) {
        $env:HOME = $h; $env:USERPROFILE = $h; $env:CHEZMOI_CONFIG_DIR = $null
        $env:LOCALAPPDATA = Join-Path $h 'AppData\Local'
        $env:PATH = (@($front) + $cleanDirs) -join ';'
        if ($InApply) { $env:DOTFILES_DOCTOR_IN_APPLY = '1' }
        $invokeArgs = @('-NoProfile', '-File', $Doctor)
        if ($Fix) { $invokeArgs += '-Fix' }
        try { $out = & pwsh @invokeArgs 2>&1 | Out-String; $code = $LASTEXITCODE }
        finally { $env:PATH = $origPath; $env:DOTFILES_DOCTOR_IN_APPLY = $null }
        return @{ Out = $out; Code = $code }
    }

    # a. The stub shadows the shim: warn, name the cure, change nothing, exit 0.
    Write-FakePython $wapps $stub; Write-FakePython $shimDir $real
    $r = Invoke-Py3Doctor @($wapps, $shimDir)
    if ($r.Code -ne 0) { Fail "[7a] a shadowing stub is a warning, not an error: $($r.Out)" }
    if ($r.Out -notmatch 'warn\s+python3\s') { Fail "[7a] stub must warn: $($r.Out)" }
    if ($r.Out -notmatch 'Microsoft Store') { Fail "[7a] warning must name the Microsoft Store stub: $($r.Out)" }
    if ($r.Out -notmatch 'App execution aliases') { Fail "[7a] warning must say where to turn it off: $($r.Out)" }
    if (-not (Test-Path (Join-Path $wapps 'python3.cmd'))) { Fail '[7a] without -Fix the stub must be left alone' }
    Write-Host '  ok: python3 Store stub detected, nothing removed without -Fix'

    # b. -Fix removes ONLY the stub; python3 then resolves to the shim and passes.
    $r = Invoke-Py3Doctor @($wapps, $shimDir) -Fix
    if ($r.Code -ne 0) { Fail "[7b] -Fix run should pass: $($r.Out)" }
    if (Test-Path (Join-Path $wapps 'python3.cmd')) { Fail '[7b] -Fix must remove the stub' }
    if (-not (Test-Path (Join-Path $shimDir 'python3.cmd'))) { Fail '[7b] -Fix must leave the shim alone' }
    if ($r.Out -notmatch 'ok\s+python3\s') { Fail "[7b] python3 must pass after -Fix: $($r.Out)" }
    $r = Invoke-Py3Doctor @($wapps, $shimDir)
    if ($r.Out -notmatch 'ok\s+python3\s') { Fail "[7b] a second run must pass: $($r.Out)" }
    Write-Host '  ok: -Fix removes the stub and python3 resolves to the shim'

    # c. A genuine Store-installed Python also lives in WindowsApps: it runs, so it stays.
    Write-FakePython $wapps $real
    $r = Invoke-Py3Doctor @($wapps) -Fix
    if ($r.Out -notmatch 'ok\s+python3\s') { Fail "[7c] a working WindowsApps python3 is fine: $($r.Out)" }
    if (-not (Test-Path (Join-Path $wapps 'python3.cmd'))) { Fail '[7c] -Fix must never remove a python3 that works' }
    Write-Host '  ok: a working Store-installed python3 is left alone'

    # d. Something that is not Python, outside WindowsApps: warn, never delete.
    Remove-Item (Join-Path $wapps 'python3.cmd') -Force
    Write-FakePython $otherDir $junk
    $r = Invoke-Py3Doctor @($otherDir) -Fix
    if ($r.Out -notmatch 'warn\s+python3\s') { Fail "[7d] a python3 that is not Python must warn: $($r.Out)" }
    if (-not (Test-Path (Join-Path $otherDir 'python3.cmd'))) { Fail '[7d] -Fix must only ever remove the WindowsApps stub' }
    Remove-Item (Join-Path $otherDir 'python3.cmd') -Force
    Write-Host '  ok: a broken python3 outside WindowsApps warns and is never removed'

    # e. No python3 at all: warn, and point at the shim (chezmoi apply).
    $r = Invoke-Py3Doctor @()
    if ($r.Out -notmatch 'warn\s+python3\s') { Fail "[7e] a missing python3 must warn: $($r.Out)" }
    if ($r.Out -notmatch 'chezmoi apply') { Fail "[7e] a missing python3 must point at the shim (chezmoi apply): $($r.Out)" }
    Write-Host '  ok: a missing python3 warns and points at the shim'

    # f. In-apply: the apply deploys the shim itself, and must never touch the stub.
    Write-FakePython $wapps $stub
    $r = Invoke-Py3Doctor @($wapps) -InApply
    if ($r.Code -ne 0) { Fail "[7f] in-apply must pass: $($r.Out)" }
    if ($r.Out -notmatch 'skip\s+python3\s') { Fail "[7f] in-apply must report the python3 check as skipped: $($r.Out)" }
    if ($r.Out -match '(warn|ok)\s+python3\s') { Fail "[7f] in-apply must not probe python3: $($r.Out)" }
    if (-not (Test-Path (Join-Path $wapps 'python3.cmd'))) { Fail '[7f] in-apply must not touch the stub' }
    Write-Host '  ok: in-apply mode skips the python3 check'
} else {
    Write-Host '  skip: python3 check is Windows-only'
}

Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
Write-Host 'PASS: dotfiles-doctor.ps1 (7 scenarios)'
exit 0
