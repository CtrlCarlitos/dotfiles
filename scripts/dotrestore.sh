#!/usr/bin/env bash
# dotrestore.sh - restore an archive created by dotbackup.sh onto this machine.
# Validates the manifest, restores the allowlisted config + ~/.ssh files, and
# refuses to overwrite an existing chezmoi config or any existing ~/.ssh file.
# Usage: bash dotrestore.sh <backup.7z>   (or: dot restore <archive>)
# Afterwards run `chezmoi init` then `chezmoi apply` - see
# docs/backup-restore.md for the full flow.
set -euo pipefail

[ "$#" -eq 1 ] || { printf 'ERROR: usage: %s <backup.7z>\n' "$0" >&2; exit 1; }
archive="$1"
[ -r "$archive" ] || { printf 'ERROR: archive is not readable: %s\n' "$archive" >&2; exit 1; }

seven_zip="$(command -v 7zz || command -v 7z || true)"
[ -n "$seven_zip" ] || { printf 'ERROR: install 7-Zip (7z or 7zz) first\n' >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
"$seven_zip" x -p "-o$stage" "$archive"

unexpected_root="$(find "$stage" -mindepth 1 -maxdepth 1 ! -name dotfiles-backup-v1 -print -quit)"
[ -z "$unexpected_root" ] || {
    printf 'ERROR: archive does not contain the dotfiles-backup-v1 layout\n' >&2
    exit 1
}

root="$stage/dotfiles-backup-v1"
manifest="$root/manifest.json"
config_source="$root/chezmoi/chezmoi.toml"
ssh_source="$root/ssh"
if [ ! -d "$root" ] || [ -L "$root" ]; then
    printf 'ERROR: archive does not contain the dotfiles-backup-v1 layout\n' >&2
    exit 1
fi
staged_symlink="$(find "$root" -type l -print -quit)"
[ -z "$staged_symlink" ] || {
    printf 'ERROR: archive contains a symlink: %s\n' "$staged_symlink" >&2
    exit 1
}
manifest_entry=0
chezmoi_entry=0
ssh_entry=0
for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "${entry##*/}" in
        manifest.json) [ -f "$entry" ] && manifest_entry=1 ;;
        chezmoi) [ -d "$entry" ] && chezmoi_entry=1 ;;
        ssh) [ -d "$entry" ] && ssh_entry=1 ;;
        # RESTORE.md: human-only orientation, optional (older archives lack it)
        RESTORE.md) ;;
        *)
            printf 'ERROR: archive does not contain the dotfiles-backup-v1 layout\n' >&2
            exit 1
            ;;
    esac
done
if [ "$manifest_entry" -ne 1 ] || [ "$chezmoi_entry" -ne 1 ] || [ "$ssh_entry" -ne 1 ] || [ ! -f "$config_source" ]; then
    printf 'ERROR: archive does not contain the dotfiles-backup-v1 layout\n' >&2
    exit 1
fi

if command -v jq >/dev/null 2>&1; then
    jq -e '.format_version == "dotfiles-backup-v1"' "$manifest" >/dev/null || {
        printf 'ERROR: invalid backup manifest\n' >&2
        exit 1
    }
else
    manifest_text="$(<"$manifest")"
    manifest_pattern='^[[:space:]]*\{[[:space:]]*"format_version"[[:space:]]*:[[:space:]]*"dotfiles-backup-v1"[[:space:]]*,[[:space:]]*"created_at"[[:space:]]*:[[:space:]]*"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"[[:space:]]*,[[:space:]]*"source_platform"[[:space:]]*:[[:space:]]*"[A-Za-z0-9._-]+"[[:space:]]*\}[[:space:]]*$'
    [[ "$manifest_text" =~ $manifest_pattern ]] || {
        printf 'ERROR: invalid backup manifest\n' >&2
        exit 1
    }
fi

reject_symlinked_parent() { # $1 = destination path
    local parent
    parent="$(dirname "$1")"
    while [ "$parent" != "$HOME" ]; do
        [ "$parent" != / ] || {
            printf 'ERROR: destination is outside HOME: %s\n' "$1" >&2
            exit 1
        }
        [ ! -L "$parent" ] || {
            printf 'ERROR: refusing symlinked destination parent: %s\n' "$parent" >&2
            exit 1
        }
        parent="$(dirname "$parent")"
    done
}

config_destination="$HOME/.config/chezmoi/chezmoi.toml"
reject_symlinked_parent "$config_destination"
if [ -e "$config_destination" ] || [ -L "$config_destination" ]; then
    printf 'ERROR: refusing to overwrite existing ChezMoi config: %s\n' "$config_destination" >&2
    exit 1
fi

if [ -d "$ssh_source" ]; then
    reject_symlinked_parent "$HOME/.ssh/.dotrestore-parent-check"
    while IFS= read -r -d '' source; do
        relative="${source#"$ssh_source/"}"
        destination="$HOME/.ssh/$relative"
        reject_symlinked_parent "$destination"
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            printf 'ERROR: refusing to overwrite existing SSH file: %s\n' "$destination" >&2
            exit 1
        fi
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
        # 600 for every restored file: private halves need it, and .pub halves
        # are IdentityFile targets (OpenSSH enforces private-key permissions
        # on them too).
        chmod 600 "$destination"
    done < <(find "$ssh_source" -type f -print0)
fi

# Cross-OS normalization: when the archive was created on a different
# platform, translate what translates and say what was done. source_platform
# comes from the backup manifest (windows / linux / darwin). A Windows-origin
# restore carries CRLF line endings that Unix OpenSSH refuses ("error in
# libcrypto" before any auth) - stripped here; permissions are already
# normalized to 600 above.
target_platform="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$target_platform" in darwin*) target_platform="darwin" ;; esac
source_platform=""
if command -v jq >/dev/null 2>&1; then
    source_platform="$(jq -r '.source_platform // empty' "$manifest" 2>/dev/null || true)"
else
    source_platform="$(sed -n 's/.*"source_platform"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._-]*\)".*/\1/p' "$manifest" 2>/dev/null || true)"
fi
if [ -n "$source_platform" ] && [ "$source_platform" != "$target_platform" ]; then
    translated=0
    while IFS= read -r -d '' restored; do
        if [ -s "$restored" ] && grep -q "$(printf '\r')" "$restored" 2>/dev/null; then
            perl -pi -e 's/\r$//' "$restored" 2>/dev/null || true
            translated=$((translated + 1))
        fi
    done < <(find "$HOME/.ssh" -type f -print0)
    printf 'Cross-OS restore (source: %s, target: %s): stripped Windows CRLF from %d file(s); permissions normalized to 600.\n' \
        "$source_platform" "$target_platform" "$translated"
fi

printf 'Restore complete. Run:\n  chezmoi init\n  chezmoi apply\n'
