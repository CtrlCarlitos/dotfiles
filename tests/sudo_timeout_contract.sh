#!/usr/bin/env bash
set -euo pipefail

# A privileged command under net_timeout goes through the real sudo binary,
# never through the dot_sudo function.
#
# Since #324 $SUDO (and its copy $npm_sudo) names a shell FUNCTION, dot_sudo,
# so that the password prompt happens on the first privileged command instead
# of at the top. coreutils `timeout` exec()s its command, and a function is not
# a file: every `net_timeout 300 $npm_sudo <cmd>` call site died on the spot -
#   timeout: failed to run command 'dot_sudo': No such file or directory
#   ⚠ Playwright system deps install failed or timed out - continuing
# on a WSL `dot up` (2026-10-09, system npm at /usr, so npm_sudo was set).
# The same shape sat in the first npm -g install and the agent-browser install.
#
# The contract: sudo_net_timeout / sudo_net_timeout_tty <sudo|""> <secs> <cmd...>
# prime through dot_sudo_prime (same once-per-run prompt), then run the real
# sudo under the timeout - exactly what `net_timeout 300 sudo <cmd>` did before.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"
[ -f "$tmpl" ] || { fail "missing $tmpl"; finish; }

# 1. Static: no sudo variable in command position under a timeout wrapper.
code_only() { grep -vE '^[[:space:]]*#' "$1"; }
hits="$(code_only "$tmpl" | grep -nE 'net_timeout(_tty)?[[:space:]]+[0-9]+[[:space:]]+\$\{?(SUDO|npm_sudo|sudo_cmd)' || true)"
if [ -n "$hits" ]; then
    fail "a sudo variable (a function) is run under timeout: $(printf '%s' "$hits" | head -3)"
else
    pass
fi
require "$tmpl" 'sudo_net_timeout() {'
require "$tmpl" 'sudo_net_timeout_tty() {'

# 2. Executed, with the real net_timeout and a stub sudo BINARY on PATH: timeout
#    must be able to exec what it is handed.
command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed (render needed for the executed check)'
command -v timeout >/dev/null 2>&1 || skip 'coreutils timeout not installed'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
render_to "$tmp/installer.sh" sh '{"core":true}'

awk '/^_DOT_SUDO_PRIMED=""/{f=1} f{print} f && /^# sudo-helpers: end/{exit}' "$tmp/installer.sh" >"$tmp/fn.sh"
grep -q 'sudo_net_timeout_tty() {' "$tmp/fn.sh" || { fail "dot_sudo and the sudo_net_timeout helpers were not found together in the rendered installer (the '# sudo-helpers: end' marker must follow them)"; finish; }

mkdir -p "$tmp/bin"
cat >"$tmp/bin/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >>"${SUDO_CALLS:?}"
[ "${1:-}" = -v ] && exit 0
exec "$@"
EOF
chmod +x "$tmp/bin/sudo"

cat >"$tmp/drive.sh" <<'DRIVER'
set -uo pipefail
. "$1"   # scripts/lib/agent-skills.sh: the real net_timeout / net_timeout_tty
. "$2"   # dot_sudo, dot_sudo_prime, sudo_net_timeout*
trap 'kill $(jobs -p) 2>/dev/null' EXIT   # the keep-alive loops this shell started
: >"$SUDO_CALLS"
# No $(...) around these: the primed flag lives in this shell and must be seen
# by the next call. Output goes to a file instead.
sudo_net_timeout_tty dot_sudo 5 printf 'ran:%s' one >"$OUT_FILE"; rc=$?
printf 'tty_rc=%s tty_out=%s primes=%s\n' "$rc" "$(cat "$OUT_FILE")" "$(grep -c '^sudo -v$' "$SUDO_CALLS")"
sudo_net_timeout dot_sudo 5 printf 'ran:%s' two >"$OUT_FILE"; rc=$?
printf 'plain_rc=%s plain_out=%s primes=%s via_sudo=%s\n' "$rc" "$(cat "$OUT_FILE")" "$(grep -c '^sudo -v$' "$SUDO_CALLS")" "$(grep -c '^sudo printf' "$SUDO_CALLS")"
: >"$SUDO_CALLS"
sudo_net_timeout "" 5 printf 'ran:%s' three >"$OUT_FILE"; rc=$?
printf 'root_rc=%s root_out=%s sudo_calls=%s\n' "$rc" "$(cat "$OUT_FILE")" "$(grep -c . "$SUDO_CALLS" || true)"
# Last, in a fresh (unprimed) subshell: the first privileged command inside a
# command substitution. The keep-alive loop dot_sudo_prime starts must not hold
# the substitution's pipe open (the driver runs under `timeout`, so a
# regression is a failure, not a hang).
out="$(_DOT_SUDO_PRIMED=""; dot_sudo printf 'ran:%s' zero)"
printf 'subst_rc=%s subst_out=%s\n' "$?" "$out"
DRIVER
out="$(SUDO_CALLS="$tmp/calls.txt" OUT_FILE="$tmp/out.txt" PATH="$tmp/bin:$PATH" timeout -k 2 20 bash "$tmp/drive.sh" "$repo_root/scripts/lib/agent-skills.sh" "$tmp/fn.sh" 2>&1)" || true

grep -Fxq 'subst_rc=0 subst_out=ran:zero' <<<"$out" || fail "a first dot_sudo inside \$(...) must return: the keep-alive loop held the pipe open (driver output: $out)"
pass
grep -Fxq 'tty_rc=0 tty_out=ran:one primes=1' <<<"$out" || fail "sudo_net_timeout_tty must prime once and run the command through the sudo binary under timeout: $out"
pass
grep -Fxq 'plain_rc=0 plain_out=ran:two primes=1 via_sudo=2' <<<"$out" || fail "sudo_net_timeout must reuse the prime and still go through sudo: $out"
pass
grep -Fxq 'root_rc=0 root_out=ran:three sudo_calls=0' <<<"$out" || fail "an empty sudo argument (root, user-managed npm) must run the command bare, no sudo at all: $out"
pass

finish
