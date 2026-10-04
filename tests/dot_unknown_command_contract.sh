#!/usr/bin/env bash
set -euo pipefail

# `dot <anything it does not know>` must SAY so. It used to fall through to the help
# text with no error, which looks exactly like a broken command. The common cause: a
# shell started before a `dot up` keeps the `dot` function it loaded at startup (the
# repo deliberately never reloads a profile mid-session - double-loaded hooks), so a
# subcommand added since (`dot version`, `dot devtmp`) printed the help list, in the
# user's words "is it going without one?". Now:
#
#   dot <unknown>          "dot: unknown command '<x>'" + a hint to open a new shell,
#                          then the help list; exit status 2
#   dot / dot help / -h    the help list, no error, status 0
#
# All three dispatchers (invariant #10) are EXECUTED: the zsh dot() under bash (the way
# tests/dot_cli_contract.sh does) and the `dot` of both PowerShell profiles under pwsh.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# check LABEL RUN: RUN ARGS... prints "<combined output>\nrc=<status>"
check() {
    local label="$1" run="$2" out rc
    out="$("$run" bogus 2>&1 | tr -d '\r')"
    rc="${out##*rc=}"
    [[ $out == *"unknown command 'bogus'"* ]] || fail "$label: 'dot bogus' must say \"unknown command 'bogus'\" (got: ${out:0:160})"
    [[ $out == *'new shell'* ]] || fail "$label: the message must hint at opening a new shell (a stale shell is the usual cause)"
    [[ $out == *'dot up'* && $out == *'dot doctor'* ]] || fail "$label: the help list must still follow the error"
    [ "$rc" = 2 ] || fail "$label: 'dot bogus' must exit 2 (got '$rc')"

    local arg
    for arg in help -h --help; do
        out="$("$run" "$arg" 2>&1 | tr -d '\r')"
        rc="${out##*rc=}"
        [[ $out != *'unknown command'* ]] || fail "$label: 'dot $arg' is help, not an unknown command"
        [[ $out == *'dot up'* ]] || fail "$label: 'dot $arg' must print the help list"
        [ "$rc" = 0 ] || fail "$label: 'dot $arg' must exit 0 (got '$rc')"
    done
    out="$("$run" 2>&1 | tr -d '\r')"
    rc="${out##*rc=}"
    [[ $out != *'unknown command'* && $out == *'dot up'* && "$rc" = 0 ]] ||
        fail "$label: bare 'dot' must print the help list, exit 0, no error (got rc=$rc)"
}

# --- zsh dot(), evaluated under bash -------------------------------------------------------
zsh_aliases="$repo_root/dot_aliases.zsh"
awk '/^dot\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$zsh_aliases" >"$tmp/dot.zsh.fn"
[ -s "$tmp/dot.zsh.fn" ] || fail "could not extract dot() from $zsh_aliases"
run_zsh() { ( export DOTFILES_DIR="$tmp/source"; eval "$(cat "$tmp/dot.zsh.fn")"; dot "$@"; printf 'rc=%s\n' "$?" ) 2>&1; }
check zsh run_zsh

# --- the two PowerShell profiles, under pwsh ------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    for profile in Documents/PowerShell Documents/WindowsPowerShell; do
        file="$repo_root/$profile/Microsoft.PowerShell_profile.ps1"
        # awk reads a FILE, not a pipe: an awk that exits early on a pipe makes the writer
        # die of SIGPIPE, which pipefail turns into a failure on any large enough input.
        tr -d '\r' <"$file" >"$tmp/profile.ps1"
        awk '/^function dot \{/{f=1} f{print} f && /^\}$/{exit}' "$tmp/profile.ps1" >"$tmp/dot.ps1"
        [ -s "$tmp/dot.ps1" ] || { fail "could not extract the dot function from $profile"; continue; }
        {
            cat "$tmp/dot.ps1"
            printf '%s\n' '$global:LASTEXITCODE = 0' 'dot @args *>&1 | Out-String | Write-Output' 'Write-Output "rc=$global:LASTEXITCODE"'
        } >"$tmp/run-dot.ps1"
        run_ps() { pwsh -NoProfile -File "$(winpath "$tmp/run-dot.ps1")" "$@" 2>&1; }
        check "$profile" run_ps
    done
else
    printf 'SKIP (PowerShell profiles only): pwsh not installed\n'
fi

finish
