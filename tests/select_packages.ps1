#Requires -Version 5.1
# Tests for scripts/select-packages.ps1 — the gum package-group menu (Windows
# twin). Mirrors tests/select_packages.sh: fake gum on PATH serves canned
# `choose` results and tees argv to $env:FAKE_GUM_LOG; a child pwsh runs the
# script under test with HOME/USERPROFILE pointed at temp dirs.
#
# The script under test gates on stdin being a real console
# ([Console]::IsInputRedirected -eq $false — the [ -t 0 ] twin) plus
# -not $env:CI, so interactive scenarios run the child under a pty via a
# python3 helper (which also sets a 24x80 winsize: pwsh livelocks on a 0x0
# pty, exactly what util-linux `script` allocates when its own stdin is not
# a terminal). Hosts without python3 (e.g. Windows) invoke the child directly
# and rely on the harness console. The no-TTY path is piped stdin into the
# child; the $env:CI arm is exercised by setting CI in the child.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ScriptUnderTest = Join-Path $RepoRoot 'scripts/select-packages.ps1'

# Windows has no pty to fake a console with, so the interactive scenarios only
# work when this harness itself runs from a real console. Under a captured or
# piped shell every one of them takes the script's no-TTY path and fails, which
# is noise, not a regression - skip instead. CI runs this test on Linux, where
# the python pty helper below provides a console.
if (($IsWindows -or $env:OS -eq 'Windows_NT') -and [Console]::IsInputRedirected) {
    Write-Host 'SKIP: select_packages.ps1 needs a console stdin on Windows (CI runs it on Linux)'
    exit 0
}

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

# The 16 groups in taxonomy order — plan Global Constraints.
$TestGroups = @('core', 'modern_cli', 'fonts', 'agent_toolkit', 'opencode_cli',
    'opencode_desktop', 'claude_cli', 'claude_desktop', 'chatgpt_cli',
    'chatgpt_desktop', 'antigravity_cli', 'antigravity_desktop', 'dev_desktop',
    'remote_access', 'remote_access_server', 'guardrail')

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
    # The test file is CRLF (.gitattributes: *.ps1 eol=crlf), so this here-string
    # inherits CRLF. Written verbatim, the shebang keeps a trailing CR and Linux
    # fails with: /usr/bin/env: 'bash\r': No such file or directory - gum then
    # never runs and every interactive assertion fails (confirmed live).
    $gumSh = @'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GUM_LOG:?}"
if [[ "$*" == *--no-limit* ]]; then
    [[ "$FAKE_MULTI" == "__FAIL__" ]] && exit 130
    tr ' ' '\n' <<<"${FAKE_MULTI:?}" | sed '/^$/d'
else
    printf '%s\n' "${FAKE_PRESET:-custom}"
fi
'@
    [IO.File]::WriteAllText((Join-Path $Bin 'gum'), ($gumSh -replace "`r`n", "`n"))
    chmod +x (Join-Path $Bin 'gum')
}

# Interactive runs need a real console stdin for the gate. Non-Windows
# harnesses often have none (CI, agent shells), so spawn the child under a
# pty. The helper sets a 24x80 winsize before exec — pwsh livelocks on a 0x0
# pty, which is what util-linux `script` leaves when its own stdin is not a
# terminal, so `script` cannot be used here. Windows (or python3-less hosts)
# fall back to direct invocation, which works whenever the harness itself
# runs from a console.
$IsWinHost = ($IsWindows -or $env:OS -eq 'Windows_NT')
$Python = $null
$PtyRunner = $null
if (-not $IsWinHost) {
    $Python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $Python) { $Python = Get-Command python -ErrorAction SilentlyContinue }
    if ($Python) {
        $PtyRunner = Join-Path $Tmp 'ptyrun.py'
        @'
import fcntl, os, pty, select, signal, struct, sys, termios, time

# ptyrun.py TIMEOUT CMD... — run CMD under a 24x80 pty, echo its output, exit
# with the child's exit code (killed past TIMEOUT).
timeout = float(sys.argv[1])
cmd = sys.argv[2:]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
pid = os.fork()
if pid == 0:
    os.close(master)
    os.setsid()
    try:
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    except OSError:
        pass
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    if slave > 2:
        os.close(slave)
    try:
        os.execvp(cmd[0], cmd)
    finally:
        os._exit(127)
os.close(slave)
status = None
deadline = time.monotonic() + timeout
while status is None:
    try:
        wpid, st = os.waitpid(pid, os.WNOHANG)
        if wpid:
            status = st
            break
    except ChildProcessError:
        status = 0
        break
    if time.monotonic() > deadline:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        break
    try:
        ready, _, _ = select.select([master], [], [], 0.2)
    except OSError:
        continue
    if ready:
        try:
            data = os.read(master, 65536)
        except OSError:
            continue
        if data:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
while True:
    try:
        data = os.read(master, 65536)
    except OSError:
        break
    if not data:
        break
    sys.stdout.buffer.write(data)
sys.stdout.buffer.flush()
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(1)
'@ | Set-Content -Path $PtyRunner -Encoding Ascii
    }
}

# Run the script under test in a child pwsh with a swapped environment.
# $FakeMulti = canned multi result (words), $FakePreset = canned preset answer.
# -NoTty pipes stdin into the child (the redirected/CI shape); -CI sets
# $env:CI in the child instead of clearing it.
function Invoke-Menu([string]$homeDir, [string]$fakeMulti, [string]$fakePreset = 'custom', [switch]$CI, [switch]$NoTty) {
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
        if ($NoTty) {
            # Piped stdin = IsInputRedirected $true = the no-console shape.
            $out = '' | & pwsh -NoProfile -File $ScriptUnderTest 2>&1 | Out-String
        } elseif ($PtyRunner) {
            # Real console stdin via pty (python helper sets a sane winsize).
            $out = & $Python $PtyRunner 30 pwsh -NoProfile -File $ScriptUnderTest 2>&1 | Out-String
        } else {
            $out = & pwsh -NoProfile -File $ScriptUnderTest 2>&1 | Out-String
        }
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
    # --- (a) fresh machine, no config: file created with exactly the 16 keys
    Write-Host '[1] fresh run creates the config with the 16 keys'
    $H1 = Join-Path $Tmp 'home1'
    New-Item -ItemType Directory -Force -Path $H1 | Out-Null
    $r = Invoke-Menu $H1 'core fonts guardrail'
    if ($r.Exit -ne 0) { Fail 'fresh run exits 0' "exit=$($r.Exit) out=$($r.Output)" } else { Ok 'fresh run exits 0' }
    $cfg = Join-Path $H1 '.config/chezmoi/chezmoi.toml'
    if (-not (Test-Path $cfg)) { Fail 'config created' 'file missing' } else {
        Assert-FileEquals $cfg (ExpectedSection @('core', 'fonts', 'guardrail')) '(a) 16 keys written with correct values'
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
    $r = Invoke-Menu $H3 'dev_desktop remote_access_server antigravity_desktop'
    if ($r.Exit -ne 0) { Fail 'mid-file re-run exits 0' "exit=$($r.Exit)" } else { Ok 'mid-file re-run exits 0' }
    Assert-FileEquals $H3Cfg ($prefix + (ExpectedSection @('dev_desktop', 'remote_access_server', 'antigravity_desktop')) + $nl + $suffix) '(c) only [data.packages] swapped in place'

    # --- (d) existing keys become the --selected set; no preset on re-run
    Write-Host '[4] re-run pre-checks existing keys'
    $log = @(Get-Content $GumLog)
    if ($log.Count -eq 1) { Ok 'no preset prompt on re-run' } else { Fail 'no preset prompt on re-run' "gum calls: $($log.Count)" }
    if ($log -match '--selected core,fonts,guardrail ') { Ok 'existing true keys became --selected' } else { Fail '--selected set wrong' ($log -join $nl) }

    # --- preset mapping: full pre-checks all but the server opt-in
    Write-Host '[5] full preset omits the server opt-in'
    $H4 = Join-Path $Tmp 'home4'
    New-Item -ItemType Directory -Force -Path $H4 | Out-Null
    $r = Invoke-Menu $H4 ($TestGroups -join ' ') 'full'
    $log = @(Get-Content $GumLog)
    if ($log.Count -eq 2) { Ok 'preset + groups calls on fresh run' } else { Fail 'preset + groups calls' "gum calls: $($log.Count)" }
    if ($log -match '--selected core,modern_cli,fonts,agent_toolkit,opencode_cli,opencode_desktop,claude_cli,claude_desktop,chatgpt_cli,chatgpt_desktop,antigravity_cli,antigravity_desktop,dev_desktop,remote_access,guardrail ') { Ok 'full preset omits remote_access_server' } else { Fail 'full preset --selected set' ($log -join $nl) }
    $cfg = Join-Path $H4 '.config/chezmoi/chezmoi.toml'
    Assert-FileEquals $cfg (ExpectedSection $TestGroups) 'full selection persisted'

    # --- gum cancel: config untouched
    Write-Host '[6] canceled menu leaves the config untouched'
    $before = [IO.File]::ReadAllText($H3Cfg)
    $r = Invoke-Menu $H3 '__FAIL__'
    if ($r.Exit -ne 0) { Fail 'cancel run exits 0' "exit=$($r.Exit)" } else { Ok 'cancel run exits 0' }
    Assert-FileEquals $H3Cfg $before 'cancel = no write'

    # --- CI safety: redirected stdin (the GH Actions hang shape), or CI env --
    Write-Host '[7] redirected stdin, CI unset -> skipping menu'
    $H5 = Join-Path $Tmp 'home5'
    New-Item -ItemType Directory -Force -Path $H5 | Out-Null
    $r = Invoke-Menu $H5 'core' -NoTty
    if ($r.Exit -ne 0) { Fail 'no-tty run exits 0' "exit=$($r.Exit) out=$($r.Output)" } else { Ok 'no-tty run exits 0' }
    if ($r.Output -match 'skipping menu') { Ok 'no-tty skipping message printed' } else { Fail 'no-tty skipping message' $r.Output }
    if (Test-Path (Join-Path $H5 '.config/chezmoi/chezmoi.toml')) { Fail 'no-tty run wrote config' 'file exists' } else { Ok 'no-tty: no config written' }
    if ((Get-Item $GumLog).Length -eq 0) { Ok 'no-tty: gum never invoked' } else { Fail 'no-tty: gum invoked' (Get-Content $GumLog -Raw) }

    Write-Host '[8] CI env set, console stdin -> skipping menu'
    $r = Invoke-Menu $H5 'core' -CI
    if ($r.Exit -ne 0) { Fail 'CI run exits 0' "exit=$($r.Exit)" } else { Ok 'CI run exits 0' }
    if ($r.Output -match 'skipping menu') { Ok 'CI skipping message printed' } else { Fail 'CI skipping message' $r.Output }
    if ((Get-Item $GumLog).Length -eq 0) { Ok 'CI: gum never invoked' } else { Fail 'CI: gum invoked' (Get-Content $GumLog -Raw) }
} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

if ($script:Failed.Count -gt 0) {
    Write-Host "FAIL: $($script:Failed.Count) assertion(s): $($script:Failed -join '; ')" -ForegroundColor Red
    exit 1
}
Write-Host "PASS: select-packages.ps1 ($script:PassCount assertions)" -ForegroundColor Green
exit 0
