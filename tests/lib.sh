#!/usr/bin/env bash
# tests/lib.sh - shared harness for the shell tests. Source it, never run it:
#
#   source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
#
# Provides:
#   fail MSG     record a failure: prints "FAIL: MSG" to stderr and tallies it.
#   skip MSG     announce a skip ("SKIP: MSG") and exit 0 - the runner accounts
#                it as skipped. Never skip silently.
#   pass         tally a custom assertion that held (optional; keeps finish()'s
#                check count honest for tests with their own assertion helpers)
#   require F S  assert file F contains the literal string S
#   forbid F S   assert file F does not contain the literal string S
#   render ARGS  chezmoi execute-template with an empty --config (the host's
#                own config must not shape a render) and this repo as --source
#   finish       completion marker: prints "PASS (N checks)" or
#                "FAIL (N checks, M failed)" and exits 0/1 accordingly. Every
#                test ends here, or in skip().
#
# Fail-fast vs accumulating: by default fail() accumulates and finish() issues
# the verdict. A file that must stop at the first failed check sets
# TESTS_FAILFAST=1 right after sourcing; fail() then exits 1 immediately,
# exactly as its private one-line version used to.

# Underscore-prefixed on purpose: sourcing must not clobber the test's own
# repo_root or scratch variables.
_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_LIB_REPO_ROOT="$(cd -- "$_LIB_DIR/.." && pwd)"

_tests_checks=0
_tests_failed=0

pass() {
    _tests_checks=$((_tests_checks + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    _tests_checks=$((_tests_checks + 1))
    _tests_failed=$((_tests_failed + 1))
    if [ -n "${TESTS_FAILFAST:-}" ]; then
        exit 1
    fi
    return 0
}

skip() {
    _lib_cleanup
    printf 'SKIP: %s\n' "$1"
    exit 0
}

require() { # $1 = file, $2 = literal
    if grep -Fq -- "$2" "$1"; then
        pass
    else
        fail "$1: missing $2"
    fi
}

forbid() { # $1 = file, $2 = literal
    if grep -Fq -- "$2" "$1"; then
        fail "$1: must not contain $2"
    else
        pass
    fi
}

render() {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    # The config must carry a .toml extension: chezmoi infers the config type
    # from the filename, so --config /dev/null fails as an unsupported type.
    # The file is empty either way - the host's config must not shape a render.
    if [ -z "${_LIB_CONFIG:-}" ]; then
        _LIB_CONFIG="$(mktemp "${TMPDIR:-/tmp}/lib-empty-config-XXXXXX.toml")"
    fi
    chezmoi execute-template --config "$_LIB_CONFIG" --source "$_LIB_REPO_ROOT" "$@"
}

_lib_cleanup() {
    if [ -n "${_LIB_CONFIG:-}" ]; then
        rm -f "$_LIB_CONFIG"
        _LIB_CONFIG=""
    fi
}

finish() {
    _lib_cleanup
    if [ "$_tests_failed" -gt 0 ]; then
        printf 'FAIL (%d checks, %d failed)\n' "$_tests_checks" "$_tests_failed"
        exit 1
    fi
    printf 'PASS (%d checks)\n' "$_tests_checks"
    exit 0
}
