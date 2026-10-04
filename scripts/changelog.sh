#!/usr/bin/env bash
# changelog.sh - generate CHANGELOG.md from git history. Never edit the result
# by hand: it is derived from the tags and the commit titles, so it cannot
# disagree with the log. See docs/versioning.md.
#
#   changelog.sh                  the whole file on stdout: header + one section
#                                 per release tag (vYYYY.MM.DD[.N]), newest first
#   changelog.sh --unreleased     only the commits since the latest tag
#   changelog.sh --next TAG       the whole file with an extra top section TAG for
#                                 the commits since the latest tag - for a release
#                                 PR, written before TAG exists
#   changelog.sh --section TAG    one existing release's section, exactly as it appears
#                                 in the file (tests/changelog_committed_contract.sh
#                                 compares the committed file against it)
#   changelog.sh --next-tag [--date YYYY-MM-DD]
#                                 the next tag: that day (default today), then
#                                 .1, .2 ... when the day already has a release
#
# Rules (tests/changelog_contract.sh pins the exact output):
#   - The date of a section is the date in the TAG NAME, not a commit date, so a
#     committed file regenerates byte-identically whenever the tag is placed.
#   - The oldest tag is the baseline: its section lists no commits ("earlier
#     history is in git log").
#   - Conventional titles `type(scope)!: text (#N)` are grouped (Breaking, Features,
#     Fixes, Documentation, Tests and CI, Refactoring, Maintenance, Other); a `!`
#     puts the entry under Breaking only. `(#N)` becomes a PR link.
#   - Automation is not listed: `chore(release): ...` commits are dropped and
#     version-pin bumps (`chore: auto-update software versions`, `chore(guardrail):
#     pin ...`) are summarised as one line under Maintenance.
# PR links use CHANGELOG_REPO_URL (set it empty for plain `#N`), else the origin
# remote mapped to https://github.com/OWNER/REPO. CHANGELOG_TODAY overrides today
# (a test hook). Portable to bash 3.2 (no mapfile, no associative arrays).
set -euo pipefail

calver_glob='v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]*'
calver_re='^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$'

die() { printf 'changelog.sh: %s\n' "$1" >&2; exit "${2:-2}"; }

mode=full next='' date_arg='' sect=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --unreleased) mode=unreleased ;;
        --next) [ "$#" -ge 2 ] || die '--next needs a tag'; next="$2"; shift ;;
        --next-tag) mode=nexttag ;;
        --section) [ "$#" -ge 2 ] || die '--section needs a tag'; mode=section; sect="$2"; shift ;;
        --date) [ "$#" -ge 2 ] || die '--date needs YYYY-MM-DD'; date_arg="$2"; shift ;;
        -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

git rev-parse --git-dir >/dev/null 2>&1 || die 'not inside a git repository' 1

# --- release tags, oldest first --------------------------------------------------
tags=()
while IFS= read -r t; do
    [[ $t =~ $calver_re ]] && tags+=("$t")
done < <(git tag --list "$calver_glob" --sort=v:refname)
ntags=${#tags[@]}
latest=''
[ "$ntags" -eq 0 ] || latest="${tags[$((ntags - 1))]}"

tag_exists() { local t; for t in ${tags[@]+"${tags[@]}"}; do [ "$t" = "$1" ] && return 0; done; return 1; }
tag_date() { printf '%s-%s-%s' "${1:1:4}" "${1:6:2}" "${1:9:2}"; }

# --- the next tag ------------------------------------------------------------------
if [ "$mode" = nexttag ]; then
    day="${date_arg:-${CHANGELOG_TODAY:-$(date +%Y-%m-%d)}}"
    [[ $day =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "bad date: $day (want YYYY-MM-DD)"
    cand="v${day//-/.}"
    n=0
    while tag_exists "$cand"; do
        n=$((n + 1))
        cand="v${day//-/.}.$n"
    done
    printf '%s\n' "$cand"
    exit 0
fi

# --- PR links ----------------------------------------------------------------------
if [ "${CHANGELOG_REPO_URL+set}" = set ]; then
    base="$CHANGELOG_REPO_URL"
else
    base=''
    remote="$(git remote get-url origin 2>/dev/null || true)"
    # git@github-alias:Owner/Repo.git, https://github.com/Owner/Repo(.git), ...
    if [[ $remote =~ [:/]([^/:]+/[^/:]+)$ ]]; then
        slug="${BASH_REMATCH[1]%.git}"
        base="https://github.com/$slug"
    fi
fi

# --- one section from a range of commits ---------------------------------------------
# $1 = heading text, $2 = git revision range ('' = every commit reachable from HEAD)
render_section() {
    local title="$1" range="$2" subj type scope bang desc num entry group
    local g_breaking='' g_features='' g_fixes='' g_docs='' g_tests='' g_refactor='' g_maint='' g_other=''
    local pins=0 body='' log_args=(--no-merges --format=%s)
    if [ -n "$range" ]; then log_args+=("$range"); else log_args+=(HEAD); fi

    while IFS= read -r subj; do
        [ -n "$subj" ] || continue
        case "$subj" in
            'chore(release)'*) continue ;;
            'chore: auto-update software versions'* | 'chore(guardrail): pin '*) pins=$((pins + 1)); continue ;;
        esac
        type='' scope='' bang='' desc="$subj" num=''
        if [[ $subj =~ ^([a-z]+)(\(([^\)]*)\))?(!)?:\ (.+)$ ]]; then
            type="${BASH_REMATCH[1]}" scope="${BASH_REMATCH[3]}" bang="${BASH_REMATCH[4]}" desc="${BASH_REMATCH[5]}"
        fi
        if [[ $desc =~ ^(.*)\ \(#([0-9]+)\)$ ]]; then
            desc="${BASH_REMATCH[1]}" num="${BASH_REMATCH[2]}"
        fi
        entry='- '
        [ -z "$scope" ] || entry="$entry**$scope:** "
        entry="$entry$desc"
        if [ -n "$num" ]; then
            if [ -n "$base" ]; then entry="$entry ([#$num]($base/pull/$num))"; else entry="$entry (#$num)"; fi
        fi
        if [ -n "$bang" ]; then group=breaking; else
            case "$type" in
                feat) group=features ;;
                fix) group=fixes ;;
                docs) group=docs ;;
                test | ci) group=tests ;;
                refactor) group=refactor ;;
                chore | build | style) group=maint ;;
                *) group=other ;;
            esac
        fi
        case "$group" in
            breaking) g_breaking="$g_breaking$entry"$'\n' ;;
            features) g_features="$g_features$entry"$'\n' ;;
            fixes) g_fixes="$g_fixes$entry"$'\n' ;;
            docs) g_docs="$g_docs$entry"$'\n' ;;
            tests) g_tests="$g_tests$entry"$'\n' ;;
            refactor) g_refactor="$g_refactor$entry"$'\n' ;;
            maint) g_maint="$g_maint$entry"$'\n' ;;
            other) g_other="$g_other$entry"$'\n' ;;
        esac
    done < <(git log "${log_args[@]}")

    if [ "$pins" -gt 0 ]; then
        local plural='s'
        [ "$pins" -ne 1 ] || plural=''
        g_maint="$g_maint- $pins automated version-pin update$plural"$'\n'
    fi

    emit() { # $1 = group title, $2 = entries
        [ -z "$2" ] || body="$body### $1"$'\n\n'"$2"$'\n'
    }
    emit Breaking "$g_breaking"
    emit Features "$g_features"
    emit Fixes "$g_fixes"
    emit Documentation "$g_docs"
    emit 'Tests and CI' "$g_tests"
    emit Refactoring "$g_refactor"
    emit Maintenance "$g_maint"
    emit Other "$g_other"
    [ -n "$body" ] || body='No notable changes.'$'\n'
    # Called as $(render_section ...): the trailing blank lines are stripped, and
    # the caller joins sections with exactly one blank line.
    printf '## %s\n\n%s' "$title" "$body"
}

# shellcheck disable=SC2016  # the backticks are literal Markdown, not a command
header='# Changelog

Every release of this repo, newest first. Generated by `scripts/changelog.sh`
from git history - do not edit by hand (see docs/versioning.md). Versions are
dates: `vYYYY.MM.DD`, with `.1`, `.2` for a second release the same day.'

since_latest() { if [ -n "$latest" ]; then printf '%s..HEAD' "$latest"; fi; }

# The section of the release tag at index $1 (the oldest tag is the baseline).
tag_section() {
    local t="${tags[$1]}"
    if [ "$1" -eq 0 ]; then
        # shellcheck disable=SC2016  # literal Markdown backticks
        printf '## %s - %s\n\nBaseline: the first tagged state. Earlier history is in `git log`.' "$t" "$(tag_date "$t")"
    else
        render_section "$t - $(tag_date "$t")" "${tags[$(($1 - 1))]}..$t"
    fi
}

if [ "$mode" = section ]; then
    i=0
    while [ "$i" -lt "$ntags" ]; do
        if [ "${tags[$i]}" = "$sect" ]; then
            printf '%s\n' "$(tag_section "$i")"
            exit 0
        fi
        i=$((i + 1))
    done
    die "--section $sect: no such release tag"
fi

if [ "$mode" = unreleased ]; then
    printf '%s\n' "$(render_section Unreleased "$(since_latest)")"
    exit 0
fi

# --- the whole file --------------------------------------------------------------------
if [ -n "$next" ]; then
    [[ $next =~ $calver_re ]] || die "--next $next: not a release tag (want vYYYY.MM.DD[.N])"
    ! tag_exists "$next" || die "--next $next: that tag already exists"
    if [ -n "$latest" ]; then
        [ "$(printf '%s\n%s\n' "$latest" "$next" | sort -V | tail -n 1)" = "$next" ] ||
            die "--next $next: must come after the latest release $latest"
        [ "$(git rev-list --count "$latest..HEAD")" -gt 0 ] ||
            die "--next $next: nothing to release since $latest" 1
    fi
fi

out="$header"
if [ -n "$next" ]; then
    out="$out"$'\n\n'"$(render_section "$next - $(tag_date "$next")" "$(since_latest)")"
fi
if [ "$ntags" -eq 0 ] && [ -z "$next" ]; then
    out="$out"$'\n\n''No releases yet.'
fi
i=$((ntags - 1))
while [ "$i" -ge 0 ]; do
    out="$out"$'\n\n'"$(tag_section "$i")"
    i=$((i - 1))
done
printf '%s\n' "$out"
