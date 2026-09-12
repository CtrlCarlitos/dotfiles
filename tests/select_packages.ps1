#Requires -Version 5.1
# Tests for scripts/select-packages.ps1 — the gum package-group menu (Windows
# twin). Mirrors tests/select_packages.sh: fake gum on PATH serves canned
# `choose` results and tees argv to $env:FAKE_GUM_LOG; a child pwsh runs the
# script under test with HOME/USERPROFILE pointed at temp dirs.
#
# The script under test gates on [Environment]::UserInteractive + -not $env:CI
# (the Windows-twin TTY check), so interactive scenarios must run from an
# interactive session; the CI gate is exercised by setting $env:CI in a child.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ScriptUnderTest = Join-Path $RepoRoot 'scripts/select-packages.ps1'

$script:PassCount = 0
$script:Failed = @()
function Ok([string]$name) {
    $script:PassCount++
    Write-Host "  ok: $name" -ForegroundColor Green
}
function Fail([string]$name, [string]$detail) {
    $script:Failed += $name
    Write-Host "FAIL: $name" -ForegroundColor Red
    if ($detail) { Write-Host $detail -ForegroundColor DarkGray }
}

# The 12 groups in taxonomy order — plan Global Constraints.
$TestGroups = @('core', 'modern_cli', 'fonts', 'agent_toolkit', 'claude_cli',
    'claude_desktop', 'chatgpt_cli', 'chatgpt_desktop', 'antigravity_cli',
    'antigravity_desktop', 'dev_desktop', 'guardrail')

$nl = [Environment]::NewLine

function ExpectedSection([string[]]$trueKeys) {
    $lines = @('[data.packages]')
    foreach ($g in $TestGroups) {
        $val = if ($trueKeys -contains $g) { 'true' } else { 'false' }
        $lines += "  $g = $val"
    }
    return ($lines -join $nl) + $nl
}

# --- temp workspace ----------------------------------------------------------

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("sel-pkgs-ps1-" + [IO.Path]::GetRandomFileName())
$Bin = Join-Path $Tmp 'bin'
New-Item -ItemType Directory -Force -Path $Bin | Out-Null
$GumLog = Join-Path $Tmp 'gum.log'

# Fake gum. On Windows pwsh a .cmd shim is needed (a shebang script is not
# executable there); on Linux/macOS pwsh a bash script works. Behavior:
#   choose --no-limit ... -> $env:FAKE_MULTI words, one per line ("__FAIL__" = exit 130, Windows shim only logs)
#   choose (preset)       -> $env:FAKE_PRESET (default custom)
if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    @'
@echo off
echo %* >> "%FAKE_GUM_LOG%"
echo %* | find /i "--no-limit" >nul
if errorlevel 1 (
  echo %FAKE_PRESET%
) else (
  for %%W in (%FAKE_MULTI%) do echo %%W
)
'@ | Set-Content -Path (Join-Path $Bin 'gum.cmd') -Encoding Ascii
} else {
    @'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GUM_LOG:?}"
if [[ "$*" == *--no-limit* ]]; then
    [[ "$FAKE_MULTI" == "__FAIL__" ]] && exit 130
    tr ' ' '\n' <<<"${FAKE_MULTI:?}" | sed '/^$/d'
else
    printf '%s\n' "${FAKE_PRESET:-custom}"
fi
'@ | Set-Content -Path (Join-Path $Bin 'gum')
    chmod +x (Join-Path $Bin 'gum')
}

# Run the script under test in a child pwsh with a swapped environment.
# $FakeMulti = canned multi result (words), $FakePreset = canned preset answer.
function Invoke-Menu([string]$homeDir, [string]$fakeMulti, [string]$fakePreset = 'custom', [switch]$CI) {
    [IO.File]::WriteAllText($GumLog, '')
    $savedHome, $savedProfile, $savedPath, $savedCI = $env:HOME, $env:USERPROFILE, $env:PATH, $env:CI
    try {
        $env:HOME = $homeDir
        $env:USERPROFILE = $homeDir
        $sep = [IO.Path]::PathSeparator
        $env:PATH = "$Bin$sep$env:PATH"
        $env:FAKE_GUM_LOG = $GumLog
        $env:FAKE_MULTI = $fakeMulti
        $env:FAKE_PRESET = $fakePreset
        if ($CI) { $env:CI = 'true' } else { Remove-Item Env:CI -ErrorAction SilentlyContinue }
        $out = & pwsh -NoProfile -File $ScriptUnderTest 2>&1 | Out-String
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $out }
    } finally {
        $env:HOME, $env:USERPROFILE, $env:PATH, $env:CI = $savedHome, $savedProfile, $savedPath, $savedCI
        Remove-Item Env:FAKE_GUM_LOG, Env:FAKE_MULTI, Env:FAKE_PRESET -ErrorAction SilentlyContinue
    }
}

function Assert-FileEquals([string]$file, [string]$expected, [string]$label) {
    if (-not (Test-Path -LiteralPath $file)) { Fail $label 'file missing'; return }
    $actual = [IO.File]::ReadAllText($file)
    if ($actual -ceq $expected) {
        Ok $label
    } else {
        Fail $label ("expected:$nl$expected${nl}---actual---$nl$actual")
    }
}

$SeedNoPackages = @"
# seeded by the test
[data]
  # keep this comment byte-identical

[[data.accounts]]
  name = "Work Account"
  email = "work@example.com"
  username = "work"
  provider = "github"
  key = "id_work"
  dirs = ["projects/work"]

[add]
  secrets = "warning"
"@ + $nl

try {
    # --- (a) fresh machine, no config: file created with exactly the 12 keys
    Write-Host '[1] fresh run creates the config with the 12 keys'
    $H1 = Join-Path $Tmp 'home1'
    New-Item -ItemType Directory -Force -Path $H1 | Out-Null
    $r = Invoke-Menu $H1 'core fonts guardrail'
    if ($r.Exit -ne 0) { Fail 'fresh run exits 0' "exit=$($r.Exit) out=$($r.Output)" } else { Ok 'fresh run exits 0' }
    $cfg = Join-Path $H1 '.config/chezmoi/chezmoi.toml'
    if (-not (Test-Path $cfg)) { Fail 'config created' 'file missing' } else {
        Assert-FileEquals $cfg (ExpectedSection @('core', 'fonts', 'guardrail')) '(a) 12 keys written with correct values'
    }
    $log = @(Get-Content $GumLog)
    if ($log.Count -eq 2) { Ok 'preset prompt shown when no existing section' } else { Fail 'preset prompt shown' "gum calls: $($log.Count)" }

    # --- (b) existing accounts survive; section appended
    Write-Host '[2] existing config gains only the packages section'
    $H2 = Join-Path $Tmp 'home2'
    $H2Cfg = Join-Path $H2 '.config/chezmoi/chezmoi.toml'
    New-Item -ItemType Directory -Force -Path (Split-Path $H2Cfg) | Out-Null
    [IO.File]::WriteAllText($H2Cfg, $SeedNoPackages, (New-Object Text.UTF8Encoding($false)))
    $r = Invoke-Menu $H2 'core fonts guardrail'
    if ($r.Exit -ne 0) { Fail 'seeded run exits 0' "exit=$($r.Exit)" } else { Ok 'seeded run exits 0' }
    Assert-FileEquals $H2Cfg ($SeedNoPackages + $nl + (ExpectedSection @('core', 'fonts', 'guardrail'))) '(b) accounts + other sections byte-preserved'

    # --- (c) section in the middle of the file: in-place swap
    Write-Host '[3] re-run rewrites only the packages section (mid-file)'
    $H3 = Join-Path $Tmp 'home3'
    $H3Cfg = Join-Path $H3 '.config/chezmoi/chezmoi.toml'
    New-Item -ItemType Directory -Force -Path (Split-Path $H3Cfg) | Out-Null
    $prefix = "[data]$nl  # seeded by the test$nl$nl"
    $oldSection = "[data.packages]$nl  core = true$nl  fonts = true$nl  guardrail = true$nl$nl"
    $suffix = "[[data.accounts]]$nl  name = `"Work Account`"$nl  email = `"work@example.com`"$nl$nl[add]$nl  secrets = `"warning`"$nl"
    [IO.File]::WriteAllText($H3Cfg, $prefix + $oldSection + $suffix, (New-Object Text.UTF8Encoding($false)))
    $r = Invoke-Menu $H3 'dev_desktop antigravity_desktop'
    if ($r.Exit -ne 0) { Fail 'mid-file re-run exits 0' "exit=$($r.Exit)" } else { Ok 'mid-file re-run exits 0' }
    Assert-FileEquals $H3Cfg ($prefix + (ExpectedSection @('dev_desktop', 'antigravity_desktop')) + $nl + $suffix) '(c) only [data.packages] swapped in place'

    # --- (d) existing keys become the --selected set; no preset on re-run
    Write-Host '[4] re-run pre-checks existing keys'
    $log = @(Get-Content $GumLog)
    if ($log.Count -eq 1) { Ok 'no preset prompt on re-run' } else { Fail 'no preset prompt on re-run' "gum calls: $($log.Count)" }
    if ($log -match '--selected core,fonts,guardrail ') { Ok 'existing true keys became --selected' } else { Fail '--selected set wrong' ($log -join $nl) }

    # --- preset mapping: standard pre-checks exactly its six groups
    Write-Host '[5] standard preset pre-checks its set'
    $H4 = Join-Path $Tmp 'home4'
    New-Item -ItemType Directory -Force -Path $H4 | Out-Null
    $r = Invoke-Menu $H4 ($TestGroups -join ' ') 'standard'
    $log = @(Get-Content $GumLog)
    if ($log.Count -eq 2) { Ok 'preset + groups calls on fresh run' } else { Fail 'preset + groups calls' "gum calls: $($log.Count)" }
    if ($log -match '--selected core,modern_cli,fonts,agent_toolkit,claude_cli,guardrail ') { Ok 'standard preset --selected set' } else { Fail 'standard preset --selected set' ($log -join $nl) }
    $cfg = Join-Path $H4 '.config/chezmoi/chezmoi.toml'
    Assert-FileEquals $cfg (ExpectedSection $TestGroups) 'full selection persisted'

    # --- gum cancel: config untouched
    Write-Host '[6] canceled menu leaves the config untouched'
    $before = [IO.File]::ReadAllText($H3Cfg)
    $r = Invoke-Menu $H3 '__FAIL__'
    if ($r.Exit -ne 0) { Fail 'cancel run exits 0' "exit=$($r.Exit)" } else { Ok 'cancel run exits 0' }
    Assert-FileEquals $H3Cfg $before 'cancel = no write'

    # --- CI gate: skip without prompting
    Write-Host '[7] CI env -> skipping menu'
    $H5 = Join-Path $Tmp 'home5'
    New-Item -ItemType Directory -Force -Path $H5 | Out-Null
    $r = Invoke-Menu $H5 'core' -CI
    if ($r.Exit -ne 0) { Fail 'CI run exits 0' "exit=$($r.Exit)" } else { Ok 'CI run exits 0' }
    if ($r.Output -match 'skipping menu') { Ok 'skipping message printed' } else { Fail 'skipping message' $r.Output }
    if (Test-Path (Join-Path $H5 '.config/chezmoi/chezmoi.toml')) { Fail 'CI run wrote config' 'file exists' } else { Ok 'no config written' }
    if ((Get-Item $GumLog).Length -eq 0) { Ok 'gum never invoked' } else { Fail 'gum invoked in CI' (Get-Content $GumLog -Raw) }
} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

if ($script:Failed.Count -gt 0) {
    Write-Host "FAIL: $($script:Failed.Count) assertion(s): $($script:Failed -join '; ')" -ForegroundColor Red
    exit 1
}
Write-Host "PASS: select-packages.ps1 ($script:PassCount assertions)" -ForegroundColor Green
exit 0
