#!/usr/bin/env bash
set -euo pipefail

# configure_vscode_if_new - VS Code's settings and extensions on the run that installs it -
# EXECUTED from the rendered installer.
#
# configure_vscode runs at the 'VS Code' mark, before the desktop apps; while `code` is missing it
# skips settings and extensions. On a fresh machine VS Code arrives only with the desktop apps,
# after it: issue #431 Run 10's one-liner printed "Installing VS Code..." and nothing else for
# it, the settings and extensions came with the second `dot up` (Run 11), and keybindings.json
# (gated on ~/.config/Code/User at the start of an apply) with the third. The contract:
#   1. code missing at the mark, installed by the desktop step: configure_vscode runs again;
#   2. code already there at the mark: no second run;
#   3. code still missing (desktop step skipped or failed): no second run;
#   4. rendered order, on Linux and macOS: the presence is recorded right after the first
#      configure_vscode, and configure_vscode_if_new follows the desktop dispatch.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_to "$tmp/linux.sh" sh '{"dev_desktop": true}'
awk '/^configure_vscode_if_new\(\) \{/ {f=1} f {print} f && /^\}$/ {exit}' "$tmp/linux.sh" >"$tmp/fn.sh"
grep -q '^configure_vscode_if_new() {' "$tmp/fn.sh" || fail "configure_vscode_if_new() not found in the rendered installer"

mkdir -p "$tmp/bin"
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    cat <<'STUBS'
configure_vscode() { echo "configure code=$(command -v code >/dev/null && echo yes || echo no)" >>"$CALLS"; }
dot_timing_mark() { echo "mark $1" >>"$CALLS"; }
STUBS
    cat "$tmp/fn.sh"
    printf '%s\n' 'configure_vscode_if_new'
} >"$tmp/harness.sh"

run() { # $1 = vscode_was_present, $2 = 1 when `code` is on PATH now; prints the call log
    : >"$tmp/calls"
    rm -f "$tmp/bin/code"
    [ "$2" = 1 ] && { printf '#!/bin/sh\n' >"$tmp/bin/code"; chmod +x "$tmp/bin/code"; }
    # PATH is the stub dir alone (the harness uses builtins only), so a real VS Code on this
    # machine cannot answer `command -v code`.
    vscode_was_present="$1" CALLS="$tmp/calls" PATH="$tmp/bin" "$bash_bin" "$tmp/harness.sh" >/dev/null 2>&1 ||
        echo "rc=$?" >>"$tmp/calls"
    tr '\n' '|' <"$tmp/calls"
}
bash_bin="$(command -v bash)"

# 1. Installed by this run.
got="$(run "" 1)"
[ "$got" = 'mark VS Code|configure code=yes|mark desktop apps|' ] && pass ||
    fail "fresh install: configure_vscode must run again, timed as VS Code, then back to desktop apps (got: $got)"
# 2. Already there.
got="$(run /usr/bin/code 1)"
[ -z "$got" ] && pass || fail "already installed: no second configure_vscode (got: $got)"
# 3. Still missing.
got="$(run "" 0)"
[ -z "$got" ] && pass || fail "still missing: no second configure_vscode (got: $got)"

# 4. Rendered order, both platforms the dispatch serves.
render_to "$tmp/darwin.sh" darwin '{"dev_desktop": true}'
for r in linux darwin; do
    f="$tmp/$r.sh"
    rec="$(grep -n '^    vscode_was_present="$(command -v code || true)"$' "$f" | cut -d: -f1)"
    first=""
    [ -z "$rec" ] || [ "$(sed -n "$((rec - 1))p" "$f")" != '    configure_vscode' ] || first=$((rec - 1))
    desk="$(grep -nE '^ *install_(linux|mac)_desktop$' "$f" | tail -1 | cut -d: -f1)"
    again="$(grep -n '^    configure_vscode_if_new$' "$f" | cut -d: -f1)"
    grep -q '^configure_vscode_if_new() {' "$f" || fail "$r: configure_vscode_if_new() is not defined"
    [ -n "$first" ] && [ -n "$rec" ] && [ -n "$desk" ] && [ -n "$again" ] ||
        fail "$r: missing a step (configure_vscode=$first record=$rec desktop=$desk if_new=$again)"
    [ "$rec" = $((first + 1)) ] && [ "$again" -gt "$desk" ] && pass ||
        fail "$r: wrong order (configure_vscode=$first record=$rec desktop=$desk if_new=$again)"
done

finish
