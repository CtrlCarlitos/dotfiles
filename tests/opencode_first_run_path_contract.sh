#!/usr/bin/env bash
set -euo pipefail

# install_opencode_cli leaves the native OpenCode binary on the installer's own PATH -
# EXECUTED against the rendered installer.
#
# OpenCode's native installer writes ~/.opencode/bin/opencode and adds that directory to the
# shell rc files only. On a fresh Ubuntu 26.04 checkpoint (issue #431 Run 8) `command -v opencode`
# therefore stayed false for the rest of the run: no Superpowers for OpenCode, no MCP
# registrations, and the agent-guardrails setup reported "opencode: not detected" - all of it
# arrived only with the next `dot up` (Run 9). The contract:
#   1. fresh: after the native installer runs, `opencode` resolves in the same shell, to the
#      native binary, and the Superpowers step that follows sees it;
#   2. already installed in ~/.opencode/bin but not on PATH: no reinstall, and it resolves;
#   3. a leftover npm shim earlier on PATH: the native directory goes in front of it;
#   4. the installer fails and leaves nothing: no crash under set -e, nothing resolves.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

for d in /usr/bin /bin; do
    [ ! -e "$d/opencode" ] || skip "$d/opencode exists - the system PATH this test uses would resolve it"
done
command -v jq >/dev/null 2>&1 || skip 'jq not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_to "$tmp/installer.sh" sh '{"opencode_cli": true}'
for fn in opencode_path_add install_opencode_cli; do
    awk -v f="$fn" '$0 ~ "^" f "\\(\\) \\{" {on=1} on {print} on && /^\}$/ {exit}' "$tmp/installer.sh" >>"$tmp/fns.sh"
    grep -q "^$fn() {" "$tmp/fns.sh" || fail "$fn() not found in the rendered installer"
done

# The fake native binary, as OpenCode's installer would lay it down.
fake_opencode() { # $1 = path
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\necho 1.19.4\n' >"$1"
    chmod +x "$1"
}
export -f fake_opencode

{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. "%s"\n' "$repo_root/scripts/lib/agent-skills.sh" # info/warn
    cat <<'STUBS'
ensure_jq() { :; }
npm() { :; }
# The native installer: lays the binary down unless told to fail.
net_timeout() {
    echo installer >>"$CALLS"
    [ "${INSTALL_FAILS:-0}" = 1 ] && return 1
    fake_opencode "$HOME/.opencode/bin/opencode"
}
STUBS
    cat "$tmp/fns.sh"
    printf '%s\n' 'install_opencode_cli' 'echo "resolved=$(command -v opencode || true)"'
} >"$tmp/harness.sh"

run() { # $1 = HOME, $2 = extra PATH prefix ("" = none); prints the harness output
    : >"$tmp/calls"
    HOME="$1" CALLS="$tmp/calls" PATH="${2:+$2:}/usr/bin:/bin" bash "$tmp/harness.sh" 2>&1
}

# 1. Fresh.
h1="$tmp/h1"; mkdir -p "$h1"
out="$(run "$h1" "")" || fail "fresh: the installer function failed (got: $out)"
case "$out" in *"resolved=$h1/.opencode/bin/opencode"*) pass ;; *) fail "fresh: opencode must resolve to the native binary in the same run (got: $out)" ;; esac
grep -q obra/superpowers "$h1/.config/opencode/opencode.json" 2>/dev/null && pass ||
    fail "fresh: Superpowers for OpenCode must be configured in the same run"

# 2. Installed, not on PATH: no reinstall.
h2="$tmp/h2"; fake_opencode "$h2/.opencode/bin/opencode"
out="$(run "$h2" "")"
case "$out" in *"resolved=$h2/.opencode/bin/opencode"*) pass ;; *) fail "installed: opencode must resolve (got: $out)" ;; esac
[ ! -s "$tmp/calls" ] && pass || fail "installed: the native installer must not run again (calls: $(cat "$tmp/calls"))"

# 3. A shim earlier on PATH loses to the native binary.
h3="$tmp/h3"; fake_opencode "$h3/.opencode/bin/opencode"; fake_opencode "$tmp/shim/opencode"
out="$(run "$h3" "$tmp/shim")"
case "$out" in *"resolved=$h3/.opencode/bin/opencode"*) pass ;; *) fail "shim: the native binary must come first (got: $out)" ;; esac

# 4. The installer fails.
h4="$tmp/h4"; mkdir -p "$h4"
out="$(INSTALL_FAILS=1 run "$h4" "")" || fail "failed install: must not end the run (got: $out)"
case "$out" in *'resolved='$'\n'* | *'resolved=') pass ;; *) fail "failed install: nothing may resolve (got: $out)" ;; esac

finish
