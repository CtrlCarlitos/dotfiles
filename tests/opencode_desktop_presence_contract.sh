#!/usr/bin/env bash
set -euo pipefail

# install_opencode_desktop recognises the OpenCode Desktop .deb it installed - EXECUTED against
# the rendered installer.
#
# The .deb's package is named `opencode` (not opencode-desktop) and its binary is
# /opt/OpenCode/ai.opencode.desktop, off PATH. The guard asked for neither, so every `dot up`
# downloaded 117.5 MB and apt answered "opencode is already the newest version (1.19.4)"
# (issue #431 Run 11). The contract (Linux):
#   1. the installed binary is there: "already installed", no download;
#   2. nothing installed: the .deb is downloaded and installed.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

[ "$(uname -s)" = Linux ] || skip 'the .deb arm runs on Linux only'
command -v opencode-desktop >/dev/null 2>&1 && skip 'opencode-desktop is on PATH - the guard would match through it'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_to "$tmp/installer.sh" sh '{"opencode_desktop": true}'
awk '/^install_opencode_desktop\(\) \{/ {f=1} f {print} f && /^\}$/ {exit}' "$tmp/installer.sh" >"$tmp/fn.sh"
grep -q '^install_opencode_desktop() {' "$tmp/fn.sh" || fail "install_opencode_desktop() not found in the rendered installer"

{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. "%s"\n' "$repo_root/scripts/lib/agent-skills.sh" # info/warn
    cat <<'STUBS'
PKG_MANAGER=apt
SUDO=""
dpkg() { return 1; }           # no package named opencode-desktop, as on the VM
net_timeout() { echo download >>"$CALLS"; return 1; }
STUBS
    cat "$tmp/fn.sh"
    printf '%s\n' 'install_opencode_desktop'
} >"$tmp/harness.sh"

run() { # $1 = OPENCODE_DESKTOP_BIN; prints the harness output
    : >"$tmp/calls"
    WORK="$tmp" CALLS="$tmp/calls" OPENCODE_DESKTOP_BIN="$1" bash "$tmp/harness.sh" 2>&1
}

# 1. Installed: the .deb's binary is there.
printf '#!/bin/sh\n' >"$tmp/ai.opencode.desktop"
chmod +x "$tmp/ai.opencode.desktop"
out="$(run "$tmp/ai.opencode.desktop")" || fail "installed: the function failed (got: $out)"
[ ! -s "$tmp/calls" ] && pass || fail "installed: must not download the .deb again (got: $out)"
case "$out" in *'OpenCode Desktop already installed'*) pass ;; *) fail "installed: must say so (got: $out)" ;; esac

# 2. Not installed: the download runs.
out="$(run "$tmp/missing")" || fail "missing: the function failed (got: $out)"
grep -qx download "$tmp/calls" && pass || fail "missing: must download the .deb (got: $out)"

finish
