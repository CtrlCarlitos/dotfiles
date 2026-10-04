#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # fake npm/info/vars are used by the eval-ed installer function
set -euo pipefail

# `npm install -g npm@latest` ran on every install run even when npm was already the
# latest: 8-40s (Windows) / 3-15s (Linux) for a no-op, on every `dot upgrade`. The
# installers now ask the registry first (`npm view npm version`) and install only when
# the answer differs from the installed `npm -v`. When the registry cannot be reached
# the answer is empty and the install is attempted as before (never skipped on doubt).
# Still once per run. Both twins (invariant #10) are rendered from the real templates
# and the upgrade function of each is EXECUTED against a fake npm:
#   a. current  (-v == view)  -> no install
#   b. stale    (-v != view)  -> exactly one install, even when called twice
#   c. offline  (view empty)  -> one install attempt
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

groups='"core":true,"modern_cli":true,"fonts":true,"agent_toolkit":true,"opencode_cli":true,"opencode_desktop":false,"claude_cli":true,"claude_desktop":false,"chatgpt_cli":true,"chatgpt_desktop":false,"antigravity_cli":true,"antigravity_desktop":false,"remote_access":false,"remote_access_server":false,"guardrail":false,"dev_desktop":false,"vscode_settings":false'
data() { printf '{"chezmoi":{"os":"%s","kernel":{"osrelease":"6.8.0-generic"}},"packages":{%s},"accounts":[]}' "$1" "$groups"; }
render --override-data "$(data linux)" <"$repo_root/run_onchange_install_packages.sh.tmpl" >"$tmp/install.sh"
render --override-data "$(data windows)" <"$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/install.ps1"
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# --- bash twin -----------------------------------------------------------------------------
awk '/^npm_upgrade_once\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$tmp/install.sh" >"$tmp/fn.sh"
[ -s "$tmp/fn.sh" ] || fail "npm_upgrade_once() not found in the rendered shell installer"

sh_installs() { # $1 = latest the registry reports ("" = unreachable); prints the install count after TWO calls
    (
        calls="$tmp/sh.calls"; : >"$calls"; fake_registry="$1"; npm_sudo=""; NPM_UPGRADED=""
        info() { :; }
        npm() {
            case "$1" in
                -v) echo 10.9.0 ;;
                view) [ -n "$fake_registry" ] && echo "$fake_registry" || return 1 ;;
                install) echo install >>"$calls" ;;
            esac
        }
        eval "$(cat "$tmp/fn.sh")"
        npm_upgrade_once; npm_upgrade_once
        grep -c install "$calls" || true
    )
}
[ "$(sh_installs 10.9.0)" = 0 ] || fail "bash: npm already current - no install expected"
[ "$(sh_installs 11.0.0)" = 1 ] || fail "bash: stale npm - exactly one install expected across two calls"
[ "$(sh_installs '')" = 1 ] || fail "bash: registry unreachable - one install attempt expected"

# --- PowerShell twin -----------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    tr -d '\r' <"$tmp/install.ps1" | awk '/^function Update-NpmOnce \{/{f=1} f{print} f && /^\}$/{exit}' >"$tmp/fn.ps1"
    [ -s "$tmp/fn.ps1" ] || fail "Update-NpmOnce not found in the rendered PowerShell installer"
    ps_installs() {
        {
            printf '%s\n' 'Set-StrictMode -Version Latest' '$ErrorActionPreference = "Stop"' "\$global:latest = '$1'" '$global:installs = 0' '$script:NpmUpgraded = $false'
            printf '%s\n' 'function Invoke-Quietly { param([string]$Description, [scriptblock]$Action) & $Action }'
            printf '%s\n' 'function npm { if ($args[0] -eq "-v") { "10.9.0" } elseif ($args[0] -eq "view") { if ($global:latest) { $global:latest } } elseif ($args[0] -eq "install") { $global:installs++ } }'
            cat "$tmp/fn.ps1"
            printf '%s\n' 'Update-NpmOnce | Out-Null; Update-NpmOnce | Out-Null' 'Write-Output "installs=$global:installs"'
        } >"$tmp/run.ps1"
        pwsh -NoProfile -File "$(winpath "$tmp/run.ps1")" 2>&1 | tr -d '\r' | grep -o 'installs=[0-9]*' | tail -1
    }
    [ "$(ps_installs 10.9.0)" = installs=0 ] || fail "PowerShell: npm already current - no install expected"
    [ "$(ps_installs 11.0.0)" = installs=1 ] || fail "PowerShell: stale npm - exactly one install expected across two calls"
    [ "$(ps_installs '')" = installs=1 ] || fail "PowerShell: registry unreachable - one install attempt expected"
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

finish
