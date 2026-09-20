#!/usr/bin/env bash
set -euo pipefail

# Static parity guard for the PowerShell entry points. Removing any of these
# checks reintroduces a passphrase, manifest, collision, or cleanup regression.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backup="$repo_root/scripts/dotbackup.ps1"
restore="$repo_root/scripts/dotrestore.ps1"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
require() { grep -Fq -- "$2" "$1" || fail "missing $2 in ${1##*/}"; }

[ -f "$backup" ] || fail 'scripts/dotbackup.ps1 missing'
[ -f "$restore" ] || fail 'scripts/dotrestore.ps1 missing'

require "$backup" '-mhe=on'
require "$backup" "'-p'"
require "$backup" 'manifest.json'
require "$backup" 'dotfiles-backup-v1'
require "$restore" "'-p'"
require "$restore" 'manifest.json'
require "$restore" 'dotfiles-backup-v1'
require "$restore" 'chezmoi init'
require "$restore" 'chezmoi apply'

if grep -Fq -- '-p$' "$backup" "$restore" || grep -Fq -- '-p"' "$backup" "$restore"; then
    fail 'passphrase must use bare -p'
fi
if grep -Eq -- 'Read-Host.*[Pp]assphrase|[Pp]assphrase.*Read-Host' "$backup" "$restore"; then
    fail 'passphrase must not be collected by Read-Host'
fi

require "$restore" 'chezmoi.toml'
require "$restore" '$relative'
require "$restore" 'Test-Path -LiteralPath $configDestination'
require "$restore" 'Test-Path -LiteralPath $destination'
require "$restore" 'ReparsePoint'
require "$backup" 'finally'
require "$restore" 'finally'

printf 'PASS: dotbackup_restore_contract.sh\n'
