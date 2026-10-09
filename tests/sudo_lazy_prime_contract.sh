#!/usr/bin/env bash
set -euo pipefail

# The installer primes sudo on the FIRST privileged command, never at the top.
#
# It used to run `sudo -v` as the very first thing - before package-manager
# detection, before any group check, before a line of output. So an apply with
# nothing to do still stopped dead on "[sudo] password for ...", and a
# `chezmoi update` that re-ran this script only because its hash changed asked
# for a password in order to then do nothing. Two separate real sessions
# reported it as the first thing `dot up` does.
#
# $SUDO therefore names a FUNCTION (dot_sudo), not the sudo binary. That shape
# has three requirements worth pinning, because each one breaks silently:
#   - no top-level `sudo -v`: the whole point;
#   - the function must exist and still prime exactly once per run, or the
#     "type your password once" property is lost;
#   - SUDO must never be exported or handed to a child shell - a function does
#     not survive that, and the child would run unprivileged or re-prompt.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"
[ -f "$tmpl" ] || { fail "missing $tmpl"; finish; }

# 1. `sudo -v` may appear ONLY inside dot_sudo_prime (dot_sudo and the
#    sudo_net_timeout helpers call it - tests/sudo_timeout_contract.sh). Indentation proves nothing -
#    the original bug was itself indented, inside the `if command -v sudo`
#    block - so this compares the whole-file count against the count inside the
#    function body. Any surplus is a second place that primes.
#
#    Full-line comments are excluded before counting: the template explains
#    this history in prose, and a `sudo -v` inside a comment cannot prime
#    anything. (Contrast tests/installer_url_credentials_contract.sh, which
#    scans comments too - a credential in a comment is still a leak, while a
#    flag in a comment is just a word.)
code_only() { grep -vE '^[[:space:]]*#' "$1"; }
prime_re='(^|[^-[:alnum:]_])sudo -v([^[:alnum:]]|$)'
total_prime="$(code_only "$tmpl" | grep -cE "$prime_re" || true)"
fn_prime="$(awk '/^dot_sudo_prime\(\) \{/{f=1} f{print} f && /^}/{exit}' "$tmpl" \
    | grep -vE '^[[:space:]]*#' | grep -cE "$prime_re" || true)"
if [ "$fn_prime" != 1 ]; then
    fail "dot_sudo_prime must prime exactly once with 'sudo -v' (found $fn_prime in its body)"
elif [ "$total_prime" != "$fn_prime" ]; then
    fail "sudo is primed outside dot_sudo_prime ($total_prime occurrences, $fn_prime inside) - an eager prime is back: $(grep -nE "$prime_re" "$tmpl" | grep -vE ':[[:space:]]*#' | head -3)"
else
    pass
fi

# 2. $SUDO names the function, and the function is defined.
require "$tmpl" 'SUDO="dot_sudo"'
require "$tmpl" 'dot_sudo_prime() {'
require "$tmpl" 'dot_sudo() {'

# 3. SUDO must stay shell-local: no export, no child shell.
hits="$(grep -nE 'export[[:space:]]+SUDO|(bash|sh)[[:space:]]+-c[^\n]*\$SUDO' "$tmpl" || true)"
if [ -n "$hits" ]; then
    fail "SUDO is a function: it cannot be exported or used in a child shell: $(printf '%s' "$hits" | head -2)"
else
    pass
fi

# 4. Executed: prime once, on first use only.
command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed (render needed for the executed check)'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
render_to "$tmp/installer.sh" sh '{"core":true}'

# dot_sudo, dot_sudo_prime and the flag they guard, lifted out of the render
# and run against a stubbed sudo that records its arguments.
awk '/^_DOT_SUDO_PRIMED=""/{f=1} f{print} f && /^# sudo-helpers: end/{exit}' "$tmp/installer.sh" >"$tmp/fn.sh"
[ -s "$tmp/fn.sh" ] || { fail "dot_sudo not found in the rendered installer"; finish; }

cat >"$tmp/drive.sh" <<'DRIVER'
set -uo pipefail
calls="$1"
sudo() { printf 'sudo %s\n' "$*" >>"$calls"; }
. "$2"
: >"$calls"
printf 'before=%s\n' "$(grep -c . "$calls" || true)"
dot_sudo apt install -y probe
printf 'first=%s\n' "$(grep -c '^sudo -v$' "$calls" || true)"
: >"$calls"
dot_sudo tar -xzf probe
printf 'second=%s\n' "$(grep -c '^sudo -v$' "$calls" || true)"
DRIVER
out="$(bash "$tmp/drive.sh" "$tmp/calls.txt" "$tmp/fn.sh")"

grep -Fxq 'before=0' <<<"$out" || fail "sudo was invoked before any privileged command: $out"
pass
grep -Fxq 'first=1' <<<"$out" || fail "the first privileged command must prime sudo exactly once: $out"
pass
grep -Fxq 'second=0' <<<"$out" || fail "a later privileged command must not re-prime (password asked twice): $out"
pass

finish
