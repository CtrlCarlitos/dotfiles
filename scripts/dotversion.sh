#!/usr/bin/env bash
# dotversion.sh - which version of the dotfiles repo is this machine on?
# The version is COMPUTED from git, never stored in a file, so it cannot drift
# from the history: `git describe` over the CalVer release tags vYYYY.MM.DD[.N].
# Prints one line and exits 0, or - when there is no git metadata to ask (a copy
# of the repo without .git) - says so and exits 1.
#
#   dotfiles v2026.10.04 (abc1234)                       exactly on a release
#   dotfiles v2026.10.04 (+3 commits, abc1234)           past it
#   dotfiles v2026.10.04 (+3 commits, abc1234, dirty)    tracked files edited
#   dotfiles abc1234 (untagged)                          no release tag reachable
#   dotfiles unknown (no git metadata in DIR)            exit 1
#
# Untracked files do not count as dirty (a scratch file is not an edit of the
# repo). Usage: bash dotversion.sh   (or: dot version). `dot doctor` prints the
# same line. PowerShell twin: dotversion.ps1 (invariant #10: change both).
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'dotfiles unknown (no git metadata in %s)\n' "$root"
    exit 1
fi

if ! desc="$(git -C "$root" describe --tags --long --always --abbrev=7 \
    --match 'v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]*' 2>/dev/null)"; then
    printf 'dotfiles unknown (git cannot describe HEAD in %s)\n' "$root"
    exit 1
fi

dirty=''
if [ -n "$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    dirty=1
fi

re='^(v[0-9]{4}\.[0-9]{2}\.[0-9]{2}[0-9.]*)-([0-9]+)-g([0-9a-f]+)$'
if [[ $desc =~ $re ]]; then
    tag="${BASH_REMATCH[1]}"
    ahead="${BASH_REMATCH[2]}"
    detail=''
    if [ "$ahead" -gt 0 ]; then
        plural='s'
        [ "$ahead" -eq 1 ] && plural=''
        detail="+$ahead commit$plural, "
    fi
    detail="$detail${BASH_REMATCH[3]}"
    [ -z "$dirty" ] || detail="$detail, dirty"
    printf 'dotfiles %s (%s)\n' "$tag" "$detail"
else
    detail='untagged'
    [ -z "$dirty" ] || detail="$detail, dirty"
    printf 'dotfiles %s (%s)\n' "$desc" "$detail"
fi
