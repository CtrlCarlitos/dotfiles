#!/usr/bin/env bash
# dotbackup.sh - encrypted portable backup of this machine's dotfiles state.
# Packs ~/.config/chezmoi/chezmoi.toml and every regular file under ~/.ssh
# into an AES-256 7-Zip archive at ~/.dot_backups/dotfiles-YYYYMMDD-HHMMSS.7z.
# Prompts for the passphrase (never echoed, never on the command line).
# Usage: bash dotbackup.sh            (or: dot backup)
# Full contract: docs/backup-restore.md; refusals live in the checks below.
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

# source_platform: normalized to the canonical vocabulary the restore twins
# compare against (windows / linux / darwin; uname -s gives Linux/Darwin).
platform="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$platform" in darwin*) platform="darwin" ;; esac

printf '{\n  "format_version": "dotfiles-backup-v1",\n  "created_at": "%s",\n  "source_platform": "%s"\n}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$platform" > "$root/manifest.json"

# RESTORE.md: human-only orientation inside the archive (the restore scripts
# never read it - they act on manifest.json). What is inside, how to restore
# on the same OS, and what changes on a different OS.
cat > "$root/RESTORE.md" <<EOF
# Dotfiles backup (created on $platform, $(date -u +%Y-%m-%d))

## Contents

- \`chezmoi/chezmoi.toml\` - this machine's ChezMoi config (prompted values,
  package groups, ssh_hosts, remote_access). Review before reusing on a
  different OS: paths and remote_access values are machine-specific.
- \`ssh/\` - every regular file from this machine's \`~/.ssh\`: private keys,
  .pub halves, config, known_hosts.

## Restore on the same OS

\`\`\`bash
7z x -p <this-archive> -o<stage>
bash dotrestore.sh <stage>/dotfiles-backup-v1   # from the dotfiles repo
\`\`\`
Then: \`chezmoi init && chezmoi apply\`.

## Restore on a different OS

The ssh keys translate: the restore normalizes permissions (600 on
Linux/macOS, user-only ACL on Windows) and strips Windows CRLF line endings
on Unix targets. The chezmoi config needs a human pass first - machine paths
and remote_access values do not translate.

## Model

Private keys live in exactly one place per platform (the Windows agent vault,
or this machine's ~/.ssh) - .pub halves are the only thing duplicated across
machines, and Host blocks reference the .pub.
EOF

archive="$HOME/.dot_backups/dotfiles-$platform-$(date -u +%Y%m%d-%H%M%S).7z"
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
