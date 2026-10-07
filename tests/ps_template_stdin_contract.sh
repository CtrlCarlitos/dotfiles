#!/usr/bin/env bash
# shellcheck disable=SC2016  # PowerShell and template text are literal
set -euo pipefail

# Windows PowerShell 5.1 strips the double quotes inside an argument it passes to a
# native program, so `chezmoi execute-template '{{ if hasKey . "winget" }}...'` reached
# chezmoi as `hasKey . winget` and failed with `function "winget" not defined`
# (migrate-to-winget.ps1 run from powershell.exe, 2026-10-07). PowerShell 7 passes
# them through, so it only ever broke under 5.1. A template goes to chezmoi on STDIN,
# which both editions pass through untouched. This pins:
#   1. no PowerShell script passes execute-template a template with a double quote,
#      or one held in a variable (its text cannot be checked here), as an argument;
#   2. executed under real Windows PowerShell 5.1 where it exists: the argument form
#      loses the quotes (the premise), the stdin form renders.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

# --- 1. static ---------------------------------------------------------------------
hits="$(git -C "$repo_root" ls-files '*.ps1' ':!tests/*' | while IFS= read -r f; do
    # `execute-template --file <path>` passes a PATH, not a template text: never flagged.
    grep -nE "execute-template( +--[a-z-]+ +[^ ]+)* +('[^']*\"|\\\$[A-Za-z])" "$repo_root/$f" | grep -v 'execute-template --file ' | sed "s|^|$f:|" || true
done)"
[ -z "$hits" ] || fail "templates with a double quote (or in a variable) must reach chezmoi on stdin - pipe them:
$hits"
pass

# --- 2. executed under Windows PowerShell 5.1 ----------------------------------------
if command -v powershell.exe >/dev/null 2>&1 && command -v chezmoi >/dev/null 2>&1; then
    cfg="$(mktemp "${TMPDIR:-/tmp}/ps51-config-XXXXXX.toml")"
    : >"$cfg"
    wcfg="$(if command -v cygpath >/dev/null 2>&1; then cygpath -w "$cfg"; else printf '%s' "$cfg"; fi)"
    out="$(powershell.exe -NoProfile -Command "
        \$t = '{{ if hasKey . \"chezmoi\" }}quoted-ok{{ end }}'
        'arg=' + ((chezmoi execute-template --config '$wcfg' \$t 2>&1 | Out-String).Trim() -replace '\s+', ' ')
        'stdin=' + (\$t | chezmoi execute-template --config '$wcfg' | Out-String).Trim()
    " 2>&1 | tr -d '\r' | sed 's/^\xEF\xBB\xBF//')"
    rm -f "$cfg"
    printf '%s\n' "$out" | grep -qx 'stdin=quoted-ok' || fail "Windows PowerShell 5.1: a template on stdin must render (got: $out)"
    # the premise: if 5.1 ever stops stripping the quotes, this note says the rule can relax
    if printf '%s\n' "$out" | grep -qx 'arg=quoted-ok'; then
        printf 'note: this Windows PowerShell passed the quotes through as an argument\n'
    fi
    pass
else
    printf 'note: powershell.exe or chezmoi not available - the 5.1 check runs on Windows only\n'
fi

finish
