#!/usr/bin/env bash
set -euo pipefail

# install_antigravity_cli puts back the ~/.zshrc chezmoi wrote - EXECUTED against the rendered
# installer.
#
# agy's install.sh appends "# Added by Antigravity CLI installer" plus a PATH export to ~/.bashrc,
# ~/.zshrc and ~/.profile. ~/.zshrc is chezmoi-managed and written before the installer runs, so
# on a fresh Ubuntu 26.04 checkpoint (issue #431 Run 10) `chezmoi status` showed `MM .zshrc`,
# and the next `dot up`'s plain `chezmoi apply` stops at ".zshrc has changed since chezmoi last
# wrote it?". The contract:
#   1. the vendor installer edits ~/.zshrc and ~/.bashrc: ~/.zshrc comes back byte-identical,
#      ~/.bashrc (not managed) keeps the edit;
#   2. the vendor installer fails after editing: ~/.zshrc still comes back, the run goes on
#      under set -e and warns;
#   3. no ~/.zshrc beforehand: nothing is created or removed by the guard itself.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

for d in /usr/bin /bin; do
    [ ! -e "$d/agy" ] || skip "$d/agy exists - the system PATH this test uses would resolve it"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_to "$tmp/installer.sh" sh '{"antigravity_cli": true}'
for fn in keeping_zshrc install_antigravity_cli; do
    awk -v f="$fn" '$0 ~ "^" f "\\(\\) \\{" {on=1} on {print} on && /^\}$/ {exit}' "$tmp/installer.sh" >>"$tmp/fns.sh"
    grep -q "^$fn() {" "$tmp/fns.sh" || fail "$fn() not found in the rendered installer"
done

{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. "%s"\n' "$repo_root/scripts/lib/agent-skills.sh" # info/warn
    cat <<'STUBS'
PKG_MANAGER=apt
agy_superpowers_installed() { return 0; }
# The vendor installer: appends to every rc file it finds, as agy's does, then maybe fails.
net_timeout() {
    local f
    for f in .bashrc .zshrc .profile; do
        [ -f "$HOME/$f" ] && printf '\n\n# Added by Antigravity CLI installer\nexport PATH="%s/.local/bin:$PATH"\n' "$HOME" >>"$HOME/$f"
    done
    [ "${INSTALL_FAILS:-0}" = 1 ] && return 1
    return 0
}
STUBS
    cat "$tmp/fns.sh"
    printf '%s\n' 'install_antigravity_cli' 'echo end'
} >"$tmp/harness.sh"

run() { # $1 = HOME; prints the harness output
    HOME="$1" PATH=/usr/bin:/bin bash "$tmp/harness.sh" 2>&1
}
seed() { # $1 = HOME
    mkdir -p "$1"
    printf 'managed by chezmoi\n' >"$1/.zshrc"
    printf 'not managed\n' >"$1/.bashrc"
    cp "$1/.zshrc" "$1/zshrc.want"
}

# 1. The vendor installer edits both.
h1="$tmp/h1"; seed "$h1"
out="$(run "$h1")" || fail "edit: the installer function failed (got: $out)"
cmp -s "$h1/zshrc.want" "$h1/.zshrc" && pass ||
    fail "edit: ~/.zshrc must come back byte-identical (got: $(cat "$h1/.zshrc"))"
grep -q 'Added by Antigravity CLI installer' "$h1/.bashrc" && pass ||
    fail "edit: ~/.bashrc is not managed and must keep the vendor's edit"

# 2. The vendor installer fails after editing.
h2="$tmp/h2"; seed "$h2"
out="$(INSTALL_FAILS=1 run "$h2")" || fail "failure: the run must go on under set -e (got: $out)"
cmp -s "$h2/zshrc.want" "$h2/.zshrc" && pass || fail "failure: ~/.zshrc must still come back"
case "$out" in *'Antigravity CLI installer failed'*end*) pass ;;
    *) fail "failure: expected the warning and the rest of the run (got: $out)" ;; esac

# 3. No ~/.zshrc beforehand.
h3="$tmp/h3"; mkdir -p "$h3"
out="$(run "$h3")" || fail "no zshrc: the installer function failed (got: $out)"
[ ! -e "$h3/.zshrc" ] && pass || fail "no zshrc: the guard must not create one"

finish
