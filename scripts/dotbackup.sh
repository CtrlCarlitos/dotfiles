#!/usr/bin/env bash
set -euo pipefail

seven_zip="$(command -v 7zz || command -v 7z || true)"
[ -n "$seven_zip" ] || { printf 'ERROR: install 7-Zip (7z or 7zz) first\n' >&2; exit 1; }

config="$HOME/.config/chezmoi/chezmoi.toml"
[ -f "$config" ] || { printf 'ERROR: missing ChezMoi config: %s\n' "$config" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
root="$stage/dotfiles-backup-v1"
mkdir -p "$root/chezmoi" "$root/ssh" "$HOME/.dot_backups"
cp "$config" "$root/chezmoi/chezmoi.toml"

if [ -d "$HOME/.ssh" ]; then
    while IFS= read -r -d '' source; do
        relative="${source#"$HOME/.ssh/"}"
        destination="$root/ssh/$relative"
        mkdir -p "$(dirname "$destination")"
        cp "$source" "$destination"
    done < <(find "$HOME/.ssh" -type f -print0)
fi

printf '{\n  "format_version": "dotfiles-backup-v1",\n  "created_at": "%s",\n  "source_platform": "%s"\n}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(uname -s)" > "$root/manifest.json"

archive="$HOME/.dot_backups/dotfiles-$(date -u +%Y%m%d-%H%M%S).7z"
[ ! -e "$archive" ] || { printf 'ERROR: backup archive already exists: %s\n' "$archive" >&2; exit 1; }
"$seven_zip" a -t7z -mhe=on -p "$archive" "$root"
# Say what is in the archive. The docs list it, but the person holding the file
# is the one who needs to know. Counted by exclusion so nothing here ever opens
# a private key: anything under ~/.ssh that is not a .pub, config or host data.
keys=0
if [ -d "$HOME/.ssh" ]; then
    while IFS= read -r -d '' f; do
        case "${f##*/}" in
            *.pub | config | known_hosts | known_hosts.old | authorized_keys | environment) ;;
            *) keys=$((keys + 1)) ;;
        esac
    done < <(find "$HOME/.ssh" -type f -print0)
fi

printf 'Backup created: %s\n' "$archive"
printf '  Contains %d private key file(s) from ~/.ssh. Treat this archive as key material.\n' "$keys"
printf '  This is disaster recovery for THIS machine, not a way to set up another one:\n'
printf '  give an additional machine its own keys instead (docs/ssh-agents.md).\n'
printf '  Re-run after rotating a key - older archives still hold the old ones.\n'
