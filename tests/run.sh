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

# Bound individual tests and identify the running test before capturing output.
# GNU timeout is coreutils on Linux/Git Bash and gtimeout on Homebrew macOS.
test_timeout="${TEST_TIMEOUT_SECONDS:-180}"
if ! [[ "$test_timeout" =~ ^[1-9][0-9]*$ ]]; then
    printf 'TEST_TIMEOUT_SECONDS must be a positive integer\n' >&2
    exit 2
fi
test_command=(bash --)
for timer in timeout gtimeout; do
    if command -v "$timer" >/dev/null 2>&1 && "$timer" --version 2>/dev/null | grep -q 'GNU coreutils'; then
        test_command=("$timer" -k 5s "$test_timeout" bash --)
        break
    fi
done
if [ "${#test_command[@]}" -eq 2 ]; then
    printf 'warning: GNU timeout unavailable; per-test time limits disabled\n' >&2
fi

# The operator's own state must survive the suite. A test that rewrote the real
# skills-sources made the next `dot up` reinstall every skill (2026-10-06); each
# test is checked against a snapshot, failed if it touched the file, and the
# file is put back.
real_state="$HOME/.local/state/dotfiles/skills-sources"
state_snapshot=""
if [ -f "$real_state" ]; then
    state_snapshot="$(mktemp)"
    cp -p "$real_state" "$state_snapshot"
fi
state_changed() {
    if [ -n "$state_snapshot" ]; then
        ! cmp -s "$real_state" "$state_snapshot"
    else
        [ -e "$real_state" ]
    fi
}
state_restore() {
    if [ -n "$state_snapshot" ]; then cp -p "$state_snapshot" "$real_state"; else rm -f "$real_state"; fi
}

shopt -s nullglob
for f in "$tests_dir"/*.sh; do
    base="$(basename -- "$f")"
    [ "$base" = "run.sh" ] && continue
    [ "$base" = "lib.sh" ] && continue

    printf 'RUN  %s\n' "$base"
    started=$SECONDS
    out="$("${test_command[@]}" "$f" 2>&1)"
    rc=$?
    if state_changed; then
        state_restore
        failed=$((failed + 1))
        printf 'FAIL %s (wrote the real %s; restored)\n' "$base" "$real_state"
        continue
    fi

    if [ "$rc" -ne 0 ]; then
        failed=$((failed + 1))
        printf 'FAIL %s (exit %d)\n' "$base" "$rc"
        if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
            printf '    test exceeded its %ss budget or was killed\n' "$test_timeout"
        fi
        printf '%s\n' "$out" | tail -200 | sed 's/^/    /'
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
        printf 'ok   %s (%ss)\n' "$base" "$((SECONDS - started))"
    fi
done

if [ -n "$state_snapshot" ]; then rm -f "$state_snapshot"; fi
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
