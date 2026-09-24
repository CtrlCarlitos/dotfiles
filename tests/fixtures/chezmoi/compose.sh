#!/usr/bin/env bash
set -euo pipefail

# Compose a CI chezmoi.toml from the fixture pieces in this directory.
#
#   compose.sh <single|multi|minimal> <on|off> [--source-dir DIR] [--out FILE]
#
# Pieces are emitted in TOML order: sourceDir is a top-level key so it must
# come first; the account and package tables follow. With no --out the result
# goes to stdout. With --out the parent directory is created.
#
# Runs under bash on every runner, Windows included (GitHub's windows-latest
# ships Git Bash; a step just sets `shell: bash`). One composer, not a .ps1
# twin: the whole point is a single place a fixture can come from.

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    printf 'usage: %s <single|multi|minimal> <on|off> [--source-dir DIR] [--out FILE]\n' "${0##*/}" >&2
    exit 2
}

[ $# -ge 2 ] || usage
accounts="$1"; packages="$2"; shift 2
source_dir=""; out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --source-dir) [ $# -ge 2 ] || usage; source_dir="$2"; shift 2 ;;
        --out)        [ $# -ge 2 ] || usage; out="$2"; shift 2 ;;
        *) usage ;;
    esac
done

acc_file="$here/accounts-$accounts.toml"
pkg_file="$here/packages-$packages.toml"
[ -f "$acc_file" ] || { printf 'compose.sh: no such accounts fixture: %s\n' "$acc_file" >&2; exit 2; }
[ -f "$pkg_file" ] || { printf 'compose.sh: no such packages fixture: %s\n' "$pkg_file" >&2; exit 2; }

emit() {
    if [ -n "$source_dir" ]; then
        # TOML literal string: single quotes, no escaping, so a Windows path
        # like D:\a\dotfiles\dotfiles survives untouched.
        printf "sourceDir = '%s'\n\n" "$source_dir"
    fi
    cat "$acc_file"
    printf '\n'
    cat "$pkg_file"
}

if [ -n "$out" ]; then
    mkdir -p "$(dirname -- "$out")"
    emit > "$out"
    printf 'compose.sh: wrote %s (accounts=%s packages=%s%s)\n' \
        "$out" "$accounts" "$packages" "${source_dir:+ sourceDir set}"
else
    emit
fi
