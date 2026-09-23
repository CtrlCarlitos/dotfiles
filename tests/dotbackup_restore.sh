#!/usr/bin/env bash
set -euo pipefail

# Unix-behavior test: POSIX modes, gum, and the .sh twins are not available on
# Windows (Git Bash); the PowerShell twins have their own tests and CI runs this
# on Linux. Skip rather than fail so `bash tests/*.sh` is meaningful on Windows.
case "${OSTYPE:-}" in
    msys*|cygwin*|win32) echo "SKIP: dotbackup_restore.sh is Unix-only (needs POSIX symlinks)"; exit 0 ;;
esac

# Behavioral coverage for the Unix portable backup commands. The fake 7-Zip
# records its interface and preserves a staged archive payload as a directory.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backup="$repo_root/scripts/dotbackup.sh"
restore="$repo_root/scripts/dotrestore.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$backup" ] || fail "scripts/dotbackup.sh missing"
[ -f "$restore" ] || fail "scripts/dotrestore.sh missing"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

cat > "$bin/7z" <<'EOF'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >> "$FAKE_7Z_LOG"
for arg in "$@"; do
    case "$arg" in
        -p*) [ "$arg" = '-p' ] || { printf 'passphrase must not be in argv\n' >&2; exit 64; } ;;
    esac
done

command="$1"
shift
case "$command" in
    a)
        archive=''
        root=''
        for arg in "$@"; do
            case "$arg" in
                -*) ;;
                *) if [ -z "$archive" ]; then archive="$arg"; else root="$arg"; fi ;;
            esac
        done
        [ -n "$archive" ] && [ -n "$root" ] || exit 65
        : > "$archive"
        mkdir -p "${archive}.contents"
        cp -R "$root" "${archive}.contents/"
        ;;
    x)
        output=''
        for arg in "$@"; do
            case "$arg" in -o*) output="${arg#-o}" ;; esac
        done
        archive="${!#}"
        [ -n "$output" ] && [ -d "${archive}.contents" ] || exit 67
        cp -R "${archive}.contents/." "$output"
        ;;
    *) exit 68 ;;
esac
EOF
chmod +x "$bin/7z"

no_jq_bin="$tmp/no-jq-bin"
mkdir -p "$no_jq_bin"
for tool in chmod cp dirname find grep mkdir mktemp rm; do
    ln -s "$(command -v "$tool")" "$no_jq_bin/$tool"
done
ln -s "$bin/7z" "$no_jq_bin/7z"

run_backup() { # $1 = home
    HOME="$1" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" bash "$backup"
}

run_restore() { # $1 = home, $2 = archive
    HOME="$1" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" bash "$restore" "$2"
}

run_restore_without_jq() { # $1 = home, $2 = archive
    HOME="$1" PATH="$no_jq_bin" FAKE_7Z_LOG="$tmp/7z.log" /bin/bash "$restore" "$2"
}

make_source_home() { # $1 = home
    mkdir -p "$1/.config/chezmoi" "$1/.ssh/nested"
    printf 'source = "fixture"\n' > "$1/.config/chezmoi/chezmoi.toml"
    printf 'private key\n' > "$1/.ssh/custom_signing_key"
    printf 'public key\n' > "$1/.ssh/custom_signing_key.pub"
    printf 'host example\n' > "$1/.ssh/config"
    printf 'ignored nested file\n' > "$1/.ssh/nested/ignored"
}

make_archive() { # $1 = archive, $2 = manifest JSON
    local archive="$1" manifest="$2"
    mkdir -p "${archive}.contents/dotfiles-backup-v1/chezmoi" \
        "${archive}.contents/dotfiles-backup-v1/ssh"
    : > "$archive"
    printf '%s\n' "$manifest" > "${archive}.contents/dotfiles-backup-v1/manifest.json"
    printf 'restored config\n' > "${archive}.contents/dotfiles-backup-v1/chezmoi/chezmoi.toml"
    printf 'restored private\n' > "${archive}.contents/dotfiles-backup-v1/ssh/custom_key"
    printf 'restored public\n' > "${archive}.contents/dotfiles-backup-v1/ssh/custom_key.pub"
}

# [1] A missing local ChezMoi config must be rejected before archiving.
missing_home="$tmp/home-missing"
mkdir -p "$missing_home"
run_backup "$missing_home" >/dev/null 2>&1 && fail '[1] backup accepted missing chezmoi.toml'
printf '  ok: missing ChezMoi config rejected\n'

# [2] A backup is timestamped, encrypted with header encryption, uses a bare
# passphrase flag, and stages only the allowlisted local payload.
source_home="$tmp/home-source"
make_source_home "$source_home"
: > "$tmp/7z.log"
run_backup "$source_home" >/dev/null
archives=("$source_home"/.dot_backups/dotfiles-*.7z)
[ "${#archives[@]}" = 1 ] && [ -f "${archives[0]}" ] || fail '[2] timestamped archive missing'
grep -Fq -- '-t7z' "$tmp/7z.log" || fail '[2] archive type flag missing'
grep -Fq -- '-mhe=on' "$tmp/7z.log" || fail '[2] header encryption flag missing'
grep -Eq -- '(^| )-p( |$)' "$tmp/7z.log" || fail '[2] bare passphrase flag missing'
payload="${archives[0]}.contents/dotfiles-backup-v1"
[ -f "$payload/manifest.json" ] || fail '[2] manifest missing from staging'
[ -f "$payload/chezmoi/chezmoi.toml" ] || fail '[2] ChezMoi config missing from staging'
[ -f "$payload/ssh/custom_signing_key" ] || fail '[2] non-id SSH key missing from staging'
[ -f "$payload/ssh/nested/ignored" ] || fail '[2] nested SSH file missing from staging'
printf '  ok: encrypted v1 archive contains allowlisted payload\n'

# [3] A manifest for another format must not write any destination files.
invalid_archive="$tmp/invalid.7z"
make_archive "$invalid_archive" '{"format_version":"wrong-format","created_at":"2026-01-01T00:00:00Z","source_platform":"Linux"}'
invalid_home="$tmp/home-invalid"
mkdir -p "$invalid_home"
run_restore "$invalid_home" "$invalid_archive" >/dev/null 2>&1 && fail '[3] invalid manifest was restored'
[ ! -e "$invalid_home/.config/chezmoi/chezmoi.toml" ] || fail '[3] invalid manifest wrote config'
printf '  ok: invalid manifest rejected before restore\n'

# [4] The extracted archive may contain only the v1 root.
layout_archive="$tmp/layout.7z"
make_archive "$layout_archive" '{"format_version":"dotfiles-backup-v1","created_at":"2026-01-01T00:00:00Z","source_platform":"Linux"}'
printf 'unexpected\n' > "${layout_archive}.contents/extra"
layout_home="$tmp/home-layout"
mkdir -p "$layout_home"
run_restore "$layout_home" "$layout_archive" >/dev/null 2>&1 && fail '[4] archive with an unexpected root entry was restored'
[ ! -e "$layout_home/.config/chezmoi/chezmoi.toml" ] || fail '[4] invalid layout wrote config'
printf '  ok: invalid archive layout rejected\n'

# [5] The v1 payload root must contain only its three required entries.
payload_layout_archive="$tmp/payload-layout.7z"
make_archive "$payload_layout_archive" '{"format_version":"dotfiles-backup-v1","created_at":"2026-01-01T00:00:00Z","source_platform":"Linux"}'
printf 'unexpected\n' > "${payload_layout_archive}.contents/dotfiles-backup-v1/extra"
payload_layout_home="$tmp/home-payload-layout"
mkdir -p "$payload_layout_home"
run_restore "$payload_layout_home" "$payload_layout_archive" >/dev/null 2>&1 && fail '[5] archive with an unexpected payload entry was restored'
[ ! -e "$payload_layout_home/.config/chezmoi/chezmoi.toml" ] || fail '[5] invalid payload layout wrote config'
printf '  ok: exact v1 payload layout required\n'

# [6] Symlinks in the staged payload must be rejected before any files are read.
payload_symlink_archive="$tmp/payload-symlink.7z"
make_archive "$payload_symlink_archive" '{"format_version":"dotfiles-backup-v1","created_at":"2026-01-01T00:00:00Z","source_platform":"Linux"}'
rm "${payload_symlink_archive}.contents/dotfiles-backup-v1/chezmoi/chezmoi.toml"
ln -s /etc/passwd "${payload_symlink_archive}.contents/dotfiles-backup-v1/chezmoi/chezmoi.toml"
payload_symlink_home="$tmp/home-payload-symlink"
mkdir -p "$payload_symlink_home"
run_restore "$payload_symlink_home" "$payload_symlink_archive" >/dev/null 2>&1 && fail '[6] archive with a payload symlink was restored'
[ ! -e "$payload_symlink_home/.config/chezmoi/chezmoi.toml" ] || fail '[6] payload symlink wrote config'
printf '  ok: staged payload symlinks rejected\n'

# [7] Symlinked destination parents and final targets must not redirect restored files outside HOME.
valid_archive="$tmp/valid.7z"
make_archive "$valid_archive" '{"format_version":"dotfiles-backup-v1","created_at":"2026-01-01T00:00:00Z","source_platform":"Linux"}'
config_parent_home="$tmp/home-config-parent"
config_outside="$tmp/config-outside"
mkdir -p "$config_parent_home/.config" "$config_outside"
ln -s "$config_outside" "$config_parent_home/.config/chezmoi"
run_restore "$config_parent_home" "$valid_archive" >/dev/null 2>&1 && fail '[5] symlinked config parent was accepted'
[ ! -e "$config_outside/chezmoi.toml" ] || fail '[5] restore wrote through config parent symlink'
ssh_parent_home="$tmp/home-ssh-parent"
ssh_outside="$tmp/ssh-outside"
mkdir -p "$ssh_parent_home" "$ssh_outside"
ln -s "$ssh_outside" "$ssh_parent_home/.ssh"
run_restore "$ssh_parent_home" "$valid_archive" >/dev/null 2>&1 && fail '[5] symlinked SSH parent was accepted'
[ ! -e "$ssh_outside/custom_key" ] || fail '[5] restore wrote through SSH parent symlink'
empty_ssh_archive="$tmp/empty-ssh.7z"
make_archive "$empty_ssh_archive" '{"format_version":"dotfiles-backup-v1","created_at":"2026-01-01T00:00:00Z","source_platform":"Linux"}'
rm "${empty_ssh_archive}.contents/dotfiles-backup-v1/ssh/custom_key" \
    "${empty_ssh_archive}.contents/dotfiles-backup-v1/ssh/custom_key.pub"
empty_ssh_home="$tmp/home-empty-ssh-parent"
empty_ssh_outside="$tmp/empty-ssh-outside"
mkdir -p "$empty_ssh_home" "$empty_ssh_outside"
ln -s "$empty_ssh_outside" "$empty_ssh_home/.ssh"
run_restore "$empty_ssh_home" "$empty_ssh_archive" >/dev/null 2>&1 && fail '[5] empty SSH payload accepted a symlinked SSH parent'
[ ! -e "$empty_ssh_home/.config/chezmoi/chezmoi.toml" ] || fail '[7] SSH parent rejection wrote config first'
config_target_home="$tmp/home-config-target"
config_target_outside="$tmp/config-target-outside"
mkdir -p "$config_target_home/.config/chezmoi" "$config_target_outside"
ln -s "$config_target_outside/chezmoi.toml" "$config_target_home/.config/chezmoi/chezmoi.toml"
run_restore "$config_target_home" "$valid_archive" >/dev/null 2>&1 && fail '[7] dangling config target symlink was accepted'
[ ! -e "$config_target_outside/chezmoi.toml" ] || fail '[7] restore wrote through config target symlink'
ssh_target_home="$tmp/home-ssh-target"
ssh_target_outside="$tmp/ssh-target-outside"
mkdir -p "$ssh_target_home/.ssh" "$ssh_target_outside"
ln -s "$ssh_target_outside/custom_key" "$ssh_target_home/.ssh/custom_key"
run_restore "$ssh_target_home" "$valid_archive" >/dev/null 2>&1 && fail '[7] dangling SSH target symlink was accepted'
[ ! -e "$ssh_target_outside/custom_key" ] || fail '[7] restore wrote through SSH target symlink'
printf '  ok: symlinked destination parents and targets rejected\n'

# [6] The fixed-format parser accepts a valid v1 manifest without jq.
no_jq_valid_home="$tmp/home-no-jq-valid"
mkdir -p "$no_jq_valid_home"
run_restore_without_jq "$no_jq_valid_home" "$valid_archive" >/dev/null
[ "$(<"$no_jq_valid_home/.config/chezmoi/chezmoi.toml")" = 'restored config' ] || fail '[6] valid manifest was not restored without jq'
printf '  ok: valid fixed-format manifest restored without jq\n'

# [7] The no-jq parser must reject malformed JSON and conflicting duplicates.
malformed_archive="$tmp/malformed.7z"
make_archive "$malformed_archive" '{"format_version":"dotfiles-backup-v1"'
malformed_home="$tmp/home-malformed"
mkdir -p "$malformed_home"
run_restore_without_jq "$malformed_home" "$malformed_archive" >/dev/null 2>&1 && fail '[6] malformed manifest was restored without jq'
[ ! -e "$malformed_home/.config/chezmoi/chezmoi.toml" ] || fail '[6] malformed manifest wrote config'
duplicate_archive="$tmp/duplicate.7z"
make_archive "$duplicate_archive" '{"format_version":"dotfiles-backup-v1","format_version":"wrong-format"}'
duplicate_home="$tmp/home-duplicate"
mkdir -p "$duplicate_home"
run_restore_without_jq "$duplicate_home" "$duplicate_archive" >/dev/null 2>&1 && fail '[6] duplicate format_version manifest was restored without jq'
[ ! -e "$duplicate_home/.config/chezmoi/chezmoi.toml" ] || fail '[6] duplicate manifest wrote config'
printf '  ok: strict no-jq manifest validation\n'

# [7] Existing destination files must never be overwritten.
valid_archive="$tmp/valid.7z"
make_archive "$valid_archive" '{"format_version":"dotfiles-backup-v1","created_at":"2026-01-01T00:00:00Z","source_platform":"Linux"}'
config_collision_home="$tmp/home-config-collision"
mkdir -p "$config_collision_home/.config/chezmoi"
printf 'keep config\n' > "$config_collision_home/.config/chezmoi/chezmoi.toml"
run_restore "$config_collision_home" "$valid_archive" >/dev/null 2>&1 && fail '[4] existing config was overwritten'
[ "$(<"$config_collision_home/.config/chezmoi/chezmoi.toml")" = 'keep config' ] || fail '[4] config collision changed file'
ssh_collision_home="$tmp/home-ssh-collision"
mkdir -p "$ssh_collision_home/.ssh"
printf 'keep key\n' > "$ssh_collision_home/.ssh/custom_key"
run_restore "$ssh_collision_home" "$valid_archive" >/dev/null 2>&1 && fail '[4] existing SSH file was overwritten'
[ "$(<"$ssh_collision_home/.ssh/custom_key")" = 'keep key' ] || fail '[4] SSH collision changed file'
printf '  ok: restore refuses collisions\n'

# [5] A valid v1 archive restores the local config and SSH payload into an
# empty home, retaining distinct modes for public and private SSH files.
restore_home="$tmp/home-restore"
mkdir -p "$restore_home"
run_restore "$restore_home" "$valid_archive" >/dev/null
[ "$(<"$restore_home/.config/chezmoi/chezmoi.toml")" = 'restored config' ] || fail '[5] config not restored'
[ "$(<"$restore_home/.ssh/custom_key")" = 'restored private' ] || fail '[5] private SSH file not restored'
[ "$(<"$restore_home/.ssh/custom_key.pub")" = 'restored public' ] || fail '[5] public SSH file not restored'
[ "$(stat -c '%a' "$restore_home/.ssh")" = 700 ] || fail '[5] SSH directory mode incorrect'
[ "$(stat -c '%a' "$restore_home/.ssh/custom_key")" = 600 ] || fail '[5] private SSH mode incorrect'
[ "$(stat -c '%a' "$restore_home/.ssh/custom_key.pub")" = 644 ] || fail '[5] public SSH mode incorrect'
printf '  ok: valid payload restored with SSH modes\n'

printf 'PASS: dotbackup_restore.sh\n'
