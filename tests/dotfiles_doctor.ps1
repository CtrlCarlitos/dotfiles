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

function New-ValidConfig([string]$homeDir) {
    $dir = Join-Path $homeDir '.config/chezmoi'
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

Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
Write-Host 'PASS: dotfiles-doctor.ps1 (6 scenarios)'
exit 0
