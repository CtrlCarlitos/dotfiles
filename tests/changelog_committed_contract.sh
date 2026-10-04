#!/usr/bin/env bash
set -euo pipefail

# CHANGELOG.md is generated (scripts/changelog.sh), never hand-edited. This checks
# the COMMITTED file against the tags: the header, and every section whose release
# tag exists, must regenerate byte-identically (changelog.sh --section TAG). A hand
# edit, or a generator change that was not re-run, fails here.
#
# A section for a tag that does not exist yet (the release PR is merged, publish is
# pending) is not checked: it cannot be, there is nothing to render it from. With no
# release tag reachable (a shallow checkout) there is nothing to compare, so the
# check passes vacuously; the CI lint job fetches full history so it really runs.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v git >/dev/null 2>&1 || skip 'git not installed'
cd "$repo_root"
git rev-parse --git-dir >/dev/null 2>&1 || skip 'not a git checkout (no tags to compare)'

[ -f CHANGELOG.md ] || { fail 'CHANGELOG.md is missing (generate it with scripts/release.sh prepare)'; finish; }

# The canonical link base, so the result does not depend on how origin is spelled
# (SSH alias, fork, `act`).
export CHANGELOG_REPO_URL='https://github.com/CtrlCarlitos/dotfiles'

[ "$(head -n 5 CHANGELOG.md)" = "$(bash scripts/changelog.sh | head -n 5)" ] ||
    fail 'the CHANGELOG.md header differs from the generator (regenerate: scripts/release.sh prepare)'

checked=0
while IFS= read -r heading; do
    tag="${heading#\#\# }"
    tag="${tag%% *}"
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null || continue
    committed="$(awk -v h="$heading" '$0 == h { p = 1; print; next } p && /^## / { exit } p { print }' CHANGELOG.md)"
    expected="$(bash scripts/changelog.sh --section "$tag")"
    checked=$((checked + 1))
    if [ "$committed" = "$expected" ]; then
        pass
    else
        fail "CHANGELOG.md section $tag differs from git history:$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$committed") | head -8)"
    fi
done < <(grep '^## v' CHANGELOG.md)

if [ "$checked" -eq 0 ]; then
    printf '  note: no committed section has a reachable release tag (shallow checkout?); nothing compared\n'
fi

finish
