#!/usr/bin/env bash
set -euo pipefail

# `dot version`: which version of the dotfiles repo is this machine on?
#
# The version is COMPUTED from git (`git describe` over the CalVer tags
# vYYYY.MM.DD[.N]), never stored in a file, so it cannot drift from the history:
#
#   dotfiles v2026.10.04 (abc1234)                  exactly on a release
#   dotfiles v2026.10.04 (+3 commits, abc1234)      3 commits past it
#   dotfiles v2026.10.04 (+3 commits, abc1234, dirty)   tracked files edited
#   dotfiles abc1234 (untagged)                     no release tag reachable
#   dotfiles unknown (no git metadata in DIR)       exit 1 (a copy without .git)
#
# Both twins (invariant #10) run against the same throwaway git repos. The repos
# are isolated from the host's git config (which may sign commits). Wiring into
# the three `dot` dispatchers and the two doctors is asserted at the bottom.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v git >/dev/null 2>&1 || skip 'git not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$tmp"

winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
g() { git -C "$1" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c tag.gpgsign=false "${@:2}"; }
sha() { git -C "$1" rev-parse --short=7 HEAD; }
commits() { local i; for ((i = 0; i < $2; i++)); do g "$1" commit -q --allow-empty -m "c$i"; done; }
newrepo() { # $1 = name -> a repo with both twins copied in (untracked, like a deployed checkout)
    local d="$tmp/$1"
    mkdir -p "$d/scripts"
    cp "$repo_root/scripts/dotversion.sh" "$repo_root/scripts/dotversion.ps1" "$d/scripts/" 2>/dev/null || true
    git -C "$d" init -q -b main
    g "$d" commit -q --allow-empty -m base
    printf '%s' "$d"
}

# --- fixtures ----------------------------------------------------------------------
untagged="$(newrepo untagged)"

exact="$(newrepo exact)"
g "$exact" tag v2026.10.04

ahead="$(newrepo ahead)"
g "$ahead" tag v2026.10.04
commits "$ahead" 3

ahead1="$(newrepo ahead1)"
g "$ahead1" tag v2026.10.04
commits "$ahead1" 1

dirty="$(newrepo dirty)"
printf 'x\n' >"$dirty/tracked.txt"
g "$dirty" add tracked.txt
g "$dirty" commit -q -m "add tracked"
g "$dirty" tag v2026.10.04
commits "$dirty" 3
printf 'edited\n' >"$dirty/tracked.txt"

untracked="$(newrepo untracked)"
g "$untracked" tag v2026.10.04
commits "$untracked" 3
printf 'scratch\n' >"$untracked/not-tracked.txt"

nonmatch="$(newrepo nonmatch)"
g "$nonmatch" tag v2026.10.04
commits "$nonmatch" 2
g "$nonmatch" tag foo
g "$nonmatch" tag v1
g "$nonmatch" tag release-2026

suffix="$(newrepo suffix)"
g "$suffix" tag v2026.10.04
commits "$suffix" 1
g "$suffix" tag v2026.10.04.1

newest="$(newrepo newest)"
g "$newest" tag v2026.09.30
commits "$newest" 2
g "$newest" tag v2026.10.04
commits "$newest" 1

nogit="$tmp/nogit"
mkdir -p "$nogit/scripts"
cp "$repo_root/scripts/dotversion.sh" "$repo_root/scripts/dotversion.ps1" "$nogit/scripts/" 2>/dev/null || true

# --- the check, per twin ------------------------------------------------------------
check_twin() { # $1 = label, $2 = function: run DIR -> stdout (CRs stripped)
    local label="$1" run="$2" out rc
    expect() { # $1 = case, $2 = dir, $3 = wanted output
        out="$("$run" "$2")" || true
        if [ "$out" = "$3" ]; then pass; else fail "$label/$1: wanted '$3', got '$out'"; fi
    }
    expect untagged "$untagged" "dotfiles $(sha "$untagged") (untagged)"
    expect exact "$exact" "dotfiles v2026.10.04 ($(sha "$exact"))"
    expect ahead "$ahead" "dotfiles v2026.10.04 (+3 commits, $(sha "$ahead"))"
    expect ahead-singular "$ahead1" "dotfiles v2026.10.04 (+1 commit, $(sha "$ahead1"))"
    expect dirty "$dirty" "dotfiles v2026.10.04 (+3 commits, $(sha "$dirty"), dirty)"
    expect untracked-is-clean "$untracked" "dotfiles v2026.10.04 (+3 commits, $(sha "$untracked"))"
    expect ignores-other-tags "$nonmatch" "dotfiles v2026.10.04 (+2 commits, $(sha "$nonmatch"))"
    expect same-day-suffix "$suffix" "dotfiles v2026.10.04.1 ($(sha "$suffix"))"
    expect nearest-tag "$newest" "dotfiles v2026.10.04 (+1 commit, $(sha "$newest"))"

    rc=0
    out="$("$run" "$nogit")" || rc=$?
    case "$out" in
        'dotfiles unknown (no git metadata in '*')') pass ;;
        *) fail "$label/no-git: wanted 'dotfiles unknown (no git metadata in …)', got '$out'" ;;
    esac
    [ "$rc" -eq 1 ] || fail "$label/no-git: must exit 1 when the version is unknown (got $rc)"
}

run_sh() { if [ -f "$1/scripts/dotversion.sh" ]; then bash "$1/scripts/dotversion.sh" 2>&1 | tr -d '\r'; else printf 'MISSING dotversion.sh\n'; fi; }
run_ps() { if [ -f "$1/scripts/dotversion.ps1" ]; then pwsh -NoProfile -File "$(winpath "$1/scripts/dotversion.ps1")" 2>&1 | tr -d '\r'; else printf 'MISSING dotversion.ps1\n'; fi; }

[ -f "$repo_root/scripts/dotversion.sh" ] || fail 'scripts/dotversion.sh is missing'
[ -f "$repo_root/scripts/dotversion.ps1" ] || fail 'scripts/dotversion.ps1 is missing'
check_twin sh run_sh
if command -v pwsh >/dev/null 2>&1; then
    check_twin ps1 run_ps
else
    printf 'SKIP (ps1 twin only): pwsh not installed\n'
fi

# --- wiring: three dispatchers, two doctors -----------------------------------------
require "$repo_root/dot_aliases.zsh" "version)  shift; bash \"\$repo_scripts/dotversion.sh\" \"\$@\" ;;"
require "$repo_root/dot_aliases.zsh" "'dot version'"
for profile in "$repo_root/Documents/PowerShell/Microsoft.PowerShell_profile.ps1" "$repo_root/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"; do
    require "$profile" "'version' { & (Join-Path \$repoScripts 'dotversion.ps1') @rest }"
    require "$profile" "'dot version'"
done
require "$repo_root/scripts/dotfiles-doctor.sh" 'dotfiles-version'
require "$repo_root/scripts/dotfiles-doctor.ps1" 'dotfiles-version'

finish
