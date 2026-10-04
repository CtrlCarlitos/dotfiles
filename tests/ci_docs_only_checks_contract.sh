#!/usr/bin/env bash
set -euo pipefail

# Required status checks are matched by NAME (the `main branch protection` ruleset
# lists `Test (macos-latest)` and `Test (ubuntu-latest)`). For a docs-only change CI
# skips the heavy jobs, and a skipped job counts as passed - EXCEPT a skipped matrix
# job: GitHub records one check literally named `Test (${{ matrix.os }})`, the
# per-OS names are never created, and the PR can never merge. The first
# changelog-only PR (#243) hit exactly this: BLOCKED with every check green.
#
# So every matrix job gated on `needs.changes.outputs.heavy == 'true'` must have a
# companion job with the SAME name and OS list that runs in the opposite case and
# creates the per-OS names. This reads .github/workflows/ci.yml and holds the pair
# together, so editing one half (a new OS, a renamed job) cannot silently
# reintroduce the deadlock.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

ci="$repo_root/.github/workflows/ci.yml"
[ -f "$ci" ] || { fail "$ci missing"; finish; }

# One line per job: key <TAB> name <TAB> if <TAB> matrix os list.
jobs_tsv() {
    awk '
        /^jobs:/ { injobs = 1; next }
        injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            if (key != "") print key "\t" name "\t" cond "\t" os
            key = $1; sub(/:$/, "", key); name = ""; cond = ""; os = ""; next
        }
        injobs && /^    name:/ { sub(/^    name:[[:space:]]*/, ""); name = $0 }
        injobs && /^    if:/ { sub(/^    if:[[:space:]]*/, ""); cond = $0 }
        injobs && /^        os:/ { sub(/^        os:[[:space:]]*/, ""); os = $0 }
        END { if (key != "") print key "\t" name "\t" cond "\t" os }
    ' "$1"
}

tsv="$(jobs_tsv "$ci")"
run_cond="needs.changes.outputs.heavy == 'true'"
skip_cond="needs.changes.outputs.heavy != 'true'"

gated=0
while IFS=$'\t' read -r key name cond os; do
    [ -n "$key" ] || continue
    case "$name" in *'${{ matrix.'*) ;; *) continue ;; esac
    [ "$cond" = "$run_cond" ] || continue
    gated=$((gated + 1))
    found=''
    while IFS=$'\t' read -r key2 name2 cond2 os2; do
        [ "$key2" != "$key" ] || continue
        if [ "$name2" = "$name" ] && [ "$cond2" = "$skip_cond" ]; then
            found=1
            if [ "$os2" = "$os" ]; then pass; else
                fail "job '$key2' must list the same matrix OSes as '$key' ($os), found: $os2"
            fi
        fi
    done <<<"$tsv"
    [ -n "$found" ] ||
        fail "matrix job '$key' ($name) is skipped on docs-only changes, which leaves the per-OS check names uncreated and the PR unmergeable: add a job named '$name' with 'if: $skip_cond' and the same matrix"
done <<<"$tsv"

[ "$gated" -gt 0 ] || fail "found no matrix job gated on heavy == 'true' in ci.yml: the parser no longer matches the workflow, or the gating moved"

finish
