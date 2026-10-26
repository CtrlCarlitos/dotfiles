#!/usr/bin/env bash
set -euo pipefail

# Chocolatey's setup (chocolateysetup.psm1 Add-ChocolateyProfile, run by the bootstrap AND by
# every `choco upgrade chocolatey`) appends its eager tab-completion block to the running host's
# $PROFILE unless that file already contains the literal string '$ChocolateyProfile'
# (Select-String -SimpleMatch). Both profiles ship a lazy equivalent instead; without that
# token Chocolatey appended its block right after chezmoi wrote the profile, and the next
# `dot up` stopped on "Microsoft.PowerShell_profile.ps1 has changed since chezmoi last wrote
# it? diff/overwrite/all-overwrite/skip/quit" (LAB-DOT-WIN-HOM #434 Run 6, 2026-10-24).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
profiles=(
    "$repo_root/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"
    "$repo_root/Documents/PowerShell/Microsoft.PowerShell_profile.ps1"
)

. "$repo_root/tests/lib.sh"

# 1. Static: Chocolatey's own search key is present (a fixed-string match, exactly as it checks).
for p in "${profiles[@]}"; do
    # shellcheck disable=SC2016 # the literal $ChocolateyProfile is the point
    if grep -Fq -- '$ChocolateyProfile' "$p"; then pass; else
        fail "$p: must contain the literal \$ChocolateyProfile, or Chocolatey's setup appends its eager block"
    fi
done

command -v pwsh >/dev/null 2>&1 || skip 'executed part needs PowerShell: pwsh not installed'

# 2. Executed: the lazy block still defines the choco shim against a fake ChocolateyInstall, and
#    Chocolatey's check (Select-String -SimpleMatch) reports the profile as already set up.
to_native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
harness="$(mktemp -d)"
trap 'rm -rf "$harness"' EXIT
mkdir -p "$harness/choco/helpers"
: >"$harness/choco/helpers/chocolateyProfile.psm1"
for p in "${profiles[@]}"; do
    block="$(tr -d '\r' <"$p" | awk '/^# Chocolatey - lazy on purpose/{f=1} f&&/^# Aliases & Modern Tools/{exit} f{print}')"
    [ -n "$block" ] || { fail "$p: could not locate the lazy Chocolatey block"; continue; }
    printf '%s\n' "$block" >"$harness/block.ps1"
    cat >"$harness/run.ps1" <<'PSEOF'
param([string]$Dir, [string]$ProfilePath)
$env:ChocolateyInstall = Join-Path $Dir 'choco'
. (Join-Path $Dir 'block.ps1')
if (Test-Path function:choco) { 'SHIM=yes' } else { 'SHIM=no' }
if (Select-String -Path $ProfilePath -Pattern '$ChocolateyProfile' -Quiet -SimpleMatch) { 'CHOCO-SEES-PROFILE=yes' } else { 'CHOCO-SEES-PROFILE=no' }
PSEOF
    out="$(pwsh -NoProfile -NonInteractive -File "$(to_native "$harness/run.ps1")" -Dir "$(to_native "$harness")" -ProfilePath "$(to_native "$p")" 2>&1 || true)"
    case "$out" in *'SHIM=yes'*) pass ;; *) fail "$p: the lazy block must still define the choco shim (got: $out)" ;; esac
    case "$out" in *'CHOCO-SEES-PROFILE=yes'*) pass ;; *) fail "$p: Chocolatey's -SimpleMatch check must find its key (got: $out)" ;; esac
done

finish
