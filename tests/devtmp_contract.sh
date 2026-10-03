#!/usr/bin/env bash
set -euo pipefail

# `dot devtmp` contract (issue #227): the config template must emit
# [data.devtmp] on Windows only and survive `chezmoi init`; the script must
# never EXECUTE a Defender change; both PowerShell profiles carry the arm.
# Behavior of the helpers and of Invoke-DevTmp: tests/devtmp.ps1.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmpl="$repo_root/.chezmoi.toml.tmpl"

# --- template: set value re-emitted, unset value = comment only, Windows only.
# The OS is forced through --override-data so the verdict does not depend on
# the runner (same idiom as tests/dotupgrade_desktop_shortcuts_contract.sh).
empty_config="$(mktemp -d)/empty.toml"
: > "$empty_config"
render_init() { # $1 = --override-data JSON
    CI=1 chezmoi execute-template --init --config "$empty_config" --source "$repo_root" \
        --override-data "$1" < "$tmpl"
}
win='"chezmoi":{"os":"windows"}'
lin='"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}}'

set_out="$(render_init "{$win,\"devtmp\":{\"path\":\"C:/dev/tmp\"}}")"
printf '%s\n' "$set_out" | grep -Eq '^[[:space:]]*\[data\.devtmp\]$' ||
    fail 'windows: config template dropped [data.devtmp] when path is set'
printf '%s\n' "$set_out" | grep -Eq '^[[:space:]]*path = "C:/dev/tmp"$' ||
    fail 'windows: config template dropped path = "C:/dev/tmp"'

bs_out="$(render_init "{$win,\"devtmp\":{\"path\":\"C:\\\\dev\\\\tmp\"}}")"
printf '%s\n' "$bs_out" | grep -Eq '^[[:space:]]*path = "C:\\\\dev\\\\tmp"$' ||
    fail 'windows: a backslash path must be re-emitted as a valid TOML basic string'

unset_out="$(render_init "{$win}")"
if printf '%s\n' "$unset_out" | grep -Eq '^[[:space:]]*\[data\.devtmp\]$'; then
    fail 'windows: config template emitted a live [data.devtmp] with no path'
fi
printf '%s\n' "$unset_out" | grep -Fq '# [data.devtmp]' ||
    fail 'windows: config template lost the commented [data.devtmp] example'

empty_out="$(render_init "{$win,\"devtmp\":{\"path\":\"\"}}")"
if printf '%s\n' "$empty_out" | grep -Eq '^[[:space:]]*\[data\.devtmp\]$'; then
    fail 'windows: an empty path must not render a live [data.devtmp]'
fi

lin_out="$(render_init "{$lin,\"devtmp\":{\"path\":\"/tmp/x\"}}")"
if printf '%s\n' "$lin_out" | grep -Fq 'data.devtmp'; then
    fail 'linux: [data.devtmp] must be Windows-only (neither live nor commented)'
fi

# --- the script never EXECUTES a Defender change: Add-MpPreference exists only
# as a string assigned to $exclusionCommand and printed. (tests/devtmp.ps1 adds
# the behavioral trap: a recording Add-MpPreference that must never be called.)
script="$repo_root/scripts/devtmp.ps1"
[ -f "$script" ] || fail "$script missing"
require "$script" '$exclusionCommand = '
forbid "$script" 'Set-MpPreference'
forbid "$script" 'Remove-MpPreference'
forbid "$script" 'Invoke-Expression'
forbid "$script" '-Verb RunAs'
if grep -nE '^[[:space:]]*Add-MpPreference' "$script"; then
    fail "$script: Add-MpPreference must be printed text, never a statement"
fi
if grep -nE '[&.|;(][[:space:]]*Add-MpPreference' "$script"; then
    fail "$script: Add-MpPreference must never be invoked (call operator, dot, pipe or subexpression)"
fi

finish
