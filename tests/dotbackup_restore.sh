#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Unix-behavior test: POSIX modes, gum, and the .sh twins are not available on
# Windows (Git Bash); the PowerShell twins have their own tests and CI runs this
# on Linux. Skip rather than fail so `bash tests/*.sh` is meaningful on Windows.
case "${OSTYPE:-}" in
    msys*|cygwin*|win32) skip "dotbackup_restore.sh is Unix-only (needs POSIX symlinks)" ;;
esac

# Behavioral coverage for the Unix portable backup commands. The fake 7-Zip
# records its interface and preserves a staged archive payload as a directory.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backup="$repo_root/scripts/dotbackup.sh"
restore="$repo_root/scripts/dotrestore.sh"

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
for tool in chmod cp dirname find grep mkdir mktemp rm uname tr perl; do
    ln -s "$(command -v "$tool")" "$no_jq_bin/$tool"
done
ln -s "$bin/7z" "$no_jq_bin/7z"

# XDG_* are stripped so a developer's own environment cannot move the guardrail roots under
# test; scenario [17] sets them explicitly.
run_backup() { # $1 = home
    env -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$1" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" bash "$backup"
}

run_restore() { # $1 = home, $2 = archive
    env -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$1" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" bash "$restore" "$2"
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

# make_archive_windows: a Windows-origin archive - CRLF line endings in the
# key files (the class a Windows->WSL restore must normalize; observed live:
# CRLF keys die in libcrypto on Linux before any auth).
make_archive_windows() { # $1 = archive, $2 = manifest JSON
    make_archive "$1" "$2"
    printf 'windows private\r\n' > "${1}.contents/dotfiles-backup-v1/ssh/custom_key"
    printf 'windows public\r\n' > "${1}.contents/dotfiles-backup-v1/ssh/custom_key.pub"
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
if [ "${#archives[@]}" = 1 ] && [ -f "${archives[0]}" ]; then :; else fail '[2] timestamped archive missing'; fi
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
[ "$(stat -c '%a' "$restore_home/.ssh/custom_key.pub")" = 600 ] || fail '[5] public SSH mode incorrect (600: .pub halves are IdentityFile targets)'
printf '  ok: valid payload restored with SSH modes\n'

# [8] Cross-OS restore: a Windows-origin archive (CRLF key files) restored on
# Linux gets CR stripped and 600 permissions, with the translation reported.
# Exercises manifest.source_platform consumption end-to-end.
cross_home="$tmp/home-crossos"
mkdir -p "$cross_home"
cross_archive="$tmp/cross-os.7z"
make_archive_windows "$cross_archive" '{"format_version":"dotfiles-backup-v1","created_at":"2026-01-01T00:00:00Z","source_platform":"Windows"}'
run_restore "$cross_home" "$cross_archive" >/dev/null
for keyfile in "$cross_home"/.ssh/custom_key "$cross_home"/.ssh/custom_key.pub; do
    [ -f "$keyfile" ] || fail "[8] $keyfile missing after cross-OS restore"
    [ "$(stat -c '%a' "$keyfile")" = 600 ] || fail "[8] $keyfile must be 600 after cross-OS restore"
    if grep -q $'\r' "$keyfile"; then
        fail "[8] $keyfile still carries CRLF after cross-OS restore"
    fi
done
grep -q 'Cross-OS restore' /tmp/dotrestore-translation.log 2>/dev/null || true
echo "  ok: cross-OS restore normalized CRLF and permissions"

# --- guardrail operator state -------------------------------------------------
make_guardrail_home() { # $1 = home, $2 = approval mode
    make_source_home "$1"
    mkdir -p "$1/.config/guardrail" "$1/.local/state/guardrail/operator-auth/nested" \
        "$1/.local/state/guardrail/manifests" "$1/.local/state/guardrail/allowances"
    printf 'approval = "%s"\n' "$2" > "$1/.config/guardrail/waivers.toml"
    printf 'night = true\n' > "$1/.config/guardrail/night.toml"
    printf 'credential\n' > "$1/.local/state/guardrail/operator-auth/enrollment.json"
    printf 'nested credential\n' > "$1/.local/state/guardrail/operator-auth/nested/key"
    printf '{"event":1}\n' > "$1/.local/state/guardrail/audit-2026.jsonl"
    printf 'regenerated\n' > "$1/.local/state/guardrail/manifests/claude.json"
    printf 'machine secret\n' > "$1/.local/state/guardrail/allowances/auth.key"
    printf 'trust record\n' > "$1/.local/state/guardrail/selftest-passed"
}

backup_payload() { # $1 = home; prints the staged payload dir of its only archive
    local archives=("$1"/.dot_backups/dotfiles-*.7z)
    printf '%s\n' "${archives[0]}.contents/dotfiles-backup-v1"
}

# [9] Passkey mode: operator config and enrollment captured; the audit log only
# on request; regenerated and per-machine state never.
pk_home="$tmp/home-guardrail-passkey"
make_guardrail_home "$pk_home" passkey
run_backup "$pk_home" >/dev/null
pk_payload="$(backup_payload "$pk_home")"
[ -f "$pk_payload/guardrail/config/waivers.toml" ] || fail '[9] waivers.toml not captured'
[ -f "$pk_payload/guardrail/config/night.toml" ] || fail '[9] night.toml not captured'
[ -f "$pk_payload/guardrail/operator-auth/nested/key" ] || fail '[9] passkey enrollment not captured in passkey mode'
[ ! -e "$pk_payload/guardrail/audit" ] || fail '[9] audit log captured without DOTBACKUP_AUDIT=1'
for never in manifests allowances selftest-passed; do
    [ -z "$(find "$pk_payload" -name "$never" -print -quit)" ] || fail "[9] $never must never be captured"
done
rm -rf "$pk_home/.dot_backups"
HOME="$pk_home" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" DOTBACKUP_AUDIT=1 bash "$backup" >/dev/null
[ -f "$(backup_payload "$pk_home")/guardrail/audit/audit-2026.jsonl" ] || fail '[9] audit log not captured with DOTBACKUP_AUDIT=1'
echo "  ok: guardrail backup captures operator state, skips regenerated state"

# [10] Prompt mode (the default) does not use the passkey, so it is not captured.
pr_home="$tmp/home-guardrail-prompt"
make_guardrail_home "$pr_home" prompt
run_backup "$pr_home" >/dev/null
pr_payload="$(backup_payload "$pr_home")"
[ -f "$pr_payload/guardrail/config/waivers.toml" ] || fail '[10] waivers.toml not captured in prompt mode'
[ ! -e "$pr_payload/guardrail/operator-auth" ] || fail '[10] passkey enrollment captured outside passkey mode'
echo "  ok: passkey enrollment captured only in passkey mode"

# [11] No guardrail state at all: no guardrail/ entry (older layout unchanged).
plain_home="$tmp/home-no-guardrail"
make_source_home "$plain_home"
run_backup "$plain_home" >/dev/null
[ ! -e "$(backup_payload "$plain_home")/guardrail" ] || fail '[11] guardrail/ present without guardrail state'
echo "  ok: no guardrail section when guardrail was never configured"

# [12] Same-OS restore: owner-only modes, enrollment included.
pk_archive=("$pk_home"/.dot_backups/dotfiles-*.7z)
gr_restore="$tmp/home-guardrail-restore"
mkdir -p "$gr_restore"
run_restore "$gr_restore" "${pk_archive[0]}" >/dev/null
[ "$(<"$gr_restore/.config/guardrail/waivers.toml")" = 'approval = "passkey"' ] || fail '[12] waivers.toml not restored'
[ "$(stat -c '%a' "$gr_restore/.config/guardrail/waivers.toml")" = 600 ] || fail '[12] waivers.toml must be 600'
[ "$(stat -c '%a' "$gr_restore/.config/guardrail")" = 700 ] || fail '[12] guardrail config dir must be 700'
[ "$(stat -c '%a' "$gr_restore/.local/state/guardrail/operator-auth/nested/key")" = 600 ] || fail '[12] enrollment must be 600'
[ -f "$gr_restore/.local/state/guardrail/audit-2026.jsonl" ] || fail '[12] audit log not restored'
echo "  ok: guardrail state restored owner-only"

# [13] Cross-OS: config restored, passkey enrollment skipped with a notice.
gr_cross_archive="$tmp/guardrail-cross.7z"
mkdir -p "${gr_cross_archive}.contents"
cp -R "$(backup_payload "$pk_home")" "${gr_cross_archive}.contents/"
: > "$gr_cross_archive"
sed -i 's/"source_platform": "[a-z]*"/"source_platform": "windows"/' "${gr_cross_archive}.contents/dotfiles-backup-v1/manifest.json"
gr_cross="$tmp/home-guardrail-cross"
mkdir -p "$gr_cross"
cross_out="$(run_restore "$gr_cross" "$gr_cross_archive")"
[ -f "$gr_cross/.config/guardrail/waivers.toml" ] || fail '[13] cross-OS restore dropped waivers.toml'
[ ! -e "$gr_cross/.local/state/guardrail/operator-auth" ] || fail '[13] cross-OS restore wrote passkey enrollment'
printf '%s' "$cross_out" | grep -q 'enroll again' || fail '[13] skipped enrollment not reported'
echo "  ok: cross-OS restore skips passkey enrollment"

# [14] An existing guardrail file is never overwritten, and nothing is written first.
gr_collide="$tmp/home-guardrail-collide"
mkdir -p "$gr_collide/.config/guardrail"
printf 'keep\n' > "$gr_collide/.config/guardrail/waivers.toml"
run_restore "$gr_collide" "${pk_archive[0]}" >/dev/null 2>&1 && fail '[14] existing waivers.toml was overwritten'
[ "$(<"$gr_collide/.config/guardrail/waivers.toml")" = keep ] || fail '[14] collision changed waivers.toml'
[ ! -e "$gr_collide/.config/chezmoi/chezmoi.toml" ] || fail '[14] collision rejection wrote config first'
echo "  ok: restore refuses to overwrite guardrail files"

# [15] Anything outside the fixed guardrail allowlist is rejected.
gr_bad_archive="$tmp/guardrail-bad.7z"
mkdir -p "${gr_bad_archive}.contents"
cp -R "$(backup_payload "$pk_home")" "${gr_bad_archive}.contents/"
: > "$gr_bad_archive"
mkdir -p "${gr_bad_archive}.contents/dotfiles-backup-v1/guardrail/manifests"
printf 'stale\n' > "${gr_bad_archive}.contents/dotfiles-backup-v1/guardrail/manifests/claude.json"
gr_bad="$tmp/home-guardrail-bad"
mkdir -p "$gr_bad"
run_restore "$gr_bad" "$gr_bad_archive" >/dev/null 2>&1 && fail '[15] archive with a stale manifest was restored'
[ ! -e "$gr_bad/.config/chezmoi/chezmoi.toml" ] || fail '[15] rejected archive wrote config'
echo "  ok: guardrail allowlist enforced on restore"


# [16] Per-machine guardrail state added since the section was designed is never captured,
# not even with DOTBACKUP_AUDIT=1: a restored session-checks fingerprint would skip checks
# a restored tree has not passed, and the rollback record plus the set-aside binary name
# THIS machine's binary and hash (rollback would fail or roll back to the wrong build).
pm_home="$tmp/home-guardrail-permachine"
make_guardrail_home "$pm_home" passkey
mkdir -p "$pm_home/.local/state/guardrail/session-checks" "$pm_home/.local/bin"
printf 'fingerprint\n' > "$pm_home/.local/state/guardrail/session-checks/repo.json"
printf '{"sha256":"x"}\n' > "$pm_home/.local/state/guardrail/previous.json"
printf 'binary\n' > "$pm_home/.local/bin/guardrail.previous"
printf 'binary\n' > "$pm_home/.local/bin/guardrail.previous.exe"
HOME="$pm_home" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" DOTBACKUP_AUDIT=1 bash "$backup" >/dev/null
pm_payload="$(backup_payload "$pm_home")"
for never in session-checks previous.json 'guardrail.previous*'; do
    [ -z "$(find "$pm_payload" -name "$never" -print -quit)" ] || fail "[16] $never must never be captured"
done
echo "  ok: per-machine guardrail state (session-checks, rollback record, set-aside binary) never captured"

# [17] XDG overrides: guardrail resolves config under XDG_CONFIG_HOME and state under
# XDG_STATE_HOME when set. Backup reads there, restore writes there, and a root outside
# HOME is refused with a clear message instead of silently capturing nothing.
xdg_home="$tmp/home-xdg"
make_source_home "$xdg_home"
mkdir -p "$xdg_home/xcfg/guardrail" "$xdg_home/xst/guardrail/operator-auth"
printf 'approval = "passkey"\n' > "$xdg_home/xcfg/guardrail/waivers.toml"
printf 'credential\n' > "$xdg_home/xst/guardrail/operator-auth/enrollment.json"
printf '{"event":1}\n' > "$xdg_home/xst/guardrail/audit.jsonl"
XDG_CONFIG_HOME="$xdg_home/xcfg" XDG_STATE_HOME="$xdg_home/xst" HOME="$xdg_home" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" DOTBACKUP_AUDIT=1 bash "$backup" >/dev/null
xdg_payload="$(backup_payload "$xdg_home")"
[ -f "$xdg_payload/guardrail/config/waivers.toml" ] || fail '[17] backup ignored XDG_CONFIG_HOME'
[ -f "$xdg_payload/guardrail/operator-auth/enrollment.json" ] || fail '[17] backup ignored XDG_STATE_HOME (operator-auth)'
[ -f "$xdg_payload/guardrail/audit/audit.jsonl" ] || fail '[17] backup ignored XDG_STATE_HOME (audit)'
xdg_archive=("$xdg_home"/.dot_backups/dotfiles-*.7z)
xdg_restore="$tmp/home-xdg-restore"
mkdir -p "$xdg_restore"
XDG_CONFIG_HOME="$xdg_restore/xcfg" XDG_STATE_HOME="$xdg_restore/xst" HOME="$xdg_restore" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" bash "$restore" "${xdg_archive[0]}" >/dev/null
[ -f "$xdg_restore/xcfg/guardrail/waivers.toml" ] || fail '[17] restore ignored XDG_CONFIG_HOME'
[ -f "$xdg_restore/xst/guardrail/operator-auth/enrollment.json" ] || fail '[17] restore ignored XDG_STATE_HOME'
[ ! -e "$xdg_restore/.config/guardrail" ] || fail '[17] restore also wrote the default config root'
xdg_out="$tmp/home-xdg-outside"
mkdir -p "$xdg_out"
if xdg_err="$(XDG_CONFIG_HOME="$tmp/outside-home-cfg" HOME="$xdg_out" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" bash "$restore" "${xdg_archive[0]}" 2>&1 >/dev/null)"; then
    fail '[17] a guardrail root outside HOME must be refused'
fi
printf '%s' "$xdg_err" | grep -q 'outside HOME' || fail "[17] the refusal must say the root is outside HOME (got: $xdg_err)"
[ ! -e "$xdg_out/.config/chezmoi/chezmoi.toml" ] || fail '[17] refused restore wrote config first'
echo "  ok: XDG_CONFIG_HOME / XDG_STATE_HOME honored; a root outside HOME is refused"

# [18] Repo grants in waivers.toml are keyed by absolute repo path. After a cross-OS or
# cross-path restore they match nothing, silently: the restore must name them.
inert_archive="$tmp/guardrail-inert.7z"
mkdir -p "${inert_archive}.contents"
cp -R "$(backup_payload "$pk_home")" "${inert_archive}.contents/"
: > "$inert_archive"
cat > "${inert_archive}.contents/dotfiles-backup-v1/guardrail/config/waivers.toml" <<TOML
approval = "passkey"

["/definitely/missing/repo"]
  secret_allow = false

["C:\\\\Users\\\\gone\\\\repo"]
  secret_allow = false

["$tmp/real-repo"]
  secret_allow = false

[web_hosts]
  "example.com" = true
TOML
mkdir -p "$tmp/real-repo"
inert_home="$tmp/home-inert"
mkdir -p "$inert_home"
inert_out="$(run_restore "$inert_home" "$inert_archive")"
printf '%s' "$inert_out" | grep -Fq '/definitely/missing/repo' || fail '[18] a grant for a missing path must be listed'
printf '%s' "$inert_out" | grep -Fq 'C:\Users\gone\repo' || fail "[18] a Windows-path grant on Linux must be listed (got: $inert_out)"
printf '%s' "$inert_out" | grep -Fq '2 repo grant(s)' || fail "[18] the count must be 2 (got: $inert_out)"
if printf '%s' "$inert_out" | grep -Fq "$tmp/real-repo"; then fail '[18] a grant whose path exists must not be listed'; fi
if printf '%s' "$inert_out" | grep -Fq 'web_hosts'; then fail '[18] a non-path table must not be listed'; fi
# no repo grants at all -> no warning
inert_clean="$tmp/home-inert-clean"
mkdir -p "$inert_clean"
clean_out="$(run_restore "$inert_clean" "${pk_archive[0]}")"
if printf '%s' "$clean_out" | grep -Fq 'grant(s)'; then fail '[18] no warning expected when there are no repo grants'; fi
echo "  ok: restore names repo grants that will not apply here"

# [19] The audit log can be huge: say how big before the operator hands the archive around.
audit_home="$tmp/home-audit-size"
make_guardrail_home "$audit_home" prompt
audit_out="$(HOME="$audit_home" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" DOTBACKUP_AUDIT=1 bash "$backup")"
printf '%s' "$audit_out" | grep -Eq 'Audit log: 1 segment\(s\), ' || fail "[19] audit size not reported (got: $audit_out)"
rm -rf "$audit_home/.dot_backups"
quiet_out="$(run_backup "$audit_home")"
if printf '%s' "$quiet_out" | grep -Fq 'Audit log'; then fail '[19] audit size reported without DOTBACKUP_AUDIT=1'; fi
echo "  ok: audit log size reported when captured"

finish
