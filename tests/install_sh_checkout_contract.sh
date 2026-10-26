#!/usr/bin/env bash
set -euo pipefail

# install.sh clones the source BEFORE the package menu (step 1.3) - install.ps1's
# 2026-10-14 fix, ported after a fresh Ubuntu 26.04 VM (2026-10-23) never showed
# the gum menu: the one-liner downloads install.sh alone, so
# scripts/select-packages.sh was not on disk when the menu step looked for it.
# Executed end to end with stub git/gum/chezmoi - no sudo, apt or network:
#   1. fresh machine: clones main (unauthenticated https) and the menu then runs
#      from the checkout, before chezmoi
#   2. DOTFILES_BRANCH=<b> clones <b> - how a fix is tried before it is merged
#   3. existing clone: fast-forwarded (a rerun used to reuse a stale clone);
#      switched first only when DOTFILES_BRANCH asks for another branch
#   4. a clone that keeps failing stops the install after 3 attempts, before chezmoi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
install_sh="$repo_root/install.sh"

. "$repo_root/tests/lib.sh"

command -v timeout >/dev/null 2>&1 || skip "coreutils timeout not installed"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

for c in curl gpg wget 7zz gum; do
    printf '#!/bin/sh\nexit 0\n' >"$bin/$c"
    chmod +x "$bin/$c"
done
# git: logs every call to events; a clone leaves a checkout whose menu script logs that it ran
cat >"$bin/git" <<'EOF'
#!/bin/sh
echo "git $*" >>"$STUB_DIR/events"
case "$*" in
    clone*)
        [ -z "${FAIL_CLONE:-}" ] || exit 128
        for a; do d="$a"; done
        mkdir -p "$d/.git" "$d/scripts"
        printf '#!/bin/sh\necho menu >>"$STUB_DIR/events"\n' >"$d/scripts/select-packages.sh"
        ;;
    *"rev-parse --abbrev-ref HEAD") echo main ;;
esac
exit 0
EOF
printf '#!/bin/sh\necho "chezmoi $*" >>"$STUB_DIR/events"\n' >"$bin/chezmoi"
chmod +x "$bin/git" "$bin/chezmoi"

run_install() { # env assignments as arguments; fresh HOME unless KEEP_HOME=1 was given
    rc=0
    rm -f "$tmp/events"
    case " $* " in *" KEEP_HOME=1 "*) ;; *) rm -rf "${tmp:?}/home"; mkdir -p "$tmp/home" ;; esac
    # neutral cwd (the repo root would select the --source . branch); stdin not a TTY (no consent prompt)
    (cd "$tmp" && env -u DEVCONTAINER -u REMOTE_CONTAINERS -u DOTFILES_BRANCH HOME="$tmp/home" \
        STUB_DIR="$tmp" CHEZMOI_RETRY_DELAY=0 DOT_LOG=0 PATH="$bin:$PATH" "$@" \
        timeout 120 sh "$install_sh" >"$tmp/out" 2>&1 </dev/null) || rc=$?
}
events() { tr '\n' '|' <"$tmp/events" 2>/dev/null; }
src="$tmp/home/.local/share/chezmoi"

# --- 1. fresh machine: clone main, menu from the checkout, then chezmoi ---------------------------
run_install
[ "$rc" -eq 0 ] || fail "fresh install must succeed (rc $rc): $(tail -3 "$tmp/out")"
[ "$(events)" = "git clone --branch main https://github.com/CtrlCarlitos/dotfiles.git $src|menu|chezmoi init --apply|" ] ||
    fail "fresh install: clone main, then the menu, then one chezmoi init --apply (got: $(events))"
pass

# --- 2. DOTFILES_BRANCH picks the branch ----------------------------------------------------------
run_install DOTFILES_BRANCH=fix/x
case "$(events)" in
    "git clone --branch fix/x https://github.com/CtrlCarlitos/dotfiles.git $src|menu|"*) pass ;;
    *) fail "DOTFILES_BRANCH=fix/x must clone that branch (got: $(events))" ;;
esac

# --- 3. existing clone: fast-forward; switch only when asked --------------------------------------
mkdir -p "$src/.git"
run_install KEEP_HOME=1
[ "$(events)" = "git -C $src pull --ff-only|menu|chezmoi init --apply|" ] ||
    fail "existing clone: pull --ff-only, no clone, no branch switch (got: $(events))"
run_install KEEP_HOME=1 DOTFILES_BRANCH=fix/x
[ "$(events)" = "git -C $src rev-parse --abbrev-ref HEAD|git -C $src fetch origin fix/x|git -C $src switch fix/x|git -C $src pull --ff-only|menu|chezmoi init --apply|" ] ||
    fail "existing clone + DOTFILES_BRANCH: fetch, switch, then pull (got: $(events))"
pass

# --- 4. a failing clone stops after 3 attempts, before chezmoi ------------------------------------
run_install FAIL_CLONE=1
[ "$rc" -ne 0 ] || fail "a clone that never succeeds must fail the install"
[ "$(grep -c '^git clone' "$tmp/events")" -eq 3 ] || fail "expected exactly 3 clone attempts (got: $(events))"
grep -q '^chezmoi' "$tmp/events" && fail "chezmoi must not run without a checkout (got: $(events))"
require "$tmp/out" 'after 3 attempts'

finish
