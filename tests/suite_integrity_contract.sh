#!/usr/bin/env bash
set -uo pipefail

# The suite watching itself. Every check here exists because the thing it
# checks actually went wrong, and in each case CI stayed green while it did.
#
#   1. WIRED      seven test files were never referenced in ci.yml and had
#                 therefore never run once. This is also what hid the
#                 mis-spliced agent_skill_wiring_contract.sh, whose functions
#                 were nested inside others and never defined: bash fails
#                 loudly on an undefined function, so that file was not
#                 tolerated by CI, it was simply never executed by it.
#
#   2. COMPLETED  every test announces its own end with a PASS/SKIP line. A
#                 test that exits 0 without one returned early - the assertions
#                 below that point never ran, and an early `exit 0` is
#                 indistinguishable from success by exit code alone.
#
#   3. NO SKIPS   a test that declines to run looks exactly like a passing one.
#                 `bash tests/*.sh` on Windows reports "33 passed" while 4 of
#                 those skip outright, and that number was once reported as
#                 evidence a branch was ready. Skips are legitimate where the
#                 tooling genuinely is absent (POSIX modes and gum under Git
#                 Bash); on a Linux runner with everything installed they mean
#                 a guard is too broad or a job is missing a package.
#
# Part 3 runs the other tests, so it must never run itself - see $self.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ci="$repo_root/.github/workflows/ci.yml"
self="$(basename -- "${BASH_SOURCE[0]}")"
failures=0

fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# Windows lacks POSIX modes, gum, and the .sh twins' dependencies, so skips
# there are expected. Everywhere else a skip is a defect.
strict=true
case "${OSTYPE:-}" in
    msys* | cygwin* | win32) strict=false ;;
esac
[ "${TESTS_STRICT:-}" = 0 ] && strict=false
[ "${TESTS_STRICT:-}" = 1 ] && strict=true

#-------------------------------------------------------------------------------
# 1. Every test file is referenced by the workflow meant to run it.
#-------------------------------------------------------------------------------
[ -f "$ci" ] || { printf 'FAIL: %s missing\n' "$ci" >&2; exit 1; }

unwired=0
for f in "$repo_root"/tests/*.sh "$repo_root"/tests/*.ps1; do
    [ -e "$f" ] || continue
    base="$(basename -- "$f")"
    grep -Fq -- "tests/$base" "$ci" ||
        { fail "tests/$base is not referenced in ci.yml - it would never run"; unwired=$((unwired + 1)); }
done
[ "$unwired" -eq 0 ] && printf '  ok: every test file is wired into ci.yml\n'

#-------------------------------------------------------------------------------
# 2 + 3. Run the suite; account for every test as passed, skipped or failed,
#        and require each to have announced its own completion.
#-------------------------------------------------------------------------------
passed=0; skipped=0; failed=0; skipped_names=""; silent_names=""
for f in "$repo_root"/tests/*.sh; do
    [ -e "$f" ] || continue
    base="$(basename -- "$f")"
    [ "$base" = "$self" ] && continue

    out="$(bash "$f" 2>&1)"; rc=$?

    if [ "$rc" -ne 0 ]; then
        failed=$((failed + 1))
        printf 'FAIL: %s exited %d\n' "$base" "$rc" >&2
        printf '%s\n' "$out" | tail -3 >&2
        continue
    fi

    # A completion marker proves the file reached its end rather than
    # returning early from somewhere in the middle.
    printf '%s' "$out" | grep -Eq '^(PASS|SKIP|PASS/SKIP):' ||
        silent_names="$silent_names $base"

    if printf '%s' "$out" | grep -Eq '(^|[^A-Za-z])SKIP:'; then
        skipped=$((skipped + 1))
        skipped_names="$skipped_names $base"
    else
        passed=$((passed + 1))
    fi
done

printf '  suite: %d passed, %d skipped, %d failed\n' "$passed" "$skipped" "$failed"
[ -n "$skipped_names" ] && printf '  skipped:%s\n' "$skipped_names"

[ "$failed" -eq 0 ] || fail "$failed test(s) failed - see above"

[ -z "$silent_names" ] ||
    fail "test(s) exited 0 without a PASS/SKIP completion line:$silent_names
      End the file with one (e.g. printf 'PASS: <what held>\\n'). Without it an
      early 'exit 0' is indistinguishable from a full, successful run."

if [ "$skipped" -gt 0 ] && [ "$strict" = true ]; then
    fail "$skipped test(s) skipped on a platform that should run all of them.
      A skip is not a pass. Either this job is missing the tooling the test
      needs (install it in ci.yml) or the guard is too broad (narrow it).
      TESTS_STRICT=0 inspects locally without failing."
fi

if [ "$failures" -gt 0 ]; then
    printf '\nFAIL: suite integrity (%d problem(s))\n' "$failures" >&2
    exit 1
fi
printf 'PASS: suite integrity - all tests wired, all completed, none silently skipped\n'
