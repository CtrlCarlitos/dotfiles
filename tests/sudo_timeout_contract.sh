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

# 3. Static: $SUDO/$npm_sudo (the function names) must never be spliced directly
#    into a string handed to a NEW `bash -c` - that shell has no function table,
#    so the exact same class of bug resurfaces one level up from net_timeout:
#    the act installer composed `| ${SUDO} bash -s -- ...` into a variable, then
#    ran `bash -c "$act_script"`, and died with the identical signature -
#    "bash: line 1: dot_sudo: command not found", curl's pipe reader gone before
#    its first byte (2026-10-23 fresh Ubuntu VM). The fix primes dot_sudo_prime
#    in the CURRENT shell, then splices the literal `sudo` binary instead.
hits="$(code_only "$tmpl" | grep -nE '="[^"]*\$\{(SUDO|npm_sudo)\}[^"]*"$' || true)"
if [ -n "$hits" ]; then
    fail "a sudo function name (\$SUDO/\$npm_sudo) is spliced into a string for bash -c: $(printf '%s' "$hits" | head -3)"
else
    pass
fi

# 4. Static: the npm sudo decision must run AFTER the pkg_manager dispatch, not
#    before - install_apt/install_brew are what install Node in the first place
#    (install_node). Computing the decision earlier found no npm at all on a
#    machine with none preinstalled (`command -v npm` empty), so npm_sudo
#    silently ended up "" - no warning either, since that warning is gated on a
#    non-empty NPM_BIN - and every npm -g site below (agent-device,
#    markdownlint-cli2, Playwright deps, agent-browser, Codex) ran unprivileged
#    against the root-owned /usr/lib/node_modules and failed EACCES, four real
#    installs lost silently in one run (2026-10-23 fresh Ubuntu VM).
dispatch_line="$(grep -n 'apt)  install_apt ;;' "$tmpl" | head -1 | cut -d: -f1)"
decision_line="$(grep -nE '^[[:space:]]*npm_sudo="\$SUDO"[[:space:]]*$' "$tmpl" | head -1 | cut -d: -f1)"
if [ -z "$dispatch_line" ] || [ -z "$decision_line" ]; then
    fail "could not locate the pkg_manager dispatch or the npm sudo decision to order-check"
elif [ "$decision_line" -lt "$dispatch_line" ]; then
    fail "the npm sudo decision (line $decision_line) runs before the pkg_manager dispatch (line $dispatch_line) - Node/npm is not installed yet"
else
    pass
fi

# 5. Static: npm_upgrade_once must not read the global npm_sudo decision at all.
#    Every call site reaches it from INSIDE the pkg_manager dispatch (install_node's
#    only callers are install_apt itself and two apt-gated callers) - i.e. before
#    main() ever reaches the npm_sudo="$SUDO" line check #4 validates, regardless
#    of ordering further down the file. Check #4 above only verifies that line's
#    position relative to the dispatch; it does not see that something INSIDE the
#    dispatch reads the decision before it exists. Under `set -u` this killed
#    every `dot up`/install that reached Node on an apt machine - fresh or not -
#    with "npm_sudo: unbound variable" (2026-10-23 fresh Ubuntu VM, found
#    validating #438, which introduced this - the exact regression #4's own test
#    was meant to catch, from the opposite direction).
hits="$(code_only "$tmpl" | awk '/^npm_upgrade_once\(\) \{/{f=1} f{print} f && /^}/{exit}' | grep -n '\$npm_sudo' || true)"
if [ -n "$hits" ]; then
    fail "npm_upgrade_once reads the global \$npm_sudo, which is unset at every one of its call sites: $hits"
else
    pass
fi

# 6. Executed: with the global npm_sudo decision deliberately left UNSET (as it
#    always is at every real call site) and a user-managed npm (nvm-shaped: not
#    under /usr) on PATH, npm_upgrade_once must run to completion under `set -u`
#    without sudo - the crash from #5, and the user-managed-npm safety #438's own
#    fix (main()'s npm_sudo="$SUDO" / drop-for-non-/usr) was meant to preserve.
command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed (render needed for the executed check)'
tmp2="$(mktemp -d)"
trap 'rm -rf "$tmp2"' EXIT
render_to "$tmp2/installer.sh" sh '{"core":true}'
awk '/^npm_upgrade_once\(\) \{/{f=1} f{print} f && /^}/{exit}' "$tmp2/installer.sh" >"$tmp2/fn.sh"
grep -q 'npm_upgrade_once() {' "$tmp2/fn.sh" || { fail "npm_upgrade_once not found in the rendered installer"; finish; }

mkdir -p "$tmp2/userbin"
cat >"$tmp2/userbin/npm" <<'EOF'
#!/bin/sh
case "$1" in
    -v) echo 1.0.0 ;;
    view) echo 2.0.0 ;;
    install) echo "ran" >>"${NPM_LOG:?}" ;;
esac
EOF
chmod +x "$tmp2/userbin/npm"
cat >"$tmp2/stub_sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >>"${SUDO_LOG:?}"
"$@"
EOF
chmod +x "$tmp2/stub_sudo"

: >"$tmp2/npm.log"; : >"$tmp2/sudo.log"
out="$(SUDO="$tmp2/stub_sudo" NPM_LOG="$tmp2/npm.log" SUDO_LOG="$tmp2/sudo.log" PATH="$tmp2/userbin:/usr/bin:/bin" \
    bash -c 'set -euo pipefail; info() { :; }; . "$1"; npm_upgrade_once' _ "$tmp2/fn.sh" 2>&1)" || fail "npm_upgrade_once crashed with npm_sudo unset and a user-managed npm on PATH: $out"
pass
grep -Fxq 'ran' "$tmp2/npm.log" 2>/dev/null || fail "npm_upgrade_once with npm_sudo unset did not run npm install at all: $out"
pass
[ -s "$tmp2/sudo.log" ] && fail "npm_upgrade_once sudo'd a user-managed (non-/usr) npm: $(cat "$tmp2/sudo.log")"
pass

finish
