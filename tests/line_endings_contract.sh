#!/usr/bin/env bash
set -euo pipefail

# Line-ending policy, enforced on THIS repo's own tracked files (issue: the
# policy had no executable check - tests/init_line_endings.sh only exercises the
# generator on a fixture repo, and invariant #8 said "run git ls-files --eol" by
# hand). Two files drifted unnoticed because `git diff` normalises on read.
#
#   .gitattributes decides:  * text=auto eol=lf ; sh/zsh/bash LF ;
#                            ps1/ps1.tmpl/bat/cmd CRLF (CRLF on checkout, LF in
#                            the index).
#   1. the INDEX holds LF for every text file (CRLF never gets committed);
#   2. every tracked file's WORKTREE ending matches its eol attribute - a CRLF
#      attribute checks out CRLF on every OS, so this holds on every runner;
#   3. .editorconfig's CRLF section covers exactly the CRLF types of
#      .gitattributes, so editors write what Git expects;
#   4. core.autocrlf stays false in the managed gitconfig.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v git >/dev/null 2>&1 || skip 'git not installed'
cd "$repo_root"
git rev-parse --git-dir >/dev/null 2>&1 || skip 'not a git checkout (no index to compare)'

# --- 1 + 2. index and worktree against the attribute ---------------------------
# `git ls-files --eol`: "i/lf    w/crlf  attr/text eol=crlf<TAB>path". Binary and
# empty files report -text / none; they carry no ending to judge.
checked=0
while IFS=$'\t' read -r left path; do
    read -r idx wt attr eolattr <<<"$left"
    case "$attr" in *-text*|*binary*) continue ;; esac
    case "$idx" in
        i/lf|i/none|i/-text|i/) ;;
        *) fail "$path: the index holds ${idx#i/} line endings (must be LF; CRLF is only ever a checkout form)" ;;
    esac
    case "$eolattr" in
        eol=crlf) want='w/crlf' ;;
        eol=lf)   want='w/lf' ;;
        *)        continue ;;
    esac
    case "$wt" in w/none|w/|w/-text) continue ;; esac
    checked=$((checked + 1))
    if [ "$wt" = "$want" ]; then
        pass
    else
        fail "$path: worktree is ${wt#w/} but .gitattributes says ${eolattr#eol=} (fix: git add --renormalize <file>, or rewrite the file with ${eolattr#eol=})"
    fi
done < <(git ls-files --eol)
[ "$checked" -gt 0 ] || fail 'no tracked file was checked (git ls-files --eol output not understood)'

# --- 3. .editorconfig agrees with .gitattributes -------------------------------
attr_crlf="$(sed -n 's/^\*\.\([A-Za-z0-9.]*\)[[:space:]]\{1,\}text[[:space:]]\{1,\}eol=crlf.*/\1/p' .gitattributes | sort -u)"
[ -n "$attr_crlf" ] || fail '.gitattributes: no CRLF rules found (the Windows script types need them)'
# The header of every section that sets end_of_line = crlf, reduced to a list of
# extensions: "[*.{ps1,ps1.tmpl},*.bat]" -> ps1 / ps1.tmpl / bat.
ec_crlf="$(awk '/^\[/{h=$0} /^end_of_line[[:space:]]*=[[:space:]]*crlf/{print h}' .editorconfig |
    sed 's/^\[//; s/\]$//; s/\*\.//g; s/[{}]//g' | tr ',' '\n' | sort -u)"
if [ "$attr_crlf" = "$ec_crlf" ]; then
    pass
else
    ec_list="$(printf '%s' "$ec_crlf" | tr '\n' ' ')"
    attr_list="$(printf '%s' "$attr_crlf" | tr '\n' ' ')"
    fail ".editorconfig CRLF section (${ec_list% }) must match .gitattributes CRLF types (${attr_list% }); an editor would write the wrong ending for the difference"
fi
grep -Eq '^end_of_line[[:space:]]*=[[:space:]]*lf' .editorconfig || fail '.editorconfig: the [*] default must be end_of_line = lf'

# --- 4. no machine-level conversion ---------------------------------------------
grep -Eq '^[[:space:]]*autocrlf[[:space:]]*=[[:space:]]*false' dot_gitconfig.tmpl ||
    fail 'dot_gitconfig.tmpl: core.autocrlf must be false (.gitattributes is the single authority)'

finish
