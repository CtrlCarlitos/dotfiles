#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 1 ] || { printf 'ERROR: usage: %s <backup.7z>\n' "$0" >&2; exit 1; }
archive="$1"
[ -r "$archive" ] || { printf 'ERROR: archive is not readable: %s\n' "$archive" >&2; exit 1; }

seven_zip="$(command -v 7zz || command -v 7z || true)"
[ -n "$seven_zip" ] || { printf 'ERROR: install 7-Zip (7z or 7zz) first\n' >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
"$seven_zip" t -p "$archive"
"$seven_zip" x -p "-o$stage" "$archive"

unexpected_root="$(find "$stage" -mindepth 1 -maxdepth 1 ! -name dotfiles-backup-v1 -print -quit)"
[ -z "$unexpected_root" ] || {
    printf 'ERROR: archive does not contain the dotfiles-backup-v1 layout\n' >&2
    exit 1
}

root="$stage/dotfiles-backup-v1"
manifest="$root/manifest.json"
config_source="$root/chezmoi/chezmoi.toml"
[ -d "$root" ] && [ -f "$manifest" ] && [ -f "$config_source" ] || {
    printf 'ERROR: archive does not contain the dotfiles-backup-v1 layout\n' >&2
    exit 1
}

if command -v jq >/dev/null 2>&1; then
    jq -e '.format_version == "dotfiles-backup-v1"' "$manifest" >/dev/null || {
        printf 'ERROR: invalid backup manifest\n' >&2
        exit 1
    }
elif ! grep -Eq '"format_version"[[:space:]]*:[[:space:]]*"dotfiles-backup-v1"' "$manifest"; then
    printf 'ERROR: invalid backup manifest\n' >&2
    exit 1
fi

config_destination="$HOME/.config/chezmoi/chezmoi.toml"
[ ! -e "$config_destination" ] || {
    printf 'ERROR: refusing to overwrite existing ChezMoi config: %s\n' "$config_destination" >&2
    exit 1
}

ssh_source="$root/ssh"
if [ -d "$ssh_source" ]; then
    while IFS= read -r -d '' source; do
        relative="${source#"$ssh_source/"}"
        destination="$HOME/.ssh/$relative"
        [ ! -e "$destination" ] || {
            printf 'ERROR: refusing to overwrite existing SSH file: %s\n' "$destination" >&2
            exit 1
        }
    done < <(find "$ssh_source" -type f -print0)
fi

mkdir -p "$(dirname "$config_destination")"
cp "$config_source" "$config_destination"
if [ -d "$ssh_source" ]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    while IFS= read -r -d '' source; do
        relative="${source#"$ssh_source/"}"
        destination="$HOME/.ssh/$relative"
        mkdir -p "$(dirname "$destination")"
        cp "$source" "$destination"
        case "$relative" in
            *.pub) chmod 644 "$destination" ;;
            *) chmod 600 "$destination" ;;
        esac
    done < <(find "$ssh_source" -type f -print0)
fi

printf 'Restore complete. Run:\n  chezmoi init\n  chezmoi apply\n'
