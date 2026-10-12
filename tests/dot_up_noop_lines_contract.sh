#!/usr/bin/env bash
set -euo pipefail

# `dot up` lines that read the same whether or not anything happened (WSL, 2026-10-12): "Installing
# core packages...", "Installing OpenSSH Server prerequisites...", "Configuring Superpowers for
# OpenCode..." and "Registering MCP in agy global mcp_config.json (...)". Now each says what it did:
#   1. apt_missing_packages (scripts/lib/agent-skills.sh): the names dpkg does not report installed;
#      the installer installs only then - `apt install -y` of a present set would UPGRADE it, which
#      dot up never does - and otherwise says "all present" / "already installed"
#   2. the OpenCode plugin entry: "already configured" when opencode.json carries it
#   3. the agy MCP merge prints changed/unchanged and the line says which
# Plus the updater's NPM sub-marks (two WSL runs booked "NPM packages 13s" against ~4 s in
# isolation) and the Antigravity gate's wiring (executed in superpowers_refresh_contract.sh).
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
lib="$repo_root/scripts/lib/agent-skills.sh"
tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"
ai_sh="$repo_root/scripts/update_ai_tools.sh"
ai_ps1="$repo_root/scripts/update_ai_tools.ps1"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
# dpkg-query: $INSTALLED names are "install ok installed", the rest unknown (exit 1, like dpkg)
cat >"$tmp/bin/dpkg-query" <<'STUB'
#!/bin/sh
name="$3"
for n in ${INSTALLED:-}; do [ "$n" = "$name" ] && { printf 'install ok installed'; exit 0; }; done
exit 1
STUB
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/opencode"
chmod +x "$tmp/bin"/*

# 1. apt_missing_packages, executed
run_lib() { PATH="$tmp/bin:/usr/bin:/bin" bash -c '. "$1"; shift; "$@"' _ "$lib" "$@" 2>&1; }
got="$(INSTALLED="git curl" run_lib apt_missing_packages git curl)"
[ -z "$got" ] || fail "all present: expected nothing, got '$got'"
got="$(INSTALLED="git" run_lib apt_missing_packages git curl jq)"
[ "$got" = "curl jq" ] || fail "two missing: expected 'curl jq', got '$got'"
got="$(PATH="/nonexistent" /bin/bash -c '. "$1"; apt_missing_packages git curl' _ "$lib" 2>&1)"
[ "$got" = "git curl" ] || fail "no dpkg-query: every name reads as missing (the install runs as before), got '$got'"
pass

# 2. the installer: core and OpenSSH install only when something is missing, and say so otherwise
require "$tmpl" 'core_missing="$(apt_missing_packages '
require "$tmpl" 'info "Core packages: all present."'
require "$tmpl" 'info "Installing core packages (missing: $core_missing)..."'
[ "$(grep -c 'info "OpenSSH Server prerequisites already installed."' "$tmpl")" = 2 ] || fail "both OpenSSH prerequisite sites must say when it is already installed"
[ "$(grep -c 'apt_missing_packages openssh-server' "$tmpl")" = 2 ] || fail "both OpenSSH prerequisite sites must ask dpkg first"
forbid "$tmpl" 'info "Installing core packages..."'

# 3. the OpenCode plugin entry, executed from the render: first run configures, second says so
if command -v chezmoi >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    render_to "$tmp/linux.sh" sh '{"opencode": true}'
    awk '$0 == "install_opencode_cli() {" {f=1} f {print} f && /^\}$/ {exit}' "$tmp/linux.sh" >"$tmp/oc-fn.sh"
    grep -q '^install_opencode_cli() {' "$tmp/oc-fn.sh" || fail "render: install_opencode_cli() not found"
    run_oc() { HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin" bash -c 'set -uo pipefail; . "$1"; . "$2"; ensure_jq() { :; }; net_timeout() { shift; "$@"; }; install_opencode_cli' _ "$lib" "$tmp/oc-fn.sh" 2>&1; }
    out="$(run_oc)"
    case "$out" in *'Configuring Superpowers for OpenCode...'*) pass ;; *) fail "first run: must configure (got: $out)" ;; esac
    grep -q 'obra/superpowers' "$tmp/home/.config/opencode/opencode.json" || fail "first run: opencode.json must carry the plugin"
    out="$(run_oc)"
    case "$out" in *'Superpowers for OpenCode already configured (opencode.json).'*) pass ;; *) fail "second run: must say already configured (got: $out)" ;; esac
    case "$out" in *'Configuring Superpowers'*) fail "second run: must not say Configuring again" ;; *) pass ;; esac
    # 4. the agy merge heredoc, executed: changed on the first write, unchanged on the second
    render_to "$tmp/agy.sh" sh '{"agent_toolkit": true, "antigravity_cli": true}'
    sed -n "/python3 - \"\$AGY_GLOBAL_MCP\" \"\$AGY_WANT\" <<'PYEOF'/,/^PYEOF\$/p" "$tmp/agy.sh" | sed '1d;$d' >"$tmp/merge.py"
    [ -s "$tmp/merge.py" ] || fail "render: no agy merge heredoc"
    got="$(python3 -I "$tmp/merge.py" "$tmp/home/mcp_config.json" serena)"
    [ "$got" = changed ] || fail "agy merge, first write: expected 'changed', got '$got'"
    got="$(python3 -I "$tmp/merge.py" "$tmp/home/mcp_config.json" serena)"
    [ "$got" = unchanged ] || fail "agy merge, nothing new: expected 'unchanged', got '$got'"
    require "$tmp/agy.sh" 'info "MCP in agy global mcp_config.json already registered ($AGY_WANT)."'
    require "$tmp/agy.sh" 'info "Registered MCP in agy global mcp_config.json ($AGY_WANT, forceAllToolsEager)."'
    forbid "$tmp/agy.sh" 'info "Registering MCP in agy global mcp_config.json'
    pass
else
    printf 'note: chezmoi or jq not installed - the executed installer checks are skipped\n'
fi

# 5. the updater: NPM sub-marks, the Antigravity gate in both twins
require "$ai_sh" "dot_timing_mark 'NPM: codex'"
require "$ai_sh" 'dot_timing_mark "NPM: $npm_tool"'
require "$ai_sh" 'Superpowers (Antigravity) is current ($agy_have)'
require "$ai_ps1" 'Superpowers (Antigravity) is current ($agyHave)'
require "$repo_root/scripts/lib/ps-skills.ps1" 'function Get-CodexSuperpowersCachedVersion'

finish
