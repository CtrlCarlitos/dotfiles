#!/usr/bin/env bash
set -uo pipefail

# The suite's entrypoint, local and CI: enumerate tests/*.sh (this runner and
# lib.sh excluded; tests/fixtures/ is data, not tests), execute each with bash,
# and account every test as passed, skipped or failed. This absorbs
# tests/suite_integrity_contract.sh, deleted when this file landed:
#
#   wiring      was part 1 there: every test file had to be hand-referenced in
#               ci.yml, and the test checked its own wiring. Superseded - run.sh
#               runs every test because it exists, so a file cannot go unwired.
#               The tests/*.ps1 twins keep their own ci.yml steps (this is a
#               bash runner).
#   completion  kept: a test that exits 0 without announcing its end is a
#               failure. An early `exit 0` must stay distinguishable from a
#               full, successful run (lib.sh's finish()/skip() announce).
#   no skips    kept, as --strict (the default): a test that declines to run
#               looks exactly like a passing one, and on a runner with the
#               tooling installed a skip means a guard is too broad or a job is
#               missing a package. TESTS_STRICT=0 inspects locally without
#               failing; hard failures fail in both modes.

tests_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

strict=true
case "${OSTYPE:-}" in
    msys* | cygwin* | win32) strict=false ;; # no POSIX modes / gum there; .sh twins are Unix CI's business
esac
[ "${TESTS_STRICT:-}" = 0 ] && strict=false
[ "${TESTS_STRICT:-}" = 1 ] && strict=true
case "${1:-}" in
    "") ;;

    --strict) strict=true ;;

    *)
        printf 'usage: tests/run.sh [--strict]   (env: TESTS_STRICT=0 tolerates skips)\n' >&2
        exit 2
        ;;
esac

passed=0
skipped=0
failed=0
skipped_names=""
silent_names=""

shopt -s nullglob
for f in "$tests_dir"/*.sh; do
    base="$(basename -- "$f")"
    [ "$base" = "run.sh" ] && continue
    [ "$base" = "lib.sh" ] && continue

    out="$(bash -- "$f" 2>&1)"
    rc=$?

    if [ "$rc" -ne 0 ]; then
        failed=$((failed + 1))
        printf 'FAIL %s (exit %d)\n' "$base" "$rc"
        printf '%s\n' "$out" | tail -25 | sed 's/^/    /'
        continue
    fi

    # A completion marker proves the file reached its end rather than
    # returning early from somewhere in the middle.
    if ! printf '%s' "$out" | grep -Eq '^(PASS|SKIP)'; then
        failed=$((failed + 1))
        silent_names="$silent_names $base"
        printf 'FAIL %s (exited 0 without a PASS/SKIP completion line)\n' "$base"
        printf '%s\n' "$out" | tail -5 | sed 's/^/    /'
        continue
    fi

    if printf '%s' "$out" | grep -Eq '(^|[^A-Za-z])SKIP:'; then
        skipped=$((skipped + 1))
        skipped_names="$skipped_names $base"
        printf 'SKIP %s\n' "$base"
    else
        passed=$((passed + 1))
        printf 'ok   %s\n' "$base"
    fi
done

printf '\nsuite: %d passed, %d skipped, %d failed\n' "$passed" "$skipped" "$failed"
[ -n "$skipped_names" ] && printf 'skipped:%s\n' "$skipped_names"

if [ "$strict" = true ] && [ "$skipped" -gt 0 ]; then
    failed=$((failed + 1))
    printf 'FAIL: %d test(s) skipped under --strict. A skip is not a pass: either this\n' "$skipped" >&2
    printf 'machine is missing tooling the tests need (install it) or a guard is too\n' >&2
    printf 'broad (narrow it). TESTS_STRICT=0 bash tests/run.sh inspects locally.\n' >&2
fi
if [ "$strict" = false ] && [ "$skipped" -gt 0 ]; then
    printf 'note: skips tolerated (TESTS_STRICT=0) - CI runs --strict\n'
fi

if [ "$failed" -gt 0 ]; then
    printf '\nFAIL: suite (%d problem(s))\n' "$failed" >&2
    exit 1
fi
printf 'PASS: suite (%d tests)\n' "$((passed + skipped))"
