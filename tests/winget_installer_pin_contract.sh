#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# PowerShell 7 has two winget installers: the per-user MSIX (winget's default) and the machine-wide MSI.
# The catalog installs the MSI (`--scope machine --installer-type wix`) so every user of the computer
# has it. `dot upgrade` once ran a plain `winget upgrade`, was offered the MSIX, and stopped at "the
# install technology is different", leaving PowerShell on its old version for good. The upgrade now
# takes the same flags (WingetInstallerPin in scripts/lib/ps-common.ps1); this holds the two lists
# together: the catalog's winget_args for each pinned id must contain every flag of the pin.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

yaml="$repo_root/.chezmoidata/packages.yaml"
pin="$(pwsh -NoProfile -Command ". '$(winpath "$repo_root/scripts/lib/ps-common.ps1")'; (\$script:WingetInstallerPin['Microsoft.PowerShell']) -join ' '" | tr -d '\r')"
[ -n "$pin" ] || { fail "WingetInstallerPin has no entry for Microsoft.PowerShell"; finish; exit 1; }

catalog="$(awk '/^    - id: powershell-core$/ {f=1; next} /^    - id:/ {f=0} f && /winget_args:/ {sub(/^ *winget_args: *"/, ""); sub(/"$/, ""); print}' "$yaml")"
[ -n "$catalog" ] || { fail "the powershell-core catalog record has no winget_args"; finish; exit 1; }

for flag in $pin; do
    case " $catalog " in
        *" $flag "*) pass ;;
        *) fail "powershell-core winget_args (\"$catalog\") must contain '$flag' from WingetInstallerPin (\"$pin\")" ;;
    esac
done
case "$catalog" in *"--scope machine"*) pass ;; *) fail "PowerShell is installed machine-wide: winget_args must carry --scope machine" ;; esac

# `--scope machine` ALONE still selects the Store package (MSIX) for PowerShell 7.6.x (found on a fresh
# machine, 2026-10-14): a copy installed that way is "present" to the installer, so it must say what it is
# and print the one-time fix, from Windows PowerShell.
installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
require "$installer" "Get-AppxPackage -Name 'Microsoft.PowerShell'"
require "$installer" 'PowerShell 7 is the per-user Store package here'
require "$installer" 'ELEVATED Windows PowerShell (powershell.exe, not pwsh)'
finish
