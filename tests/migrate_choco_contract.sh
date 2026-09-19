#!/usr/bin/env bash
set -euo pipefail

# migrate-to-choco contract: the opt-in takeover script for apps installed
# outside Chocolatey (the installer's "Skipping X - already installed (not
# via Chocolatey)" set). Hard rules from the live design discussion:
#   - NEVER automatic: per-app confirmation, plus a typed guard for the
#     high-risk app (tailscale = live VPN)
#   - elevation gate before any work (-ListOnly exempt)
#   - package universe stays in sync with the installer's choco lists
#     (marker line on both sides)
#   - the installer points affected users at the script

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/migrate-to-choco.ps1"
installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
ci_workflow="$repo_root/.github/workflows/ci.yml"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$script" ] || fail "scripts/migrate-to-choco.ps1 missing"

grep -Fq 'WindowsBuiltInRole]::Administrator' "$script" ||
    fail "script: no elevation gate"
grep -Fq 'Read-Host' "$script" || fail "script: no per-app confirmation"
grep -Fq 'Type "tailscale" to confirm' "$script" ||
    fail "script: no typed guard for the live-VPN app"
grep -Fq 'choco install' "$script" || fail "script: does not reinstall via choco"
grep -Fq 'ListOnly' "$script" || fail "script: no -ListOnly detection-only mode"

# Universe sync: both sides carry the marker.
grep -Fq 'MIGRATE-UNIVERSE-MARKER' "$script" || fail "script: universe marker missing"
grep -Fq 'MIGRATE-UNIVERSE-MARKER' "$installer" || fail "installer: universe marker missing"
for pkg in tailscale gsudo pstop handy tree; do
    grep -Fq "'$pkg'" "$script" || fail "script: universe lost '$pkg'"
done

# Installer advisory: skips must funnel the user to the script.
grep -Fq 'skippedNotChoco' "$installer" || fail "installer: skip collector missing"
grep -Fq 'migrate-to-choco.ps1' "$installer" || fail "installer: advisory does not name the script"

grep -Fq -- 'bash tests/migrate_choco_contract.sh' "$ci_workflow" || {
    printf 'FAIL: ci.yml: migrate-choco contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: migrate-to-choco opt-in contract\n'
