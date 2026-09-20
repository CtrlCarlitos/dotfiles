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
printf 'Backup created: %s\n' "$archive"
