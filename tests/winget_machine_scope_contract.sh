#!/usr/bin/env bash
set -euo pipefail

# Found in a live `dot upgrade` (2026-10-10): gum was installed per-user, `dot upgrade` runs
# elevated, and winget refuses to upgrade a per-user package from an elevated shell ("The package
# installed for user scope cannot be uninstalled when running with administrator privileges"),
# so gum stayed pending on every run. gum is now installed machine-wide, and a per-user copy is
# reported with its one-time fix.
#
# 2026-10-11: `winget show` confirmed the SAME root cause (winget's "portable" installer type
# defaults to user scope) for every other catalog CLI tool found sitting in the per-user WinGet
# packages folder on a real machine - 27 more ids, listed below, plus chezmoi (install.ps1, not
# in the catalog) and scrcpy (installed directly in the mobile_dev block, also not in the
# catalog). All three install.ps1/scrcpy/the catalog loop now default to --scope machine, made
# safe because install.ps1 and run_onchange_install_packages.ps1.tmpl both hard-require admin
# (tests/migrate_to_winget_contract.sh, tests/windows_elevation_contract.sh).
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

yaml="$repo_root/.chezmoidata/packages.yaml"
check_scope() {
    local id="$1"
    awk -v id="    - id: $id\$" '$0 ~ id {f=1; next} /^    - id:/{f=0} f && /winget_args: "--scope machine"/{found=1} END{exit !found}' "$yaml" ||
        fail "the $id catalog record must carry winget_args: \"--scope machine\""
}
for id in gum powershell-core vscode \
    curl wget jq fzf ripgrep ffmpeg terraform mkcert psmux \
    bat less eza fd delta zoxide direnv lazygit tealdeer dust duf procs shellcheck shfmt lychee pstop \
    act opencode-cli; do
    check_scope "$id"
done
pass

# chezmoi (install.ps1, not in the catalog) and scrcpy (the mobile_dev block, also not in the
# catalog) need the same fix applied directly to their own winget install calls.
grep -Eq "wingetFlags = @\('--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity', '--scope', 'machine'\)" "$repo_root/install.ps1" ||
    fail "install.ps1: chezmoi must install machine-wide"
grep -Fq 'winget install --exact --id Genymobile.scrcpy --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --scope machine' "$repo_root/run_onchange_install_packages.ps1.tmpl" ||
    fail "installer: scrcpy must install machine-wide"
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
