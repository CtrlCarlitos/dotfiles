#!/usr/bin/env bash
set -euo pipefail

# Graft on Windows: a PATH shim is not proof that the native parser builds
# are usable. EXECUTED (v2, #135): the graft install chain is extracted from
# the rendered installer and run under pwsh against stubbed graft/npm/python/
# vswhere/winget binaries, covering:
#   - healthy CLI  -> nothing reinstalls, telemetry still disabled;
#   - dead CLI + toolchain present -> one npm -g install carrying the catalog's
#     --allow-scripts list with NPM_CONFIG_PYTHON pointed at a supported
#     Python, then re-verify + telemetry off;
#   - Build Tools missing -> the 1.0.4 winget install fires, and when it did
#     not help the manual guidance is printed and graft is skipped;
#   - Python missing or unsupported (<3.8) -> hard skip BEFORE any winget.
# Also executed: the JSONC-tolerant parser (comments, trailing commas, URLs
# with //) and its loud failure on malformed input. The StrictMode-safe
# PSObject.Properties probe keeps its one grep (parse-time property).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed (rendering requires it)"

tmp="$(mktemp -d)"
trap '[ -n "${KEEP_TMP:-}" ] || rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin" "$tmp/vsdir/Microsoft Visual Studio/Installer" "$tmp/empty-vs"

rendered="$tmp/installer.ps1"
render_to "$rendered" ps1 '{"agent_toolkit": true}'
[ -s "$rendered" ] || fail "ps1 installer did not render"

# Extraction anchors (rendered output; the graft chain ends where the static
# ScreenRec comment starts - same gate, next block).
iwt_start="$(grep -nF 'function Invoke-WithTimeout' "$rendered" | head -1 | cut -d: -f1)"
iwt_end="$(awk -v s="$iwt_start" 'NR > s && $0 == "}"{print NR; exit}' "$rendered")"
jqc_start="$(grep -nF 'function ConvertFrom-JsonC' "$rendered" | head -1 | cut -d: -f1)"
jqc_end="$(awk -v s="$jqc_start" 'NR > s && $0 == "}"{print NR; exit}' "$rendered")"
chain_start="$(grep -nE '^if \(Get-Command graft -ErrorAction SilentlyContinue\) \{$' "$rendered" | head -1 | cut -d: -f1)"
# End BEFORE the guardrail section that shares this gate: with packages.guardrail
# unset its disabled branch would run against the HOST's real guardrail state
# (observed: it reached for the live release). The chain must stay graft-only.
chain_end="$(grep -nF '# guardrail-section: begin' "$rendered" | head -1 | cut -d: -f1)"
chain_end=$((chain_end - 1))
for v in "$iwt_start" "$iwt_end" "$jqc_start" "$jqc_end" "$chain_start" "$chain_end"; do
    [ -n "$v" ] || fail "rendered installer: extraction anchor missing"
done

# --- PATH stubs -----------------------------------------------------------------
# (graft itself is a fixture-side function below - see the note there.)

# npm: logs argv and the NPM_CONFIG_PYTHON it inherited.
cat >"$bin/npm.cmd" <<EOF
@echo off
echo %* >> "%NPM_LOG%"
echo NPM_CONFIG_PYTHON=%NPM_CONFIG_PYTHON%>> "%NPM_LOG%"
exit /b 0
EOF
case "${OSTYPE:-}" in
    msys*|cygwin*) ;;
    *)
        cat >"$bin/npm" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${NPM_LOG:?}"
printf 'NPM_CONFIG_PYTHON=%s\n' "${NPM_CONFIG_PYTHON:-}" >> "${NPM_LOG:?}"
exit 0
EOF
        chmod +x "$bin/npm"
        ;;
esac

# python / py: the FIRST invocation is the `sys.executable` probe and prints
# the stub itself (a real executable); every later invocation is the version
# probe and echoes PY_MODE ('supported'/'unsupported'). PY_MODE=absent fails
# both probes outright (models "no usable Python"). Stateful instead of
# argv-parsing: cmd's findstr proved flaky inside Invoke-Expression.
for launcher in python py; do
    cat >"$bin/$launcher.cmd" <<EOF
@echo off
if "%PY_MODE%"=="absent" exit /b 1
if exist "%PY_STATE%" goto verdict
echo %~f0
>"%PY_STATE%" echo 1
exit /b 0
:verdict
echo %PY_MODE%
exit /b 0
EOF
done
case "${OSTYPE:-}" in
    msys*|cygwin*) ;;
    *)
        for launcher in python py; do
            cat >"$bin/$launcher" <<EOF
#!/bin/sh
[ "\${PY_MODE:-supported}" = absent ] && exit 1
state="\${PY_STATE:?}"
if [ ! -e "\$state" ]; then
    printf '%s\\n' "\$0"
    : >"\$state"
    exit 0
fi
printf '%s\\n' "\${PY_MODE:-supported}"
EOF
            chmod +x "$bin/$launcher"
        done
        ;;
esac

# winget: logs argv (only the Build-Tools path should reach it).
cat >"$bin/winget.cmd" <<EOF
@echo off
echo %* >> "%WINGET_LOG%"
exit /b 0
EOF
case "${OSTYPE:-}" in
    msys*|cygwin*) ;;
    *)
        printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${WINGET_LOG:?}"\nexit 0\n' >"$bin/winget"
        chmod +x "$bin/winget"
        ;;
esac

# vswhere stub: lives under a stubbed ProgramFiles(x86); prints its log line.
# Windows needs a REAL exe there (CreateProcess rejects batch content in an
# .exe), so a minimal one is compiled with the in-box csc - the same
# dependency tests/dotbackup_restore.ps1 carries. On CI Linux the file is a
# shebang script and pwsh executes it by content.
vswhere_cs="$tmp/vswhere.cs"
win_vswhere_exe="$(cygpath -w "$tmp/vsdir/Microsoft Visual Studio/Installer/vswhere.exe" 2>/dev/null || printf '%s' "$tmp/vsdir/Microsoft Visual Studio/Installer/vswhere.exe")"
case "${OSTYPE:-}" in
    msys*|cygwin*)
        cat >"$vswhere_cs" <<'EOF'
using System;
class V {
    static int Main() {
        Console.Out.Write("VSPATH" + Environment.GetEnvironmentVariable("VSWHERE_OUT"));
        return 0;
    }
}
EOF
        csc_exe="/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
        [ -f "$csc_exe" ] || skip "in-box csc.exe not found (cannot build the stub vswhere)"
        "$csc_exe" -nologo -out:"$win_vswhere_exe" "$(cygpath -w "$vswhere_cs")" >/dev/null ||
            fail "could not compile the stub vswhere.exe"
        ;;
    *)
        printf '#!/bin/sh\nprintf "VSPATH%%s\\n" "${VSWHERE_OUT:-}"\n' \
            >"$tmp/vsdir/Microsoft Visual Studio/Installer/vswhere.exe"
        chmod +x "$tmp/vsdir/Microsoft Visual Studio/Installer/vswhere.exe"
        ;;
esac

fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"
cat >"$fixture" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$rendered, $iwtStart, $iwtEnd, $jqcStart, $jqcEnd, $chainStart, $chainEnd, $mode = $args
$lines = [IO.File]::ReadAllLines($rendered)
function Slice([object[]]$All, [int]$From, [int]$To) { ($All[($From - 1)..($To - 1)] -join "`n") + "`n" }
$iwt = Slice $lines $iwtStart $iwtEnd
$jqc = Slice $lines $jqcStart $jqcEnd
$chain = Slice $lines $chainStart $chainEnd

function Fail([string]$m) { Write-Host "FAIL: $m"; exit 1 }
function Invoke-Quietly { param([string]$Description, [scriptblock]$Action) try { & $Action } catch { Write-Host "  Warning: $Description - $_" } }
Invoke-Expression $iwt

# graft as a FUNCTION: the chain rebuilds $env:Path from the registry
# (Machine;User) after installing, which would drop any PATH stub - and could
# then resolve the HOST's real graft. A function keeps beating PATH lookups,
# so probes, telemetry and argv logging stay hermetic. Same stateful contract
# as the file stubs: the first GRAFT_FAIL_FIRST calls fail, then succeed.
$script:grafN = 0
function graft {
    $script:grafN++
    ($args -join ' ') | Add-Content -LiteralPath $env:GRAFT_LOG_WIN
    if ($script:grafN -le [int]$env:GRAFT_FAIL_FIRST) { $global:LASTEXITCODE = 1; return }
    $global:LASTEXITCODE = 0
}

switch ($mode) {
    'jsonc' {
        function Test-JsonC([string]$t) { Invoke-Expression $jqc | Out-Null; ConvertFrom-JsonC $t }
        $t = @'
{"a": 1, // trailing comment
 "b": ["x", "https://x//y",], /* block comment */
 "c": { "d": 2, },}
'@
        $obj = Test-JsonC $t
        if ($obj.a -ne 1 -or $obj.b.Count -ne 2 -or $obj.b[1] -cne 'https://x//y' -or $obj.c.d -ne 2) { Fail "JSONC parse wrong: $($obj | ConvertTo-Json -Compress)" }
        try { Test-JsonC '{not json' ; Fail 'malformed JSONC must throw' } catch { Write-Host '  ok: malformed JSONC throws' }
    }
    'full' {
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $env:G_VSDIR, 'Process')
        Invoke-Expression $chain
        $npm = Get-Content $env:NPM_LOG
        if (-not ($npm -match '@nanonets/graft')) { Fail "npm must install graft; saw: $npm" }
        if (-not ($npm -match '--allow-scripts=@nanonets/graft')) { Fail 'the native-build allowlist must ride the install' }
        if (-not ($npm -match 'NPM_CONFIG_PYTHON=.+')) { Fail 'node-gyp must be pointed at the supported Python' }
        $glog = Get-Content $env:GRAFT_LOG_WIN
        if (-not ($glog -match 'telemetry disable')) { Fail 'telemetry must be disabled after a successful install' }
        if (Test-Path $env:WINGET_LOG) { Fail 'winget must not run when the toolchain is present' }
    }
    'nobuildtools' {
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $env:G_EMPTYVS, 'Process')
        Invoke-Expression $chain
        $wlog = Get-Content $env:WINGET_LOG
        if (-not ($wlog -match 'Microsoft.VisualStudio.2022.BuildTools')) { Fail "the winget Build-Tools install must fire; saw: $wlog" }
    }
    'nopython' {
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $env:G_EMPTYVS, 'Process')
        Invoke-Expression $chain
        if (Test-Path $env:WINGET_LOG) { Fail 'a Python problem must skip graft BEFORE any multi-GB winget install' }
    }
    'graftok' {
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $env:G_VSDIR, 'Process')
        Invoke-Expression $chain
        if (Test-Path $env:NPM_LOG) { Fail 'a healthy graft must not be reinstalled' }
        $glog = Get-Content $env:GRAFT_LOG_WIN
        if (-not ($glog -match 'telemetry disable')) { Fail 'telemetry must be disabled for a healthy graft too' }
    }
    default { Fail "unknown mode: $mode" }
}
POWERSHELL

fixture_ok() { # $1 = fixture log, $2 = label - the fixture's FAIL lines decide
    if grep -q 'FAIL' "$1"; then fail "$2: $(cat "$1")"; else pass; fi
}

run_ps() { # $1 = mode, $2 = outfile; stub behavior via env
    local mode="$1" outfile="$2"
    local wintmp vsdir emptyvs
    wintmp="$(cygpath -w "$tmp" 2>/dev/null || printf '%s' "$tmp")"
    vsdir="$(cygpath -w "$tmp/vsdir" 2>/dev/null || printf '%s' "$tmp/vsdir")"
    emptyvs="$(cygpath -w "$tmp/empty-vs" 2>/dev/null || printf '%s' "$tmp/empty-vs")"
    # Scenario isolation: the stateful stubs must start cold every run, and
    # the presence-checks compare against freshly-created logs only.
    rm -f "$tmp/py-state" "$tmp/npm.log" "$tmp/winget.log" "$tmp/graft.log"
    PATH="$bin:/usr/bin:/bin" \
        GRAFT_LOG_WIN="$wintmp\\graft.log" NPM_LOG="$wintmp\\npm.log" WINGET_LOG="$wintmp\\winget.log" \
        PY_STATE="$wintmp\\py-state" GRAFT_FAIL_FIRST="${GRAFT_FAIL_FIRST:-0}" \
        PY_MODE="${PY_MODE:-supported}" VSWHERE_OUT="${VSWHERE_OUT:-vs-path}" \
        G_VSDIR="$vsdir" G_EMPTYVS="$emptyvs" \
        "$(command -v pwsh)" -NoProfile -File "$fixture" "$rendered" "$iwt_start" "$iwt_end" "$jqc_start" "$jqc_end" "$chain_start" "$chain_end" "$mode" \
        >"$outfile" 2>&1
}

# JSONC parser behaviour.
run_ps jsonc "$tmp/jsonc.log" || fail "jsonc scenario failed: $(cat "$tmp/jsonc.log")"
grep -q 'ok: malformed JSONC throws' "$tmp/jsonc.log" || fail "jsonc: $(cat "$tmp/jsonc.log")"

# Healthy CLI: no reinstall, telemetry still disabled.
rm -f "$tmp/npm.log" "$tmp/winget.log"
GRAFT_FAIL_FIRST=0 run_ps graftok "$tmp/graftok.log" || fail "graftok scenario failed: $(cat "$tmp/graftok.log")"
fixture_ok "$tmp/graftok.log" "graftok"

# Dead CLI + full toolchain: catalog-driven install with the Python pin.
: >"$tmp/npm.log"; rm -f "$tmp/winget.log"
GRAFT_FAIL_FIRST=1 run_ps full "$tmp/full.log" || fail "full scenario failed: $(cat "$tmp/full.log")"
fixture_ok "$tmp/full.log" "full"
grep -Fq 'NPM_CONFIG_PYTHON=' "$tmp/npm.log" || fail "the npm log lost the python pin line"

# Missing Build Tools: winget fires once, then the manual guidance.
rm -f "$tmp/npm.log"
GRAFT_FAIL_FIRST=1 run_ps nobuildtools "$tmp/nbt.log" || fail "nobuildtools scenario failed: $(cat "$tmp/nbt.log")"
fixture_ok "$tmp/nbt.log" "nobuildtools"
grep -Fq 'Build Tools still not detected after the winget attempt' "$tmp/nbt.log" ||
    fail "a failed winget attempt must be reported before skipping graft"
grep -Fq 'Install the C++ Build Tools manually' "$tmp/nbt.log" ||
    fail "the manual guidance must survive as the fallback"
if [ -s "$tmp/npm.log" ]; then fail "graft must not be installed without the Build Tools"; else pass; fi

# Python missing/unsupported: hard skip BEFORE winget.
rm -f "$tmp/winget.log"
PY_MODE=absent GRAFT_FAIL_FIRST=1 run_ps nopython "$tmp/nopy.log" || fail "nopython scenario failed: $(cat "$tmp/nopy.log")"
fixture_ok "$tmp/nopy.log" "nopython"
grep -Fq 'Graft needs Python 3.8+ for native parser builds - skipping Graft' "$tmp/nopy.log" ||
    fail "a missing Python must be reported"
grep -Fq 'Install Python manually' "$tmp/nopy.log" || fail "the Python guidance must survive"
if [ -e "$tmp/winget.log" ]; then fail "winget must not run when Python is missing"; else pass; fi
PY_MODE=unsupported GRAFT_FAIL_FIRST=1 run_ps nopython "$tmp/oldpy.log" || fail "oldpython scenario failed: $(cat "$tmp/oldpy.log")"
fixture_ok "$tmp/oldpy.log" "oldpython"
grep -Fq 'Graft needs Python 3.8+ for native parser builds - skipping Graft' "$tmp/oldpy.log" ||
    fail "an unsupported Python (<3.8) must be reported"

# The StrictMode-safe JSON probe must stay (parse-time property, one grep).
require "$repo_root/run_onchange_install_packages.ps1.tmpl" '$vsJson.PSObject.Properties[$k]'

rm -f "$fixture"
finish
