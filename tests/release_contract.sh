#!/usr/bin/env bash
set -euo pipefail

# scripts/release.sh cuts a release in two human-reviewed steps:
#
#   prepare   on a branch fresh from origin/main: pick the next CalVer tag and write
#             CHANGELOG.md (scripts/changelog.sh --next TAG). You commit it as
#             `chore(release): TAG`, open the PR, merge it.
#   publish   tag THAT release commit on origin/main (annotated), push the tag, and
#             create the GitHub Release with the changelog section as its notes.
#
# Publishing is outward-facing, so everything is checked first and --dry-run shows
# the plan without doing it. The tag goes on the release commit, not on HEAD: the
# version-pin bot lands commits on main within minutes of a merge, and a tag on
# HEAD would then list commits the committed CHANGELOG.md does not.
# A bare origin and a recording `gh` stub make the real tagging and pushing testable.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v git >/dev/null 2>&1 || skip 'git not installed'
release="$repo_root/scripts/release.sh"
[ -f "$release" ] || { fail 'scripts/release.sh is missing'; finish; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$tmp"
export CHANGELOG_REPO_URL='https://example.test/r'
# release.sh runs plain `git tag -a`, so the sandbox needs an identity in the
# environment (the script must not invent one; a developer has their own).
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$tmp/gh.args"
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = --notes-file ]; then cp "\$2" "$tmp/gh.notes"; fi
    shift
done
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

g() { git -C "$1" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c tag.gpgsign=false "${@:2}"; }
c() { g "$1" commit -q --allow-empty -m "$2"; }
rel() { (cd "$1" && shift && bash "$release" "$@"); }

# origin (bare) + a working clone with a baseline tag and three commits on main.
git init -q --bare -b main "$tmp/origin.git"
work="$tmp/work"
git clone -q "$tmp/origin.git" "$work" 2>/dev/null
c "$work" 'initial commit'
g "$work" tag -a v2026.10.02 -m baseline
c "$work" 'feat(devtmp): one folder for build output (#234)'
c "$work" 'fix(opencode): converge MCP entries (#239)'
c "$work" 'chore: auto-update software versions (#237)'
g "$work" push -q origin main v2026.10.02 2>/dev/null

# --- prepare ------------------------------------------------------------------------
g "$work" switch -q -c chore/release origin/main
out="$(CHANGELOG_TODAY=2026-10-05 rel "$work" prepare 2>&1)" || fail "prepare failed: $out"
grep -Fq '## v2026.10.05 - 2026-10-05' "$work/CHANGELOG.md" || fail 'prepare must write the new top section to CHANGELOG.md'
grep -Fq 'one folder for build output' "$work/CHANGELOG.md" || fail 'prepare must list the commits since the last tag'
grep -Fq 'v2026.10.05' <<<"$out" || fail "prepare must name the tag it chose (got: $out)"
grep -Fq 'chore(release): v2026.10.05' <<<"$out" || fail "prepare must say how to commit it (got: $out)"
[ -z "$(g "$work" tag --list v2026.10.05)" ] || fail 'prepare must not create the tag (publish does, after the PR merges)'

# prepare --dry-run writes nothing.
git -C "$work" checkout -q -- CHANGELOG.md 2>/dev/null || rm -f "$work/CHANGELOG.md"
CHANGELOG_TODAY=2026-10-05 rel "$work" prepare --dry-run >/dev/null 2>&1 || fail 'prepare --dry-run failed'
[ ! -s "$work/CHANGELOG.md" ] || fail 'prepare --dry-run must not write CHANGELOG.md'

# prepare refuses: uncommitted tracked changes, a HEAD that is not origin/main, nothing to release.
printf 'x\n' >"$work/tracked.txt"
g "$work" add tracked.txt
if rel "$work" prepare >/dev/null 2>"$tmp/err"; then fail 'prepare must refuse with uncommitted tracked changes'; fi
g "$work" reset -q --hard
c "$work" 'feat: an unpushed local commit (#1)'
if rel "$work" prepare >/dev/null 2>"$tmp/err"; then fail 'prepare must refuse when HEAD is not origin/main'; else
    grep -Fq 'origin/main' "$tmp/err" || fail "the HEAD refusal must name origin/main (got: $(cat "$tmp/err"))"
fi
g "$work" reset -q --hard origin/main

# --- the release PR "merges": a chore(release) commit, then a bot commit after it --------
CHANGELOG_TODAY=2026-10-05 rel "$work" prepare >/dev/null 2>&1
g "$work" add CHANGELOG.md
c "$work" 'chore(release): v2026.10.05'
release_sha="$(g "$work" rev-parse HEAD)"
c "$work" 'chore: auto-update software versions (#250)'
g "$work" switch -q main
g "$work" reset -q --hard chore/release
g "$work" push -q origin main 2>/dev/null

# --- publish ------------------------------------------------------------------------
# Refusals first.
if rel "$work" publish v2026.10.09 >/dev/null 2>"$tmp/err"; then fail 'publish must refuse a tag with no release commit'; else
    grep -Fq 'release' "$tmp/err" || fail "the no-release-commit refusal must say so (got: $(cat "$tmp/err"))"
fi
if rel "$work" publish not-a-tag >/dev/null 2>&1; then fail 'publish must refuse a malformed tag'; fi

# --dry-run: the plan, no side effects.
out="$(rel "$work" publish v2026.10.05 --dry-run 2>&1)" || fail "publish --dry-run failed: $out"
grep -Fq "${release_sha:0:7}" <<<"$out" || fail "the plan must name the release commit ${release_sha:0:7} (got: $out)"
[ -z "$(g "$work" tag --list v2026.10.05)" ] || fail 'publish --dry-run must not create the tag'
[ ! -e "$tmp/gh.args" ] || fail 'publish --dry-run must not call gh'

# The real thing.
out="$(rel "$work" publish v2026.10.05 2>&1)" || fail "publish failed: $out"
[ "$(g "$work" rev-parse 'v2026.10.05^{commit}')" = "$release_sha" ] ||
    fail 'the tag must point at the release commit, not at the bot commit after it'
[ "$(g "$work" cat-file -t v2026.10.05)" = tag ] || fail 'the tag must be annotated'
[ -n "$(git -C "$tmp/origin.git" tag --list v2026.10.05)" ] || fail 'the tag must be pushed to origin'
[ "$(git -C "$tmp/origin.git" rev-parse 'v2026.10.05^{commit}')" = "$release_sha" ] || fail 'origin must have the tag on the release commit'
# gh is called as: release create TAG --title TAG --notes-file FILE --verify-tag
# (one argument per line in the stub's record; FILE is a temp path, so skip it).
got_args="$(grep -Fxv -e "$(sed -n '/^--notes-file$/{n;p;}' "$tmp/gh.args")" "$tmp/gh.args" | tr '\n' ' ')"
[ "$got_args" = 'release create v2026.10.05 --title v2026.10.05 --notes-file --verify-tag ' ] ||
    fail "gh must be called as: release create v2026.10.05 --title v2026.10.05 --notes-file F --verify-tag (got: $got_args)"
[ -f "$tmp/gh.notes" ] || fail 'gh must be given a notes file'
grep -Fq '### Features' "$tmp/gh.notes" || fail 'the release notes must be the changelog section'
! grep -Fq '## v2026.10.05' "$tmp/gh.notes" || fail 'the notes must not repeat the section heading (the release title has it)'
! grep -Fq 'v2026.10.02' "$tmp/gh.notes" || fail 'the notes must hold only the new section'

# A second publish of the same tag is refused (nothing is re-tagged).
if rel "$work" publish v2026.10.05 >/dev/null 2>"$tmp/err"; then fail 'publish must refuse a tag that already exists'; else
    grep -Fqi 'exists' "$tmp/err" || fail "the existing-tag refusal must say so (got: $(cat "$tmp/err"))"
fi

finish
