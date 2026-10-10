#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317,SC2030,SC2031,SC1090  # the sourced library and pwsh consume these; $lib is sourced by path
set -euo pipefail

# Noise cut from `dot up` / `dot upgrade` (2026-10-05 logs) without hiding anything that
# needs attention:
#   1. agent-browser's `doctor --json` printed a ~3 KB single-line blob on every run, on
#      both machines. Now: "agent-browser doctor: N pass, N warn, N fail" plus one line per
#      warn/fail check. Output that is not the expected JSON is printed raw, never dropped.
#   2. fetch_and_verify's curl printed two progress tables per run (WSL log). Now -sS: quiet,
#      still reports errors.
#   3. Playwright's `install-deps` printed ~40 "already the newest version" lines on every
#      WSL run. Now its output goes to a file: shown on failure, apt's summary line only when
#      something was installed, everything with DOT_APT_VERBOSE=1 (executed, fake npx).
# Both languages are EXECUTED. (Claude Code is deliberately NOT updated with `claude update`:
# dot upgrade is meant to run with every agent closed, so the installer is the one path.)
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

lib="$repo_root/scripts/lib/agent-skills.sh"

# --- 2. curl is quiet ---------------------------------------------------------------------
if grep -nE 'curl -fLo' "$lib" >/dev/null; then fail "fetch_and_verify still uses a progress-printing curl (-fLo); use -fsSL -o"; else pass; fi
grep -Fq 'curl -fsSL -o "$dest/SHA256SUMS"' "$lib" || fail "fetch_and_verify must fetch SHA256SUMS with curl -fsSL -o"

# --- 2b. the checksum check is quiet (executed) ----------------------------------------------
# `sha256sum -c` printed "install.sh: OK" on every run (2026-10-09 logs, both dot up and dot
# upgrade); it landed between unrelated steps and read as a result of whichever came before.
# A verified fetch prints nothing at all; a mismatch still warns. curl is a stub that serves
# files from a directory by the URL's basename, so the real net_timeout and checksum tool run.
require "$lib" '$sha -c --quiet SHA256SUMS.one'
mkdir -p "$tmp/fv/bin" "$tmp/fv/srv" "$tmp/fv/dest"
cat >"$tmp/fv/bin/curl" <<'EOF'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
cp "${FV_SRV:?}/$(basename "$url")" "$out"
EOF
chmod +x "$tmp/fv/bin/curl"
printf 'echo installer\n' >"$tmp/fv/srv/install.sh"
fv_sum="$( ( . "$lib"; sha256_cmd ) )"
[ -n "$fv_sum" ] || fail "no SHA-256 tool on this host - fetch_and_verify cannot be executed"
( cd "$tmp/fv/srv" && $fv_sum install.sh >SHA256SUMS )
fv_run() { # fetch_and_verify's whole output lands in fv_out, its exit status in fv_rc
    fv_rc=0
    fv_out="$( ( trap - EXIT; export FV_SRV="$tmp/fv/srv"; PATH="$tmp/fv/bin:$PATH"; . "$lib"
        fetch_and_verify stub-installer "https://x.test/r/install.sh" "https://x.test/r/SHA256SUMS" install.sh "$tmp/fv/dest" ) 2>&1 )" || fv_rc=$?
}
fv_run
[ "$fv_rc" -eq 0 ] || fail "a matching checksum must verify (exit $fv_rc: $fv_out)"
[ -z "$fv_out" ] || fail "a verified fetch must print nothing - no 'install.sh: OK' (got: $fv_out)"
pass
printf 'echo tampered\n' >"$tmp/fv/srv/install.sh"
fv_run
[ "$fv_rc" -ne 0 ] || fail "a checksum mismatch must fail the fetch"
printf '%s' "$fv_out" | grep -Fq 'CHECKSUM MISMATCH' || fail "a checksum mismatch must still warn (got: $fv_out)"
pass

# --- 3. Playwright install-deps is quiet (executed) ------------------------------------------
awk '/# Quiet like the installer.s own apt calls/{f=1} f{print} f && /^        fi$/{exit}' "$repo_root/run_onchange_install_packages.sh.tmpl" >"$tmp/pwdeps.sh"
grep -q 'playwright install-deps chromium' "$tmp/pwdeps.sh" || fail "installer: the Playwright install-deps block was not found"
cat >"$tmp/fake-npx" <<'EOF'
#!/bin/sh
printf 'Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease\nlibnss3 is already the newest version (2:3.98).\n%s\n' "$PW_SUMMARY"
exit "${PW_EXIT:-0}"
EOF
chmod +x "$tmp/fake-npx"
pw_run() { # <summary> <exit> [verbose]; the block runs in a subshell, inside a function (it uses local)
    (
        trap - EXIT   # called inside $( ): the parent's cleanup must not run when this subshell ends
        export PW_SUMMARY="$1" PW_EXIT="$2"
        DOT_APT_VERBOSE="${3:-0}"
        sudo_net_timeout_tty() { shift 2; "$@"; }
        warn() { echo "WARN: $*" >&2; }
        PKG_MANAGER=apt; NPX_BIN="$tmp/fake-npx"; npm_sudo=""
        pw_block() {
            # shellcheck disable=SC1091
            . "$tmp/pwdeps.sh"
        }
        pw_block
    ) 2>&1
}
out="$(pw_run '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.' 0)"
[ -z "$out" ] || fail "install-deps with nothing to do must print nothing (got: $out)"
out="$(pw_run '0 upgraded, 2 newly installed, 0 to remove and 0 not upgraded.' 0)"
[ "$out" = '  Playwright system deps: 0 upgraded, 2 newly installed, 0 to remove and 0 not upgraded.' ] || fail "install-deps that installed something must print apt's summary only (got: $out)"
out="$(pw_run 'E: Unable to locate package libfoo' 100)"
printf '%s' "$out" | grep -Fq 'E: Unable to locate package libfoo' || fail "a failed install-deps must show its output (got: $out)"
printf '%s' "$out" | grep -Fq 'WARN: Playwright system deps install failed' || fail "a failed install-deps must warn (got: $out)"
out="$(pw_run '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.' 0 1)"
printf '%s' "$out" | grep -Fq 'already the newest version' || fail "DOT_APT_VERBOSE=1 must show install-deps' output (got: $out)"
pass

# --- 1. agent-browser doctor summary (bash) -------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    cat >"$tmp/ab-ok" <<'EOF'
#!/bin/sh
printf '%s\n' '{"checks":[{"category":"Environment","id":"env.version","message":"CLI version 0.38.2","status":"pass"},{"category":"Chrome","id":"chrome.installed","message":"Chrome is missing","status":"warn","fix":"agent-browser install"},{"category":"Providers","id":"p","message":"no key","status":"info"}],"success":true,"summary":{"fail":0,"pass":1,"warn":1}}'
EOF
    cat >"$tmp/ab-bad" <<'EOF'
#!/bin/sh
printf '%s\n' 'this is not json'
exit 4
EOF
    chmod +x "$tmp/ab-ok" "$tmp/ab-bad"
    # shellcheck source=/dev/null
    run_doctor() { ( . "$lib"; agent_browser_doctor "$1" ) 2>&1; }
    out="$(run_doctor "$tmp/ab-ok")"
    printf '%s\n' "$out" | grep -Fxq 'agent-browser doctor: 1 pass, 1 warn, 0 fail' || fail "doctor summary line missing (got: $out)"
    printf '%s\n' "$out" | grep -Fq 'warn: Chrome is missing' || fail "a warn check must be listed (got: $out)"
    printf '%s\n' "$out" | grep -Fq 'fix: agent-browser install' || fail "the fix hint must be listed (got: $out)"
    if printf '%s\n' "$out" | grep -Fq '"checks"'; then fail "the raw JSON must not be printed"; else pass; fi
    if printf '%s\n' "$out" | grep -Fq 'no key'; then fail "info checks are not worth a line"; else pass; fi
    set +e
    out="$(run_doctor "$tmp/ab-bad")"
    rc=$?
    set -e
    printf '%s\n' "$out" | grep -Fq 'this is not json' || fail "unexpected output must be printed raw, not dropped (got: $out)"
    [ "$rc" -ne 0 ] || fail "doctor's exit status must be passed through (got 0)"
else
    printf 'SKIP (doctor summary, bash): jq not installed\n'
fi

# --- PowerShell: summary and skills messages ----------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$SkillsLib, [string]$CommonLib, [string]$UserDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $UserDir
. $SkillsLib
. $CommonLib

function Capture([scriptblock]$Run) { (& $Run *>&1 | Out-String) }

# --- agent-browser doctor summary ---
$json = '{"checks":[{"category":"Environment","id":"env.version","message":"CLI version 0.38.2","status":"pass"},{"category":"Chrome","id":"chrome.installed","message":"Chrome is missing","status":"warn","fix":"agent-browser install"},{"category":"Providers","id":"p","message":"no key","status":"info"}],"success":true,"summary":{"fail":0,"pass":1,"warn":1}}'
$o = Capture { Write-AgentBrowserDoctorSummary -Output @($json) }
Write-Output ('doctor-summary=' + ($o -match 'agent-browser doctor: 1 pass, 1 warn, 0 fail'))
Write-Output ('doctor-warn-listed=' + ($o -match 'warn: Chrome is missing' -and $o -match 'fix: agent-browser install'))
Write-Output ('doctor-no-raw-json=' + (-not ($o -match '"checks"')))
Write-Output ('doctor-no-info=' + (-not ($o -match 'no key')))
$o = Capture { Write-AgentBrowserDoctorSummary -Output @('this is not json') }
Write-Output ('doctor-raw-fallback=' + ($o -match 'this is not json'))
$o = Capture { Write-AgentBrowserDoctorSummary -Output @() }
Write-Output ('doctor-empty-silent=' + ($o.Trim() -eq ''))

# --- Invoke-SkillsSource messages: one line per source, "<label>: up to date" or ": installed" ---
function Get-SkillsRemoteHead { param([string]$Repo) return 'abc123' }
foreach ($d in '.claude', '.agents') {
    New-Item -Force -ItemType Directory (Join-Path $UserDir "$d\skills\s1") | Out-Null
    Set-Content -LiteralPath (Join-Path $UserDir "$d\skills\s1\SKILL.md") -Value ''
}
$script:ranInstall = 0
$o = Capture { Invoke-SkillsSource -Label 'my skill' -Repo 'o/r' -Skills 's1' -Agents @('claude-code') -Install { $script:ranInstall++; $true } }
Write-Output ('skills-installed-line=' + ($o -match 'my skill: installed'))
$o = Capture { Invoke-SkillsSource -Label 'my skill' -Repo 'o/r' -Skills 's1' -Agents @('claude-code') -Install { $script:ranInstall++; $true } }
Write-Output ('skills-uptodate-line=' + ($o -match 'my skill: up to date'))
Write-Output ('skills-uptodate-no-install=' + ($script:ranInstall -eq 1))
PSEOF
    mkdir -p "$tmp/home"
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -SkillsLib "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" -CommonLib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" -UserDir "$(winpath "$tmp/home")" 2>&1 | tr -d '\r' || true)"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-500))"; }
    expect 'doctor-summary=True'
    expect 'doctor-warn-listed=True'
    expect 'doctor-no-raw-json=True'
    expect 'doctor-no-info=True'
    expect 'doctor-raw-fallback=True'
    expect 'doctor-empty-silent=True'
    expect 'skills-installed-line=True'
    expect 'skills-uptodate-line=True'
    expect 'skills-uptodate-no-install=True'
else
    printf 'SKIP (PowerShell part): pwsh not installed\n'
fi

finish
