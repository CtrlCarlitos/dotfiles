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

# Every test runs with its own state root. Code under test writes to
# ${XDG_STATE_HOME:-$HOME/.local/state} (shell) and $env:XDG_STATE_HOME or
# %USERPROFILE%\.local\state (PowerShell). A harness that overrode HOME but ran
# the PowerShell twin still reached the operator's real USERPROFILE: two tests
# emptied the real skills-sources and every next `dot up` reinstalled every
# skill (2026-10-06). A test that needs XDG_STATE_HOME unset unsets it itself.
# One fresh folder per test file (a shared one carried recorded state from one test into
# the next); tests/run.sh removes them at the end of the suite.
_lib_state="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tests-state.XXXXXX" 2>/dev/null)" || _lib_state="${TMPDIR:-/tmp}/dotfiles-tests-state.$$"
mkdir -p "$_lib_state" 2>/dev/null || true
if command -v cygpath >/dev/null 2>&1; then _lib_state="$(cygpath -m "$_lib_state")"; fi
export XDG_STATE_HOME="$_lib_state"

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

# seed_vscode_config FILE - write the VS Code settings a fresh machine's `chezmoi init` writes
#   ([data.vscode.settings] from .chezmoitemplates/vscode-settings.toml) into FILE. The settings
#   live in chezmoi.toml, not in .chezmoidata, so a render without them has empty tiers.
seed_vscode_config() {
    local seed_cfg
    seed_cfg="$(mktemp "${TMPDIR:-/tmp}/lib-seed-config-XXXXXX.toml")"
    chezmoi execute-template --config "$seed_cfg" --source "$_LIB_REPO_ROOT"         '{{ replace "[vscode" "[data.vscode" (toToml (dict "vscode" (dict "settings" (includeTemplate "vscode-settings.toml" . | fromToml)))) }}' >"$1"
    rm -f "$seed_cfg"
}

render() {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    # The config must carry a .toml extension: chezmoi infers the config type
    # from the filename, so --config /dev/null fails as an unsupported type.
    # It holds only the seeded VS Code settings - the host's config must not shape a render.
    if [ -z "${_LIB_CONFIG:-}" ]; then
        _LIB_CONFIG="$(mktemp "${TMPDIR:-/tmp}/lib-empty-config-XXXXXX.toml")"
        seed_vscode_config "$_LIB_CONFIG"
    fi
    chezmoi execute-template --config "$_LIB_CONFIG" --source "$_LIB_REPO_ROOT" "$@"
}

# render_to OUTFILE PLATFORM OVERRIDE_JSON
#   Render a run_onchange installer template into OUTFILE from a scratch
#   source that carries the repo's own data files, so the render never depends
#   on the host's config or cwd. PLATFORM picks the template and the chezmoi
#   OS the template gates on:
#       sh      run_onchange_install_packages.sh.tmpl   as linux
#       darwin  run_onchange_install_packages.sh.tmpl   as darwin
#       ps1     run_onchange_install_packages.ps1.tmpl  as windows
#   OVERRIDE_JSON is the "packages" document (a JSON object of group flags);
#   the chezmoi OS/kernel part is filled in here. The config carries the seeded
#   VS Code settings, as a fresh machine's has (RENDER_NO_VSCODE_SETTINGS=1: none).
render_to() { # $1 = outfile, $2 = platform, $3 = override JSON
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local out="$1" platform="$2" override="$3"
    local scratch config os_json
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/render-repo-XXXXXX")"
    config="$scratch/empty.toml"
    mkdir -p "$scratch/repo/scripts"
    cp "$_LIB_REPO_ROOT/.chezmoidata.yaml" "$scratch/repo/"
    cp -r "$_LIB_REPO_ROOT/.chezmoidata" "$_LIB_REPO_ROOT/.chezmoitemplates" "$scratch/repo/"
    if [ -d "$_LIB_REPO_ROOT/scripts/lib" ]; then
        cp -r "$_LIB_REPO_ROOT/scripts/lib" "$scratch/repo/scripts/"
    fi
    if [ -f "$_LIB_REPO_ROOT/scripts/curated-agent-skills.txt" ]; then
        cp "$_LIB_REPO_ROOT/scripts/curated-agent-skills.txt" "$scratch/repo/scripts/"
    fi
    # RENDER_NO_VSCODE_SETTINGS=1: a config from before the settings moved into chezmoi.toml
    if [ "${RENDER_NO_VSCODE_SETTINGS:-0}" = 1 ]; then
        : >"$config"
    else
        seed_vscode_config "$config"
    fi
    case "$platform" in
        sh) os_json='"os": "linux", "kernel": {"osrelease": "6.8.0-generic"}' ;;
        darwin) os_json='"os": "darwin"' ;;
        ps1) os_json='"os": "windows"' ;;
        *)
            fail "render_to: unknown platform $platform"
            return 1
            ;;
    esac
    # shellcheck disable=SC2086  # the JSON is one argument
    # .gitattributes checks *.ps1.tmpl out with CRLF on EVERY host (including
    # Linux CI), so the raw render's `}`-only lines carry a trailing CR - which
    # breaks exact-match extraction on Linux (`}\r` != `}`; msys awk hides this
    # on Windows hosts by stripping CR). Normalize once, here.
    chezmoi execute-template --config "$config" --source "$scratch/repo" \
        --override-data "{\"chezmoi\":{$os_json},\"packages\":$override}" \
        <"$_LIB_REPO_ROOT/run_onchange_install_packages.$([ "$platform" = ps1 ] && echo ps1 || echo sh).tmpl" \
        | tr -d '\r' >"$out"
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
