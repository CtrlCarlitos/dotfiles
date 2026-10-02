#!/usr/bin/env bash
set -euo pipefail

# `dot upgrade` desktop-shortcut cleanup: the config template must emit the
# [data.upgrade] table when it is set (and survive `chezmoi init`), and
# dotupgrade.ps1 must snapshot before the sweeps and delete only NEW shortcuts
# after them. Behavior of the helpers: tests/desktop_shortcuts.ps1.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

upgrade="$repo_root/scripts/dotupgrade.ps1"
common="$repo_root/scripts/lib/ps-common.ps1"
tmpl="$repo_root/.chezmoi.toml.tmpl"

require "$upgrade" 'Test-DesktopShortcutsDisabled'
require "$upgrade" 'Get-DesktopShortcut'
require "$upgrade" 'Remove-NewDesktopShortcut'
require "$common" 'function Test-DesktopShortcutsDisabled'
require "$common" 'function Get-DesktopShortcut'
require "$common" 'function Remove-NewDesktopShortcut'

# Order matters: snapshot before the first sweep, cleanup after the last.
snapshot_line="$(grep -n 'Get-DesktopShortcut)' "$upgrade" | head -n1 | cut -d: -f1)"
choco_line="$(grep -n '^    choco upgrade all' "$upgrade" | head -n1 | cut -d: -f1)"
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
