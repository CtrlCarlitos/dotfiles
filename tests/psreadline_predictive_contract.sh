#!/usr/bin/env bash
set -euo pipefail

# Predictive IntelliSense (the greyed-out suggestion typed from command history) contract.
#
# pwsh 7.2+ ships PSReadLine >=2.2 and turns PredictionSource on by default; Windows PowerShell
# 5.1 bundles the ancient 2.0.0 forever and never gets it without two parts, both exercised here:
#   - the installer's $core block installs a modern PSReadLine into the user's own module path
#     (Install-Module -Scope CurrentUser - no elevation; 5.1's console host auto-loads the
#     newest available version in preference to the bundled one, verified directly 2026-10-24),
#     skipping the network round-trip once that is already true (idempotent, like every other
#     upgrade check in this installer);
#   - Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1 then asks
#     Set-PSReadLineOption for it, guarded for an old/absent PSReadLine and wrapped in try/catch
#     for a host without virtual-terminal support.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
profile="$repo_root/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"

. "$repo_root/tests/lib.sh"

# 1. Wiring: the installer's $core block carries the install step, and the profile carries the
#    opt-in Set-PSReadLineOption call, each guarded.
awk '/^\{\{- if \$core \}\}/{f=1} f{print} f&&/^\{\{- end \}\}/{exit}' "$tmpl" | grep -Fq "Install-Module -Name PSReadLine -Scope CurrentUser" ||
    fail "$tmpl: the \$core block must install a modern PSReadLine (-Scope CurrentUser)"
grep -Fq "lt [version]'2.2.0'" "$tmpl" || fail "$tmpl: must skip the install once PSReadLine is already >=2.2.0"
grep -Fq 'Set-PSReadLineOption -PredictionSource History' "$profile" || fail "$profile: must set PredictionSource"
grep -Fq "ge [version]'2.2.0'" "$profile" || fail "$profile: must guard on a modern PSReadLine before calling it"
pass

command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (executed part needs PowerShell): pwsh not installed\n'; finish; exit 0; }

# 2. Executed: the extracted install-step logic, against a PSReadLine that is and is not modern
#    enough, by shadowing Get-Module - no real module is installed or touched.
install_step="$(awk '/^\$psReadLine = Get-Module -ListAvailable PSReadLine/{f=1} f{print} f&&/^\}$/{exit}' "$tmpl")"
[ -n "$install_step" ] || fail "$tmpl: could not locate the PSReadLine install-step logic"

harness="$(mktemp -d)"
printf '%s\n' "$install_step" >"$harness/step.ps1"
cat >"$harness/run.ps1" <<'PSEOF'
param([string]$FakeVersion, [string]$StepFile)
function Get-Module {
    param([switch]$ListAvailable, [string]$Name)
    if ($ListAvailable -and $FakeVersion) { [pscustomobject]@{ Version = [version]$FakeVersion } }
}
function Install-Module { Write-Output 'INSTALL-MODULE-CALLED' }
function Install-PackageProvider { Write-Output 'INSTALL-PACKAGEPROVIDER-CALLED' }
function Get-PackageProvider { $null }
. $StepFile
PSEOF
old_out="$(pwsh -NoProfile -File "$harness/run.ps1" -FakeVersion '2.0.0' -StepFile "$harness/step.ps1" 2>&1)"
case "$old_out" in
    *'INSTALL-MODULE-CALLED'*) pass ;;
    *) fail "an old (2.0.0) PSReadLine must trigger Install-Module (got: $old_out)" ;;
esac
new_out="$(pwsh -NoProfile -File "$harness/run.ps1" -FakeVersion '2.4.5' -StepFile "$harness/step.ps1" 2>&1)"
case "$new_out" in
    *'INSTALL-MODULE-CALLED'*) fail "an already-modern (2.4.5) PSReadLine must not reinstall (got: $new_out)" ;;
    *) pass ;;
esac
rm -rf "$harness"

finish
