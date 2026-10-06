#!/usr/bin/env bash
set -euo pipefail

# `dot up` installs the VS Code extensions that are MISSING and never upgrades. The Windows
# installer used to `--force` every extension on every run (one slow marketplace answer cost
# 4m44s); the shell installer called `code --install-extension` once per extension. Both now
# list what is installed once (a local call) and skip those. The shell loop is EXTRACTED from
# the rendered installer and run against a fake `code`.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_to "$tmp/installer.sh" sh '{"vscode_settings": true, "core": true}'
[ -s "$tmp/installer.sh" ] || fail "the shell installer did not render"

# From the declaration of the loop's variables through the heredoc terminator.
awk '/local ext ext_lc vs_installed/ {on = 1} on {print} on && /^VSEXT$/ {exit}' "$tmp/installer.sh" >"$tmp/block.sh"
grep -Fq 'code --list-extensions' "$tmp/block.sh" || fail "block extraction lost the listing step (source shape changed?)"
grep -Fxq 'VSEXT' "$tmp/block.sh" || fail "block extraction lost the heredoc terminator (source shape changed?)"
wanted="$(sed -n "/<<'VSEXT'/,/^VSEXT\$/p" "$tmp/block.sh" | sed '1d;$d' | grep -v '^[[:space:]]*$' | grep -v '^{{' || true)"
[ "$(printf '%s\n' "$wanted" | grep -c .)" -ge 5 ] || fail "expected the extension list inside the block (got: $wanted)"

first="$(printf '%s\n' "$wanted" | sed -n 1p)"
second="$(printf '%s\n' "$wanted" | sed -n 2p)"

run() { # $1 = installed list printed by `code --list-extensions`; prints the extensions it installed
    {
        printf '%s\n' 'warn() { echo "WARN $*"; }'
        # The installer discards `code`'s stdout, so the fake records what it was asked to install.
        printf '%s\n' 'code() { case "$1" in --list-extensions) printf "%s\n" "$FAKE_INSTALLED" ;; --install-extension) echo "INSTALL $2" >>"$INSTALL_LOG" ;; esac; }'
        printf '%s\n' 'f() {'
        cat "$tmp/block.sh"
        printf '%s\n' '}'
        printf '%s\n' 'f'
    } >"$tmp/harness.sh"
    : >"$tmp/install.log"
    FAKE_INSTALLED="$1" INSTALL_LOG="$tmp/install.log" bash "$tmp/harness.sh" 2>&1
    cat "$tmp/install.log"
}

# everything present (case differs: VS Code lists ids lower-case) -> nothing installed
all_lc="$(printf '%s\n' "$wanted" | tr '[:upper:]' '[:lower:]')"
out="$(run "$all_lc")"
if printf '%s\n' "$out" | grep -q '^INSTALL '; then fail "installed extensions must not be reinstalled (got: $(printf '%s' "$out" | head -3))"; else pass; fi

# one missing -> exactly that one is installed
without_first="$(printf '%s\n' "$all_lc" | sed 1d)"
out="$(run "$without_first")"
[ "$(printf '%s\n' "$out" | grep -c '^INSTALL ')" = 1 ] || fail "exactly the missing extension must be installed (got: $out)"
printf '%s\n' "$out" | grep -Fxq "INSTALL $first" || fail "the missing extension $first must be the one installed (got: $out)"

# listing unavailable (code prints nothing) -> falls back to trying every extension
out="$(run "")"
[ "$(printf '%s\n' "$out" | grep -c '^INSTALL ')" = "$(printf '%s\n' "$wanted" | grep -c .)" ] ||
    fail "with no listing every extension must still be attempted (got $(printf '%s\n' "$out" | grep -c '^INSTALL ') of $(printf '%s\n' "$wanted" | grep -c .))"
[ -n "$second" ] || fail "fixture sanity: the list has a second extension"
pass

finish
