#!/usr/bin/env bash
set -euo pipefail

# [data.logging] (docs/logging.md): every installer run can keep a live log, and verbose stops the
# console hiding output. Born from the 2026-10-14 fresh Windows install: the operator answers the
# installer's questions in their own terminal while an agent follows the run from another one, and a
# console nobody else can see was the only record. Executed here, not grepped (invariant 14):
#   1. the bash lib (scripts/lib/logging.sh): flag precedence env > config > default, the tee'd log,
#      the newest-20 prune, the verbose switches;
#   2. install.sh's POSIX twin (FIFO + tee), run under sh;
#   3. the PowerShell lib (scripts/lib/ps-installer-output.ps1) under pwsh: the same precedence and
#      a transcript that holds what the run wrote;
#   4. wiring: every installer opens its log, and no run_onchange template reads .logging - a
#      rendered value would change the script's hash, so toggling verbose would re-run the install.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap '[ -n "${KEEP_TMP:-}" ] || rm -rf "$tmp"' EXIT

write_cfg() { # $1 = home, $2 = log value, $3 = verbose value
    mkdir -p "$1/.config/chezmoi"
    cat >"$1/.config/chezmoi/chezmoi.toml" <<EOF
[data.upgrade]
  log = true

  [data.logging]
    log     = $2   # a trailing comment is fine
    verbose = $3

[data.packages]
  core = true
EOF
}

# --- 1. bash lib --------------------------------------------------------------------------
lib="$repo_root/scripts/lib/logging.sh"
flag() { # $1 = home, then dot_log_flag args; env from the caller
    HOME="$1" bash -c '. "$0"; dot_log_flag "$@"' "$lib" "${@:2}"
}
h="$tmp/flags"
mkdir -p "$h"
[ "$(flag "$h" DOT_LOG log true)" = true ] || fail "bash: no config, no env -> the default"
write_cfg "$h" false true
[ "$(flag "$h" DOT_LOG log true)" = false ] || fail "bash: [data.logging] log = false must win over the default"
[ "$(flag "$h" DOT_VERBOSE verbose false)" = true ] || fail "bash: [data.logging] verbose = true must be read"
[ "$(DOT_LOG=Yes flag "$h" DOT_LOG log true)" = true ] || fail "bash: DOT_LOG=Yes must override the config"
[ "$(DOT_LOG=0 flag "$h" DOT_LOG log true)" = false ] || fail "bash: DOT_LOG=0 must turn logging off"
[ "$(DOT_LOG=maybe flag "$h" DOT_LOG log true)" = false ] || fail "bash: an unknown env value falls through to the config"
pass

h="$tmp/open"
mkdir -p "$h/.local/state/dotfiles/logs"
for i in $(seq 1 25); do
    f="$h/.local/state/dotfiles/logs/old-$i.log"
    : >"$f"
    touch -t "20260101$(printf '%02d' $((i % 24)))00" "$f"
done
HOME="$h" bash -c '. "$0"; dot_log_open run; dot_log_verbose; echo "from-the-run $DOT_APT_VERBOSE$DOT_GUARDRAIL_VERBOSE$DOT_SKILLS_VERBOSE"; echo "to-stderr" >&2' "$lib" >"$tmp/open.out" 2>&1 || true
# shellcheck disable=SC2012
log="$(ls -1t "$h"/.local/state/dotfiles/logs/run-*.log 2>/dev/null | head -n 1 || true)"
if [ -n "$log" ]; then
    sleep 1 # tee drains after the shell exits
    grep -Fq 'from-the-run' "$log" || fail "bash: the run's stdout must reach its log: $(cat "$log")"
    grep -Fq 'to-stderr' "$log" || fail "bash: the run's stderr must reach its log"
    grep -Fq 'Live log:' "$tmp/open.out" || fail "bash: the console must say where the log is"
    # shellcheck disable=SC2012
    count="$(ls -1 "$h"/.local/state/dotfiles/logs/*.log | wc -l | tr -d ' ')"
    [ "$count" -le 20 ] || fail "bash: the log directory must keep the newest 20 logs (has $count)"
    if grep -Fq 'from-the-run 111' "$tmp/open.out"; then fail "bash: verbose must stay off by default"; fi
    pass
else
    fail "bash: dot_log_open wrote no log: $(cat "$tmp/open.out")"
fi
h="$tmp/verbose"
write_cfg "$h" false true
HOME="$h" bash -c '. "$0"; dot_log_open run; dot_log_verbose; echo "flags=$DOT_APT_VERBOSE$DOT_GUARDRAIL_VERBOSE$DOT_SKILLS_VERBOSE"' "$lib" >"$tmp/verbose.out" 2>&1
grep -Fq 'flags=111' "$tmp/verbose.out" || fail "bash: verbose = true must export the three switches: $(cat "$tmp/verbose.out")"
[ ! -d "$h/.local/state/dotfiles/logs" ] || [ -z "$(ls -A "$h/.local/state/dotfiles/logs")" ] ||
    fail "bash: log = false must write no log"
pass

# --- 2. install.sh (POSIX sh twin) ----------------------------------------------------------
fn="$tmp/install_log.sh"
awk '/^install_log_flag\(\) \{/{f=1} f{print} /^start_install_log$/{exit}' "$repo_root/install.sh" >"$fn"
grep -q '^start_install_log$' "$fn" || fail "install.sh: start_install_log not found (the extraction is the contract)"
h="$tmp/installsh"
mkdir -p "$h"
HOME="$h" sh -c '. "$0"; echo "from-install-sh"' "$fn" >"$tmp/installsh.out" 2>&1
sleep 1
# shellcheck disable=SC2012
ilog="$(ls -1 "$h"/.local/state/dotfiles/logs/install-*.log 2>/dev/null | head -n 1 || true)"
if [ -n "$ilog" ] && grep -Fq 'from-install-sh' "$ilog"; then pass; else
    fail "install.sh: output after start_install_log must reach logs/install-*.log: $(cat "$tmp/installsh.out")"
fi
h="$tmp/installsh-off"
write_cfg "$h" true false
DOT_LOG=off HOME="$h" sh -c '. "$0"; echo "quiet"' "$fn" >/dev/null 2>&1
if [ -d "$h/.local/state/dotfiles/logs" ]; then fail "install.sh: DOT_LOG=off must write no log"; else pass; fi

# --- 3. PowerShell lib --------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    h="$tmp/ps"
    write_cfg "$h" false true
    # shellcheck disable=SC2016 # PowerShell code
    out="$(LIB="$repo_root/scripts/lib/ps-installer-output.ps1" CFG="$h/.config/chezmoi/chezmoi.toml" ROOT="$h" pwsh -NoProfile -Command '
        $ErrorActionPreference = "Stop"
        Set-StrictMode -Version Latest
        . $env:LIB
        $r = @()
        Remove-Item Env:\DOT_LOG -ErrorAction SilentlyContinue
        $r += "cfg-log=" + (Resolve-DotFlag -Name DOT_LOG -Key log -Default $true -ConfigPath $env:CFG)
        $r += "cfg-verbose=" + (Resolve-DotFlag -Name DOT_VERBOSE -Key verbose -Default $false -ConfigPath $env:CFG)
        $r += "no-cfg=" + (Resolve-DotFlag -Name DOT_LOG -Key log -Default $true -ConfigPath (Join-Path $env:ROOT "missing.toml"))
        $env:DOT_LOG = "on"
        $r += "env-on=" + (Resolve-DotFlag -Name DOT_LOG -Key log -Default $false -ConfigPath $env:CFG)
        Remove-Item Env:\DOT_LOG
        $r += "off=[" + (Open-DotLog -Name off -Enabled $false -Root $env:ROOT) + "]"
        $path = Open-DotLog -Name run -Enabled $true -Root $env:ROOT
        Write-Host "from-the-ps-run"
        Close-DotLog
        $r += "has-line=" + [bool](Select-String -LiteralPath $path -SimpleMatch "from-the-ps-run" -Quiet)
        $r += "named=" + ((Split-Path -Leaf $path) -like "run-*.log")
        $r -join " "
    ' 2>&1 | tr -d '\r')"
    for want in cfg-log=False cfg-verbose=True no-cfg=True env-on=True 'off=[]' has-line=True named=True; do
        case "$out" in *"$want"*) ;; *) fail "pwsh: expected $want - got: $out" ;; esac
    done
    pass
else
    skip "pwsh not available to execute the PowerShell logging helpers"
fi

# --- 4. wiring ------------------------------------------------------------------------------
require "$repo_root/run_onchange_install_packages.ps1.tmpl" "Open-DotLog -Name 'dot-up'"
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'Close-DotLog'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" "Enable-DotVerbose -Enabled (Resolve-DotFlag -Name 'DOT_VERBOSE' -Key 'verbose'"
require "$repo_root/run_onchange_install_packages.sh.tmpl" '{{ include "scripts/lib/logging.sh" }}'
require "$repo_root/run_onchange_install_packages.sh.tmpl" 'dot_log_open dot-up'
require "$repo_root/run_onchange_install_packages.sh.tmpl" 'dot_log_verbose'
# shellcheck disable=SC2016 # a PowerShell literal
require "$repo_root/install.ps1" 'Start-Transcript -LiteralPath $InstallLogPath'
require "$repo_root/install.ps1" 'Stop-Transcript'
# install.ps1's native installers go through Out-Host - a transcript records only what PowerShell writes.
if grep -nE '^\s*(winget|choco) install ' "$repo_root/install.ps1" | grep -v 'Out-Host'; then
    fail "install.ps1: every winget/choco install line must pipe through Out-Host to reach the transcript"
fi
for t in run_onchange_install_packages.ps1.tmpl run_onchange_install_packages.sh.tmpl \
    run_onchange_generate_identities.ps1.tmpl run_onchange_generate_identities.sh.tmpl; do
    forbid "$repo_root/$t" '.logging.'
    forbid "$repo_root/$t" 'hasKey . "logging"'
done
pass

finish
