#!/usr/bin/env bash
set -euo pipefail

# Static parity guard for the PowerShell entry points. Removing any of these
# checks reintroduces a passphrase, manifest, collision, or cleanup regression.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backup="$repo_root/scripts/dotbackup.ps1"
restore="$repo_root/scripts/dotrestore.ps1"
docs="$repo_root/docs/backup-restore.md"

. "$repo_root/tests/lib.sh"

[ -f "$backup" ] || fail 'scripts/dotbackup.ps1 missing'
[ -f "$restore" ] || fail 'scripts/dotrestore.ps1 missing'
[ -f "$docs" ] || fail 'docs/backup-restore.md missing'

require "$backup" '-mhe=on'
require "$backup" "'-p'"
require "$backup" 'manifest.json'
require "$backup" 'dotfiles-backup-v1'
require "$backup" '$configItem.Attributes -band [IO.FileAttributes]::ReparsePoint'
require "$restore" '[CmdletBinding()]'
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
if grep -Eq -- "& \$sevenZip 't'|7-Zip failed while testing archive" "$restore"; then
    fail 'restore must extract once rather than testing then extracting'
fi

require "$restore" 'chezmoi.toml'
require "$restore" '$relative'
require "$restore" '$source.FullName.Substring($sshSource.Length)'
require "$restore" 'Get-Item -LiteralPath $configDestination -Force -ErrorAction SilentlyContinue'
require "$restore" 'Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue'
require "$restore" 'Refusing reparse-point destination:'
require "$restore" 'ReparsePoint'
require "$restore" '$payloadEntries.Count -ne 3'
require "$restore" "'manifest.json', 'chezmoi', 'ssh'"
require "$restore" 'Get-ChildItem -LiteralPath $payloadRoot -Force -Recurse'
require "$backup" 'finally'
require "$restore" 'finally'
require "$docs" 'powershell.exe -File'
if grep -Fq -- 'pwsh -File' "$docs"; then
    fail 'Windows commands must use powershell.exe'
fi

finish
