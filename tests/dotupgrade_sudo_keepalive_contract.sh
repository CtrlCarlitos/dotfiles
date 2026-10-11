#!/usr/bin/env bash
set -euo pipefail

# dot_sudo_keepalive (scripts/lib/agent-skills.sh): keep sudo's cached credential alive for the
# rest of a `dot upgrade`. A WSL `dot upgrade --yes` (2026-10-11) asked for the password twice:
# once for apt at the start, and again 18 minutes later for the npm global upgrade, after
# Maestro's 300 MB download had outlasted sudo's 15-minute timestamp. The installer has had a
# prime-once-then-refresh loop since #114; `dot upgrade` had none. EXECUTED against a fake sudo.
#   - refreshes with `sudo -n true` every DOT_SUDO_KEEPALIVE_SECONDS (30 by default) in the
#     background, both streams closed (an open pipe would hold a `$(...)` caller forever)
#   - ends by itself once the script that started it is gone
#   - started once, by dotupgrade.sh, right after its first sudo succeeded (the apt update)
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
lib="$repo_root/scripts/lib/agent-skills.sh"
du="$repo_root/scripts/dotupgrade.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/sudo" <<'EOF2'
#!/bin/sh
printf '%s\n' "$*" >>"${SUDO_LOG:?}"
exit 0
EOF2
chmod +x "$tmp/bin/sudo"
: >"$tmp/sudo.log"

# A script that starts the keep-alive and lives 2.5 s; the loop runs every 1 s.
PATH="$tmp/bin:$PATH" SUDO_LOG="$tmp/sudo.log" DOT_SUDO_KEEPALIVE_SECONDS=1 \
    bash -c 'set -u; . "$1"; dot_sudo_keepalive; sleep 2.5; echo "KEEPALIVE_PID=$DOT_SUDO_KEEPALIVE_PID"' _ "$lib" >"$tmp/out" 2>"$tmp/err" || fail "dot_sudo_keepalive must not fail the caller (stderr: $(/bin/cat "$tmp/err"))"
[ ! -s "$tmp/err" ] || fail "the keep-alive must print nothing (stderr: $(/bin/cat "$tmp/err"))"
n="$(grep -cx -- '-n true' "$tmp/sudo.log" || true)"
[ "$n" -ge 2 ] || fail "the credential must be refreshed with \`sudo -n true\` every DOT_SUDO_KEEPALIVE_SECONDS (saw $n refresh(es) in 2.5 s at 1 s)"
pid="$(sed -n 's/^KEEPALIVE_PID=//p' "$tmp/out")"
[ -n "$pid" ] || fail "DOT_SUDO_KEEPALIVE_PID must name the loop (output: $(/bin/cat "$tmp/out"))"
# the caller is gone: the loop must end within one interval
sleep 2.5
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    fail "the keep-alive must end once the script that started it is gone (pid $pid still alive)"
fi
pass

# Started once in dotupgrade.sh, after the first sudo (apt-get update) succeeded.
awk '/if sudo apt-get "\$\{apt_q\[@\]\}" update; then/ {a=NR} /dot_sudo_keepalive/ {if (!b) b=NR} END {exit !(a && b && a<b)}' "$du" ||
    fail "dotupgrade.sh: dot_sudo_keepalive must start right after the apt update's sudo succeeded"
[ "$(grep -c 'dot_sudo_keepalive' "$du")" -le 2 ] || fail "dotupgrade.sh: the keep-alive is started once"

finish
