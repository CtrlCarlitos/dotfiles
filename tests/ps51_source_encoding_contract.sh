#!/usr/bin/env bash
# shellcheck disable=SC2016  # PowerShell source is literal
set -euo pipefail

# Windows PowerShell 5.1 reads a BOM-less script as Windows-1252. A UTF-8 emoji or dash
# then decodes to several characters, and some of its bytes (0x84, 0x91-0x94) are "smart
# quotes" PowerShell honours as string delimiters: 📦 (F0 9F 93 A6) ended a string in
# update_ai_tools.ps1 and `dot upgrade` failed with "The term 'upgrading' is not
# recognized" (2026-10-07). No syntax error - the strings are silently re-split, so a
# parse check passes. This pins (docs/invariants.md #16):
#   1. every PowerShell source is ASCII, or starts with a UTF-8 BOM (devprofile.ps1);
#      install.ps1 (run as `irm | iex`) and the .ps1.tmpl templates are pure ASCII.
#      Glyphs in output are built from code points ([char]::ConvertFromUtf32);
#   2. executed where both editions exist: every script tokenizes to the same number of
#      tokens under Windows PowerShell 5.1 and PowerShell 7 (main's update_ai_tools.ps1
#      gave 3272 vs 3410).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
command -v python3 >/dev/null 2>&1 || skip "python3 not installed"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- 1. static ---------------------------------------------------------------------
git -C "$repo_root" ls-files '*.ps1' '*.ps1.tmpl' '*.psm1' '*.psd1' >"$tmp/files"
[ "$(wc -l <"$tmp/files")" -ge 20 ] || fail "expected at least 20 PowerShell files (git ls-files broken?)"
out="$(cd "$repo_root" && python3 - "$tmp/files" <<'PYEOF'
import sys
bad = []
for f in open(sys.argv[1]).read().split():
    b = open(f, "rb").read()
    bom = b.startswith(b"\xef\xbb\xbf")
    nonascii = [i for i, x in enumerate(b) if x > 127 and not (bom and i < 3)]
    must_ascii = f == "install.ps1" or f.endswith(".ps1.tmpl")
    if must_ascii and (bom or nonascii):
        bad.append("%s: must be pure ASCII without a BOM (%s)" % (f, "has a BOM" if bom else "non-ASCII at byte %d" % nonascii[0]))
    elif nonascii and not bom:
        line = b[:nonascii[0]].count(b"\n") + 1
        bad.append("%s:%d: non-ASCII without a BOM - Windows PowerShell 5.1 misreads it" % (f, line))
print("\n".join(bad))
PYEOF
)"
[ -z "$out" ] || fail "PowerShell sources must be ASCII (glyphs from code points) or carry a BOM:
$out"
pass

# --- 2. executed: same tokens under 5.1 and 7 ------------------------------------------
if command -v powershell.exe >/dev/null 2>&1 && command -v pwsh >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    printf '%s\n' 'param([string]$ListFile)' \
        'foreach ($p in Get-Content $ListFile) { $t = $null; $e = $null' \
        '    $null = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$t, [ref]$e)' \
        '    "{0}|{1}" -f $t.Count, $p }' >"$tmp/tok.ps1"
    grep -vE '\.ps1\.tmpl$' "$tmp/files" | while IFS= read -r f; do cygpath -w "$repo_root/$f"; done >"$tmp/list"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$tmp/tok.ps1")" -ListFile "$(cygpath -w "$tmp/list")" | tr -d '\r' | sed 's/^\xEF\xBB\xBF//' | sort >"$tmp/t51"
    pwsh -NoProfile -File "$(cygpath -w "$tmp/tok.ps1")" -ListFile "$(cygpath -w "$tmp/list")" | tr -d '\r' | sort >"$tmp/t7"
    [ -s "$tmp/t7" ] || fail "PowerShell 7 tokenized nothing"
    diff_out="$(diff "$tmp/t51" "$tmp/t7" || true)"
    [ -z "$diff_out" ] || fail "these scripts tokenize differently under Windows PowerShell 5.1 (<) and PowerShell 7 (>):
$diff_out"
    pass
else
    printf 'note: powershell.exe and pwsh not both available - the 5.1/7 token check runs on Windows only\n'
fi

finish
