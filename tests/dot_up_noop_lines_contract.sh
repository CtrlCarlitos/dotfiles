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

# 1b. apt_index_age_hours, executed: the newest release file's age; nothing -> exit 1
mkdir -p "$tmp/lists"
touch -d '3 hours ago' "$tmp/lists/archive.ubuntu.com_ubuntu_dists_noble_InRelease"
touch -d '30 hours ago' "$tmp/lists/archive.ubuntu.com_ubuntu_dists_noble-updates_InRelease"
touch -d '1 hour ago' "$tmp/lists/lock"
got="$(APT_LISTS_DIR="$tmp/lists" run_lib apt_index_age_hours)"
[ "$got" = 3 ] || fail "apt_index_age_hours: newest release file is 3 h old (the lock file does not count), got '$got'"
mkdir -p "$tmp/nolists"
if APT_LISTS_DIR="$tmp/nolists" run_lib apt_index_age_hours >/dev/null; then fail "apt_index_age_hours: no release file must exit 1"; else pass; fi
# the installer skips its refresh while the index is younger than a day; DOT_APT_REFRESH=1 forces it
require "$tmpl" 'apt_age="$(apt_index_age_hours || true)"'
require "$tmpl" 'if [ "${DOT_APT_REFRESH:-}" != 1 ] && [ -n "$apt_age" ] && [ "$apt_age" -lt 24 ]; then'
require "$tmpl" 'info "apt index is ${apt_age}h old - refresh skipped (DOT_APT_REFRESH=1 forces it; dot upgrade always refreshes)"'
require "$tmpl" '$SUDO apt update -y || true'

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

# 4b. the agent toolkit names its three steps (19 s on a WSL dot up, 2026-10-14, unattributed)
require "$tmpl" "dot_timing_mark 'agent toolkit: playwright'"
require "$tmpl" "dot_timing_mark 'agent toolkit: agent-browser install'"
require "$tmpl" "dot_timing_mark 'agent toolkit: doctor'"
require "$tmpl" 'info "agent-browser: downloaded $ab_chrome"'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" '"agent-browser: downloaded $($chrome.Matches[0].Value)"'
# the VS Code settings line names what it changed, in both twins
require "$tmpl" 'VS Code settings: %d change(s) - %s; backup at .bak (%s)" % (len(changed), ", ".join(changed), path)'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'VS Code settings: $vsChanged change(s) - $($vsChangedKeys -join '"'"', '"'"') (backup: $vscodeSettings.bak)'

# 5. the updater: NPM sub-marks, the Antigravity gate in both twins
require "$ai_sh" "dot_timing_mark 'NPM: codex'"
# the codex check's two npm calls are marked apart (6-8 s live against ~2.5 s isolated, 2026-10-13)
require "$ai_sh" 'npm_global_current "$pkg" '"'"'NPM: codex'"'"
require "$ai_sh" 'dot_timing_mark "$label: npm ls"'
require "$ai_sh" 'dot_timing_mark "$label: npm view"'
require "$ai_sh" 'dot_timing_mark "NPM: $npm_tool"'
require "$ai_sh" 'Superpowers (Antigravity) is current ($agy_have)'
require "$ai_ps1" 'Superpowers (Antigravity) is current ($agyHave)'
require "$repo_root/scripts/lib/ps-skills.ps1" 'function Get-CodexSuperpowersCachedVersion'

finish
