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

# Keep the ruleset's historical check name while avoiding macos-latest's constrained
# ARM64 pool. The full-install workflow has no required check-name compatibility to
# preserve, so it can name the Intel runner directly.
grep -Fq "runs-on: \${{ matrix.os == 'macos-latest' && 'macos-15-intel' || matrix.os }}" "$ci" ||
    fail "test-unix must route the macos-latest check name to macos-15-intel"
grep -Fq 'runs-on: macos-15-intel' "$repo_root/.github/workflows/full-install-test.yml" ||
    fail "full-install-macos must use macos-15-intel"

mac_verify_has_user_path() {
    local workflow="$1" verify
    verify="$(awk '
        /^  full-install-macos:/ { in_job = 1; next }
        in_job && /^  [A-Za-z0-9_-]+:/ { exit }
        in_job && /^      - name: Verify real installs landed$/ { in_step = 1; next }
        in_step && /^      - / { exit }
        in_step && /^        run: \|$/ { in_run = 1; next }
        in_run { print }
    ' "$workflow")"
    case "$verify" in
        *'export PATH="$HOME/.local/bin:$PATH"'*'for cmd in git chezmoi'*) return 0 ;;
        *) return 1 ;;
    esac
}

if mac_verify_has_user_path "$repo_root/.github/workflows/full-install-test.yml"; then
    pass
else
    fail "full-install-macos must add user-local binaries to PATH inside its verification step"
fi

wrong_step="$_lib_state/full-install-path-in-wrong-step.yml"
awk '
    /export PATH="\$HOME\/.local\/bin:\$PATH"/ { next }
    /^      - name: Verify real installs landed$/ {
        print "      - name: Export user PATH in the wrong step"
        print "        run: export PATH=\"$HOME/.local/bin:$PATH\""
    }
    { print }
' "$repo_root/.github/workflows/full-install-test.yml" > "$wrong_step"
if mac_verify_has_user_path "$wrong_step"; then
    fail "the PATH contract must reject an export outside the verification step"
else
    pass
fi

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
