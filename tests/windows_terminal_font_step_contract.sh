#!/usr/bin/env bash
set -euo pipefail

# The installer's Windows Terminal font step ($fonts block of run_onchange_install_packages.ps1.tmpl)
# runs under Set-StrictMode -Version Latest, where READING a missing property throws. Until
# f18e342 the modify_settings.json merge always wrote profiles.defaults.font, so the step's
# `$wtJson.profiles.defaults.font` read never missed. The merge now leaves the font out until
# MesloLGSNerdFontMono-*.ttf is installed, which on a fresh install is AFTER chezmoi's file pass:
# the read threw PropertyNotFoundStrict and the catch reported it as "Could not parse Windows
# Terminal settings.json even as JSONC" (LAB-DOT-WIN-HOM #434 Run 6, 2026-10-24).
#
# Executed here: the extracted ConvertFrom-JsonC + font step, under StrictMode, against a
# settings.json with no font, one with a different face, and one already set.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"

. "$repo_root/tests/lib.sh"

# eol=crlf source: read a materialized LF-only copy (see psreadline_predictive_contract.sh).
lf_tmpl="$(mktemp)"
harness="$(mktemp -d)"
trap 'rm -rf "$lf_tmpl" "$harness"' EXIT
tr -d '\r' <"$tmpl" >"$lf_tmpl"

jsonc_fn="$(awk '/^function ConvertFrom-JsonC/{f=1} f{print} f&&/^\}$/{exit}' "$lf_tmpl")"
font_step="$(awk '/^if \(\$wtSettings\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$lf_tmpl")"
[ -n "$jsonc_fn" ] || fail "$tmpl: could not locate ConvertFrom-JsonC"
case "$font_step" in
    *'profiles.defaults'*'font'*) pass ;;
    *) fail "$tmpl: could not locate the Windows Terminal font step (if (\$wtSettings) { ... })" ;;
esac

shells=()
command -v pwsh >/dev/null 2>&1 && shells+=(pwsh)
command -v powershell.exe >/dev/null 2>&1 && shells+=(powershell.exe)
[ "${#shells[@]}" -gt 0 ] || skip 'executed part needs PowerShell: no pwsh or powershell.exe'

printf '%s\n' "$jsonc_fn" >"$harness/jsonc.ps1"
printf '%s\n' "$font_step" >"$harness/step.ps1"
cat >"$harness/run.ps1" <<'PSEOF'
param([string]$Settings, [string]$Dir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $Dir 'jsonc.ps1')
$wtSettings = $Settings
$desiredFont = 'MesloLGS Nerd Font Mono'
. (Join-Path $Dir 'step.ps1')
$after = Get-Content $Settings -Raw | ConvertFrom-Json
Write-Output ("FACE=" + $after.profiles.defaults.font.face)
PSEOF

to_native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

for sh in "${shells[@]}"; do
    # Fresh install: defaults exist (the merge styled them) but carry no font yet. Comments and a
    # trailing comma keep the JSONC path honest.
    cat >"$harness/nofont.json" <<'EOF'
{
  // Terminal's own comment
  "profiles": { "defaults": { "colorScheme": "Catppuccin Mocha", }, "list": [] }
}
EOF
    out="$("$sh" -NoProfile -NonInteractive -File "$(to_native "$harness/run.ps1")" -Settings "$(to_native "$harness/nofont.json")" -Dir "$(to_native "$harness")" 2>&1 || true)"
    case "$out" in
        *'Could not parse'*) fail "$sh: settings.json with no profiles.defaults.font must not hit the catch under StrictMode (got: $out)" ;;
        *'FACE=MesloLGS Nerd Font Mono'*) pass ;;
        *) fail "$sh: the font step must set profiles.defaults.font.face when font is absent (got: $out)" ;;
    esac

    printf '%s\n' '{ "profiles": { "defaults": { "font": { "face": "Cascadia Mono", "size": 12 } }, "list": [] } }' >"$harness/other.json"
    out="$("$sh" -NoProfile -NonInteractive -File "$(to_native "$harness/run.ps1")" -Settings "$(to_native "$harness/other.json")" -Dir "$(to_native "$harness")" 2>&1 || true)"
    case "$out" in
        *'FACE=MesloLGS Nerd Font Mono'*) pass ;;
        *) fail "$sh: a different face must be replaced (got: $out)" ;;
    esac

    printf '%s\n' '{ "profiles": { "defaults": { "font": { "face": "MesloLGS Nerd Font Mono" } }, "list": [] } }' >"$harness/set.json"
    rm -f "$harness/set.json.bak"
    out="$("$sh" -NoProfile -NonInteractive -File "$(to_native "$harness/run.ps1")" -Settings "$(to_native "$harness/set.json")" -Dir "$(to_native "$harness")" 2>&1 || true)"
    case "$out" in
        *'Set Windows Terminal default font'*) fail "$sh: an already-set face must be left alone (got: $out)" ;;
        *'FACE=MesloLGS Nerd Font Mono'*)
            if [ -e "$harness/set.json.bak" ]; then fail "$sh: no backup for an untouched file"; else pass; fi ;;
        *) fail "$sh: unexpected output for an already-set face (got: $out)" ;;
    esac

    # No profiles at all: the step builds the path down to font.face.
    printf '%s\n' '{ "defaultProfile": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}" }' >"$harness/bare.json"
    out="$("$sh" -NoProfile -NonInteractive -File "$(to_native "$harness/run.ps1")" -Settings "$(to_native "$harness/bare.json")" -Dir "$(to_native "$harness")" 2>&1 || true)"
    case "$out" in
        *'FACE=MesloLGS Nerd Font Mono'*) pass ;;
        *) fail "$sh: settings.json without profiles must still get the font (got: $out)" ;;
    esac

    # Legacy "profiles": [ ... ] array: left byte-for-byte alone, never replaced by an object.
    printf '%s\n' '{ "profiles": [ { "name": "Windows PowerShell" } ] }' >"$harness/legacy.json"
    cp "$harness/legacy.json" "$harness/legacy.orig"
    "$sh" -NoProfile -NonInteractive -File "$(to_native "$harness/run.ps1")" -Settings "$(to_native "$harness/legacy.json")" -Dir "$(to_native "$harness")" >/dev/null 2>&1 || true
    if cmp -s "$harness/legacy.json" "$harness/legacy.orig"; then pass; else
        fail "$sh: a legacy profiles array must be left untouched (now: $(cat "$harness/legacy.json"))"
    fi
done

finish
