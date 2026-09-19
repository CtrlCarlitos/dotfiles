#!/usr/bin/env bash
set -euo pipefail

# Behavioral tests for scripts/init-line-endings.sh + .ps1 twin: the
# deterministic .gitattributes/.editorconfig generator for cross-platform
# repos. Fixture repo with shell/Windows/binary/indent types; asserts the
# generated pair agrees, the idempotence contract (no overwrite without
# --force), and the renormalize path for a CRLF-committed shell script.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tool="$repo_root/scripts/init-line-endings.sh"
tool_ps1="$repo_root/scripts/init-line-endings.ps1"

command -v git >/dev/null 2>&1 || { printf 'SKIP: git not installed\n'; exit 0; }

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fixture repo: shell + windows + indent + binary types, plus one .sh
# committed with CRLF to exercise renormalize.
R="$TMP/fixture"
mkdir -p "$R"
git -C "$R" init -q
git -C "$R" config user.email t@example.com
git -C "$R" config user.name T
# Pin the fixture's own conversion OFF so the CRLF blob really lands in the
# object DB verbatim - a host with autocrlf=input would silently normalize it
# at add time and the renormalize assertion would fail for the wrong reason.
git -C "$R" config core.autocrlf false
printf '#!/bin/sh\necho hi\n' > "$R/a.sh"
printf 'x\n' > "$R/b.ps1"
printf 'x = 1\n' > "$R/c.py"
printf 'k: v\n' > "$R/d.yml"
printf 'not-an-image\n' > "$R/img.png"   # type-marker only
printf 'go\n' > "$R/m.go"
printf '#!/bin/sh\r\necho crlf\r\n' > "$R/legacy.sh"
git -C "$R" add -A
git -C "$R" commit -qm init

# --- .sh twin ----------------------------------------------------------------
bash "$tool" "$R" > "$TMP/out1" 2>&1 || fail "[sh] tool exited non-zero: $(cat "$TMP/out1")"

grep -Fq '* text=auto eol=lf' "$R/.gitattributes" || fail "[sh] missing LF default rule"
grep -Fq '*.sh text eol=lf' "$R/.gitattributes" || fail "[sh] missing sh LF rule"
grep -Fq '*.ps1 text eol=crlf' "$R/.gitattributes" || fail "[sh] missing ps1 CRLF rule"
grep -Fq '*.png binary' "$R/.gitattributes" || fail "[sh] missing binary rule for present png"
! grep -Fq '*.jpg binary' "$R/.gitattributes" || fail "[sh] generated rule for absent jpg"

grep -Fq 'end_of_line = lf' "$R/.editorconfig" || fail "[sh] editorconfig missing lf"
grep -Fq 'end_of_line = crlf' "$R/.editorconfig" || fail "[sh] editorconfig missing ps1 crlf"
grep -Fq 'indent_style = tab' "$R/.editorconfig" || fail "[sh] editorconfig missing go tab indent"
grep -Fq 'charset = utf-8' "$R/.editorconfig" || fail "[sh] editorconfig missing charset"

# Renormalize staged the CRLF-committed shell script.
git -C "$R" diff --cached --name-only | grep -Fq 'legacy.sh' ||
    fail "[sh] CRLF-committed legacy.sh was not renormalized"
echo "  ok: sh twin generates agreeing pair + renormalizes CRLF shell script"

# Idempotence: no --force keeps files; --force rewrites them.
echo '# manual edit' >> "$R/.gitattributes"
bash "$tool" "$R" > "$TMP/out2" 2>&1
grep -Fq '# manual edit' "$R/.gitattributes" || fail "[sh] overwrote .gitattributes without --force"
bash "$tool" --force "$R" > "$TMP/out3" 2>&1
! grep -Fq '# manual edit' "$R/.gitattributes" || fail "[sh] --force did not regenerate"
echo "  ok: sh twin idempotent (--force required to overwrite)"

# --- .ps1 twin (pwsh hosts) ---------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    R2="$TMP/fixture2"
    mkdir -p "$R2"
    git -C "$R2" init -q
    git -C "$R2" config user.email t@example.com
    git -C "$R2" config user.name T
    git -C "$R2" config core.autocrlf false
    printf '#!/bin/sh\necho hi\n' > "$R2/a.sh"
    printf 'x\n' > "$R2/b.ps1"
    printf '#!/bin/sh\r\necho crlf\r\n' > "$R2/legacy.sh"
    git -C "$R2" add -A
    git -C "$R2" commit -qm init
    pwsh -NoProfile -File "$tool_ps1" -RepoDir "$R2" > "$TMP/out4" 2>&1 ||
        fail "[ps1] tool exited non-zero: $(cat "$TMP/out4")"
    grep -Fq '* text=auto eol=lf' "$R2/.gitattributes" || fail "[ps1] missing LF default rule"
    grep -Fq '*.ps1 text eol=crlf' "$R2/.gitattributes" || fail "[ps1] missing ps1 CRLF rule"
    grep -Fq 'end_of_line = lf' "$R2/.editorconfig" || fail "[ps1] editorconfig missing lf"
    git -C "$R2" diff --cached --name-only | grep -Fq 'legacy.sh' ||
        fail "[ps1] CRLF-committed legacy.sh was not renormalized"
    echo "  ok: ps1 twin generates agreeing pair + renormalizes"
else
    echo "  skip: ps1 twin (pwsh not installed)"
fi

printf 'PASS: init-line-endings (generation, agreement, idempotence, renormalize)\n'
