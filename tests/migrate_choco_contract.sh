#!/usr/bin/env bash
set -euo pipefail

# migrate-to-choco contract: the opt-in takeover script for apps installed
# outside Chocolatey (the installer's "Skipping X - already installed (not
# via Chocolatey)" set). Hard rules from the live design discussion:
#   - NEVER automatic: per-app confirmation, plus a typed guard for the
#     high-risk app (tailscale = live VPN)
#   - elevation gate before any work (-ListOnly exempt)
#   - package universe comes from .chezmoidata/packages.yaml at runtime
#     (marker line on both sides)
#   - the installer points affected users at the script

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/migrate-to-choco.ps1"
installer="$repo_root/run_onchange_install_packages.ps1.tmpl"

. "$repo_root/tests/lib.sh"

[ -f "$script" ] || fail "scripts/migrate-to-choco.ps1 missing"

grep -Fq 'WindowsBuiltInRole]::Administrator' "$script" ||
    fail "script: no elevation gate"
grep -Fq 'Read-Host' "$script" || fail "script: no per-app confirmation"
grep -Fq 'Type "tailscale" to confirm' "$script" ||
    fail "script: no typed guard for the live-VPN app"
grep -Fq 'choco install' "$script" || fail "script: does not reinstall via choco"
grep -Fq 'ListOnly' "$script" || fail "script: no -ListOnly detection-only mode"

# Universe: read from the catalog at runtime, never a list of its own. The
# old contract grepped both files for a comment marker and enforced nothing -
# the mirror had drifted to 39 of 61 packages. package_catalog_contract.sh
# checks the expression itself; this only pins that the script uses it.
grep -Fq "chezmoi execute-template '{{ .catalog.packages | toJson }}'" "$script" ||
    fail "script: does not read the package catalog through chezmoi execute-template"
# `@(` at end of line is a literal list continuing below; the runtime path's
# one-line `$Universe = @()` must not match.
# shellcheck disable=SC2016
if grep -qE '^\s*\$Universe\s*=\s*@\(\s*$' "$script"; then
    fail "script: carries its own \$Universe list again"
fi
if grep -Fq 'MIGRATE-UNIVERSE-MARKER' "$installer" "$script"; then
    fail "the MIGRATE-UNIVERSE-MARKER comment is back - it enforced nothing; the catalog is the contract"
fi
# The universe is the catalog's choco names (minus migrate: false). These
# five span core, modern_cli, dev_desktop and remote_access, so losing any
# of them from the catalog would mean a whole group had gone missing.
for pkg in tailscale gsudo pstop handy tree; do
    grep -Fq "choco: $pkg" "$repo_root/.chezmoidata/packages.yaml" ||
        fail ".chezmoidata/packages.yaml: universe lost '$pkg'"
done

# Installer advisory: skips must funnel the user to the script.
grep -Fq 'skippedNotChoco' "$installer" || fail "installer: skip collector missing"
grep -Fq 'migrate-to-choco.ps1' "$installer" || fail "installer: advisory does not name the script"
# The advisory path must be a single Windows path: CHEZMOI_SOURCE_DIR arrives
# with forward slashes, so it is normalized and joined with Join-Path, never
# concatenated with a backslash literal (printed "C:/.../chezmoi\scripts\...").
grep -Fq "Join-Path \$srcAdvisory 'scripts\migrate-to-choco.ps1'" "$installer" ||
    fail "installer: advisory must build the script path with Join-Path"
grep -Fq "CHEZMOI_SOURCE_DIR -replace '/', '" "$installer" ||
    fail "installer: advisory must normalize CHEZMOI_SOURCE_DIR slashes"
! grep -Fq '$srcAdvisory\scripts' "$installer" ||
    fail "installer: advisory must not concatenate the source dir with a backslash literal"

finish
