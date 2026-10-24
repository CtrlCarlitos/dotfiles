#!/usr/bin/env bash
set -euo pipefail

# install_playwright_chromium runs `sudo npx playwright install-deps` under apt_resume_stopped -
# EXECUTED against the rendered installer.
#
# Same sudo use_pty race as dot upgrade's apt sweep (issue #431 Run 7): a clean Ubuntu 26.04
# checkpoint (Run 8) installed and configured every package, then sat until the 300 s budget
# killed it ("sudo timed out after 300s - killed", no End-Date in /var/log/apt/history.log).
# The contract:
#   1. the watcher starts before install-deps and is stopped once it returns (quiet and verbose);
#   2. a watcher that already exited does not end the run under `set -e` - the browser download
#      still follows;
#   3. off apt (brew) no watcher starts.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_to "$tmp/installer.sh" sh '{"agent_toolkit": true}'
awk '/^install_playwright_chromium\(\) \{/ {f=1} f {print} f && /^\}$/ {exit}' "$tmp/installer.sh" >"$tmp/fn.sh"
grep -q 'install-deps chromium' "$tmp/fn.sh" ||
    fail "install_playwright_chromium() not found in the rendered installer, or it lost install-deps"

{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. "%s"\n' "$repo_root/scripts/lib/agent-skills.sh" # info/warn
    cat <<'STUBS'
log() { printf '%s\n' "$1" >>"$CALLS"; }
playwright_chromium_installed() { return 1; }
# A real background process stands in for the watcher, so "stopped" is observable.
apt_resume_stopped() {
    log watcher-start
    if [ "${WATCHER_GONE:-0}" = 1 ]; then echo 999999; return; fi
    sleep 300 </dev/null >/dev/null 2>&1 &
    echo $! >"$WATCHER_PID"
    echo $!
}
sudo_net_timeout_tty() {
    if [ -s "$WATCHER_PID" ] && kill -0 "$(cat "$WATCHER_PID")" 2>/dev/null; then log install-deps-watched; else log install-deps; fi
    return 0
}
net_timeout() { log download; return 0; }
STUBS
    cat "$tmp/fn.sh"
    printf '%s\n' 'install_playwright_chromium' 'log end'
} >"$tmp/harness.sh"

run() { # env from the caller; prints the call log
    : >"$tmp/calls"; : >"$tmp/watcher.pid"
    CALLS="$tmp/calls" WATCHER_PID="$tmp/watcher.pid" NPM_BIN=npm NPX_BIN=npx npm_sudo=sudo \
        timeout 30 bash "$tmp/harness.sh" >"$tmp/out" 2>&1 || echo "rc=$?" >>"$tmp/calls"
    tr '\n' ' ' <"$tmp/calls"
}
watcher_stopped() {
    local pid; pid="$(cat "$tmp/watcher.pid")"
    [ -n "$pid" ] || return 1
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
    kill "$pid" 2>/dev/null; return 1
}

# 1. Quiet and verbose: watcher first, install-deps while it runs, watcher gone afterwards.
for v in 0 1; do
    got="$(PKG_MANAGER=apt DOT_APT_VERBOSE=$v run)"
    case "$got" in 'watcher-start install-deps-watched download end ') pass ;;
        *) fail "DOT_APT_VERBOSE=$v: install-deps must run under the watcher (calls: $got; out: $(cat "$tmp/out"))" ;; esac
    watcher_stopped || fail "DOT_APT_VERBOSE=$v: the watcher must be stopped once install-deps returns"
done

# 2. A watcher that already exited: kill fails, the run goes on.
got="$(PKG_MANAGER=apt WATCHER_GONE=1 run)"
case "$got" in *'download end '*) pass ;; *) fail "a vanished watcher must not end the run under set -e (calls: $got)" ;; esac

# 3. brew: no install-deps, no watcher.
got="$(PKG_MANAGER=brew run)"
case "$got" in 'download end ') pass ;; *) fail "brew: no watcher and no install-deps expected (calls: $got)" ;; esac

finish
