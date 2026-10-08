#!/usr/bin/env bash
set -euo pipefail

# `dot upgrade` desktop-shortcut cleanup: the config template must emit the
# [data.upgrade] table when it is set (and survive `chezmoi init`), and
# dotupgrade.ps1 must snapshot before the sweeps and delete only NEW shortcuts
# after them. `dot up`'s installer and migrate-to-winget run installers too
# (Geany, OBS, ShareX, Termius and Handy all left shortcuts that way,
# 2026-10-07), so they snapshot and clean up the same way. Behavior of the
# helpers: tests/desktop_shortcuts.ps1.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

upgrade="$repo_root/scripts/dotupgrade.ps1"
common="$repo_root/scripts/lib/ps-common.ps1"
shortcuts="$repo_root/scripts/lib/ps-desktop-shortcuts.ps1"
installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
migrate="$repo_root/scripts/migrate-to-winget.ps1"
tmpl="$repo_root/.chezmoi.toml.tmpl"

require "$upgrade" 'Test-DesktopShortcutsDisabled'
require "$upgrade" 'Get-DesktopShortcut'
require "$upgrade" 'Remove-NewDesktopShortcut'
require "$shortcuts" 'function Test-DesktopShortcutsDisabled'
require "$shortcuts" 'function Get-DesktopShortcut'
require "$shortcuts" 'function Remove-NewDesktopShortcut'
require "$common" "ps-desktop-shortcuts.ps1"
require "$installer" '{{ include "scripts/lib/ps-desktop-shortcuts.ps1" }}'

# The installer and the migration: snapshot before their first install, clean up after the last.
line_of() { grep -nF -- "$2" "$1" | head -n1 | cut -d: -f1; }
check_order() { # $1 = file, $2 = label, $3 = first install marker, $4 = last install marker
    local snap first last clean
    snap="$(line_of "$1" '$shortcutsBefore = @(Get-DesktopShortcut)')"
    first="$(line_of "$1" "$3")"
    last="$(grep -nF -- "$4" "$1" | tail -n1 | cut -d: -f1)"
    clean="$(line_of "$1" 'Remove-NewDesktopShortcut -Before $shortcutsBefore')"
    if [ -z "$snap" ] || [ -z "$first" ] || [ -z "$last" ] || [ -z "$clean" ]; then
        fail "$2: could not locate the snapshot, install and cleanup lines"
        return
    fi
    [ "$snap" -lt "$first" ] || fail "$2: the shortcut snapshot must precede the first install"
    [ "$clean" -gt "$last" ] || fail "$2: the shortcut cleanup must follow the last install"
}
check_order "$installer" 'dot up installer' 'winget install' 'winget install'
check_order "$migrate" 'migrate-to-winget' 'Invoke-WingetMigrationItem -Item' 'Invoke-WingetMigrationItem -Item'
installer_done="$(line_of "$installer" 'Write-Host "Package installation complete!"')"
installer_clean="$(line_of "$installer" 'Remove-NewDesktopShortcut -Before $shortcutsBefore')"
if [ -z "$installer_done" ] || [ -z "$installer_clean" ] || [ "$installer_clean" -gt "$installer_done" ]; then
    fail 'dot up installer: the shortcut cleanup must come before "Package installation complete!"'
fi

# Order matters: snapshot before the first sweep, cleanup after the last.
snapshot_line="$(grep -n 'Get-DesktopShortcut)' "$upgrade" | head -n1 | cut -d: -f1)"
choco_line="$(grep -n '^    \$null = Invoke-ChocoUpgradeAll' "$upgrade" | head -n1 | cut -d: -f1)"
ai_line="$(grep -n "update_ai_tools.ps1')" "$upgrade" | head -n1 | cut -d: -f1)"
cleanup_line="$(grep -n 'Remove-NewDesktopShortcut -Before' "$upgrade" | head -n1 | cut -d: -f1)"
if [ -z "$snapshot_line" ] || [ -z "$choco_line" ] || [ -z "$ai_line" ] || [ -z "$cleanup_line" ]; then
    fail 'could not locate the snapshot, sweep, and cleanup lines in dotupgrade.ps1'
else
    [ "$snapshot_line" -lt "$choco_line" ] || fail 'the shortcut snapshot must precede the choco sweep'
    [ "$cleanup_line" -gt "$ai_line" ] || fail 'the shortcut cleanup must follow the last sweep'
fi

# The template: a set value is re-emitted, an unset one leaves only a comment,
# and only Windows carries [data.upgrade] at all. The OS is forced through
# --override-data so the verdict does not depend on the runner.
empty_config="$(mktemp -d)/empty.toml"
: > "$empty_config"
render_init() { # $1 = --override-data JSON
    CI=1 chezmoi execute-template --init --config "$empty_config" --source "$repo_root" \
        --override-data "$1" < "$tmpl"
}
win='"chezmoi":{"os":"windows"}'
lin='"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}}'

set_out="$(render_init "{$win,\"upgrade\":{\"desktop_shortcuts\":false}}")"
printf '%s\n' "$set_out" | grep -Eq '^[[:space:]]*\[data\.upgrade\]$' ||
    fail 'windows: config template dropped [data.upgrade] when desktop_shortcuts is set'
printf '%s\n' "$set_out" | grep -Eq '^[[:space:]]*desktop_shortcuts = false$' ||
    fail 'windows: config template dropped desktop_shortcuts = false'
unset_out="$(render_init "{$win}")"
if printf '%s\n' "$unset_out" | grep -Eq '^[[:space:]]*\[data\.upgrade\]$'; then
    fail 'windows: config template emitted a live [data.upgrade] with no setting'
fi
printf '%s\n' "$unset_out" | grep -Fq '# [data.upgrade]' ||
    fail 'windows: config template lost the commented [data.upgrade] example'
lin_out="$(render_init "{$lin,\"upgrade\":{\"desktop_shortcuts\":false}}")"
if printf '%s\n' "$lin_out" | grep -Fq 'data.upgrade'; then
    fail 'linux: [data.upgrade] must be Windows-only (neither live nor commented)'
fi

finish
