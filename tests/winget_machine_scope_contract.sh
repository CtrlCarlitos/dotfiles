#!/usr/bin/env bash
set -euo pipefail

# Found in a live `dot upgrade` (2026-10-10): gum was installed per-user, `dot upgrade` runs
# elevated, and winget refuses to upgrade a per-user package from an elevated shell ("The package
# installed for user scope cannot be uninstalled when running with administrator privileges"),
# so gum stayed pending on every run. gum is now installed machine-wide, and a per-user copy is
# reported with its one-time fix.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

yaml="$repo_root/.chezmoidata/packages.yaml"
awk '/^    - id: gum$/{f=1; next} /^    - id:/{f=0} f && /winget_args: "--scope machine"/{found=1} END{exit !found}' "$yaml" ||
    fail "the gum catalog record must carry winget_args: \"--scope machine\""
pass

installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
grep -Fq 'installed per-user but the catalog keeps it machine-wide' "$installer" ||
    fail "installer: a per-user copy of a machine-scope package must be reported"
grep -Fq 'winget uninstall --id $wingetId --exact' "$installer" ||
    fail "installer: the per-user report must give the one-time fix"
grep -Fq 'installed for user scope cannot be uninstalled when running with administrator' "$repo_root/scripts/lib/ps-common.ps1" ||
    fail "the winget sweep must recognise the elevated per-user failure"
pass

finish
