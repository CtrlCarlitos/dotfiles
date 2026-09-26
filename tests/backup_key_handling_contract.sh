#!/usr/bin/env bash
set -euo pipefail

# Backups and the ssh-agent model told different stories about private keys.
#
# docs/ssh-agents.md: keys live in exactly ONE place per machine, and other
# environments borrow signing ability through a forwarded socket.
# docs/backup-restore.md: here is an archive of ~/.ssh, transfer it to the
# destination machine.
#
# Both are right, for different questions, and the reconciliation is the thing
# this test pins down:
#
#   RECOVERY      the archive keeps private keys ON PURPOSE. A GitHub key can be
#                 replaced from the web UI; a key authorising you to a server may
#                 be the only thing that gets you back into it. Excluding keys
#                 would trade a real recovery path for a tidier story.
#
#   NOT PROVISION it is for a REPLACEMENT machine, never an additional live one.
#                 That case gets its own keys (the agent model). dotrestore
#                 enforces this by refusing to overwrite an existing key.
#
# Executed (v2, #135): dotbackup.sh runs against a fixture home under a stub
# 7-Zip, and the honesty contract is asserted from its REAL output - the
# private-key count (by exclusion) and the framing the operator holding the
# archive actually reads. The archive payload itself is inspected for the
# recovery path. Round-trip file mechanics live in tests/dotbackup_restore.sh;
# the PowerShell twin's behavior in tests/dotbackup_restore.ps1 (its framing
# lines stay pinned below - that twin has no execution test of its output).
# The docs-side cross-references moved to tests/docs_contracts.sh.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

backup="$repo_root/scripts/dotbackup.sh"
restore="$repo_root/scripts/dotrestore.sh"

[ -f "$backup" ] || fail "scripts/dotbackup.sh missing"
[ -f "$restore" ] || fail "scripts/dotrestore.sh missing"

# 1. The count is taken by EXCLUSION - nothing in the backup path opens a
#    private key to identify it. Reading key material to count it would be a
#    silly way to leak it into a log or a crash dump. Static by nature: this
#    asserts the ABSENCE of key-content parsing, which no fixture can prove.
if grep -Fq 'BEGIN' "$backup"; then
    fail "scripts/dotbackup.sh appears to inspect key contents - count by filename instead"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

# Stub 7-Zip: 'a' stages the payload root next to the archive (cp -R "$root"
# semantics); 'x' copies staged contents into -o<dir>. The passphrase must
# never appear in argv beyond the bare flag (same interface contract as the
# fake in tests/dotbackup_restore.sh).
cat >"$bin/7z" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_7Z_LOG:?}"
for arg in "$@"; do
    case "$arg" in -p*) [ "$arg" = "-p" ] || { echo "passphrase must not be in argv" >&2; exit 64; } ;; esac
done
command="$1"; shift
case "$command" in
    a)
        archive='' root=''
        for arg in "$@"; do
            case "$arg" in -*) ;; *) if [ -z "$archive" ]; then archive="$arg"; else root="$arg"; fi ;; esac
        done
        [ -n "$archive" ] && [ -n "$root" ] || exit 65
        : >"$archive"
        mkdir -p "${archive}.contents"
        cp -R "$root" "${archive}.contents/"
        ;;
    x)
        output=''
        for arg in "$@"; do case "$arg" in -o*) output="${arg#-o}" ;; esac; done
        archive="${!#}"
        [ -n "$output" ] && [ -d "${archive}.contents" ] || exit 67
        cp -R "${archive}.contents/." "$output"
        ;;
    *) exit 68 ;;
esac
EOF
chmod +x "$bin/7z"

# Fixture home: two private keys (the recovery path), their .pub twins, and
# the non-key files the exclusion count must skip.
home="$tmp/home"
mkdir -p "$home/.config/chezmoi" "$home/.ssh"
printf 'source = "fixture"\n' >"$home/.config/chezmoi/chezmoi.toml"
printf 'PRIVATE id_ed25519\n' >"$home/.ssh/id_ed25519"
printf 'PRIVATE id_work_sign\n' >"$home/.ssh/id_work_sign"
printf 'PUB ed25519\n' >"$home/.ssh/id_ed25519.pub"
printf 'PUB work\n' >"$home/.ssh/id_work_sign.pub"
printf 'host example\n' >"$home/.ssh/config"
printf 'known hosts\n' >"$home/.ssh/known_hosts"

out="$(HOME="$home" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" bash "$backup")"

# 2. The recovery path survives: private keys are IN the archive payload.
payload="$(printf '%s' "$home"/.dot_backups/dotfiles-*.7z).contents/dotfiles-backup-v1"
for f in id_ed25519 id_work_sign id_ed25519.pub id_work_sign.pub config known_hosts; do
    if [ -f "$payload/ssh/$f" ]; then pass; else fail "archive payload is missing ~/.ssh/$f"; fi
done
grep -Fq 'PRIVATE id_ed25519' "$payload/ssh/id_ed25519" ||
    fail "archived private key content changed"

# 3. The count is exclusion-based and told to the person holding the file:
#    exactly 2 private keys (pubs/config/known_hosts excluded), then framing.
if grep -Fqx '  Contains 2 private key file(s) from ~/.ssh. Treat this archive as key material.' <<<"$out"; then
    pass
else
    fail "backup output must state the exact private-key count and framing; got: $out"
fi
for line in \
    '  This is disaster recovery for THIS machine, not a way to set up another one:' \
    '  give an additional machine its own keys instead (docs/ssh-agents.md).' \
    '  Re-run after rotating a key - older archives still hold the old ones.'; do
    if grep -Fqx -- "$line" <<<"$out"; then pass; else fail "backup output missing: $line"; fi
done

# 4. Restore still refuses to overwrite - asserted from the executed refusal,
#    not from the source text. A populated home trips the SSH-file refusal;
#    an existing config trips the config one first.
fresh="$tmp/home-fresh"
mkdir -p "$fresh/.ssh"
printf 'existing key\n' >"$fresh/.ssh/id_ed25519"
archive="$(printf '%s' "$home"/.dot_backups/dotfiles-*.7z)"
if err="$(HOME="$fresh" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" bash "$restore" "$archive" 2>&1)"; then
    fail "restore into a home with an existing key must be refused"
elif grep -Fq 'refusing to overwrite existing SSH file' <<<"$err"; then
    pass
else
    fail "SSH refusal did not explain itself; got: $err"
fi
if err="$(HOME="$home" PATH="$bin:$PATH" FAKE_7Z_LOG="$tmp/7z.log" bash "$restore" "$archive" 2>&1)"; then
    fail "restore into a home with an existing config must be refused"
elif grep -Fq 'refusing to overwrite existing ChezMoi config' <<<"$err"; then
    pass
else
    fail "config refusal did not explain itself; got: $err"
fi

# 5. PowerShell twin: same archive story for the operator who reads ITS output.
#    Its behavior (round-trip + refusal) is executed by tests/dotbackup_restore.ps1.
have() { require "$repo_root/$1" "$2"; }
have scripts/dotbackup.ps1 "private key file(s) from ~/.ssh"
have scripts/dotbackup.ps1 "Treat this archive as key material"
have scripts/dotbackup.ps1 "not a way to set up another one"
have scripts/dotbackup.ps1 "docs/ssh-agents.md"
have scripts/dotbackup.ps1 "Re-run after rotating a key"
# The PowerShell twin's refusal wording: its refusal BEHAVIOR is covered by
# tests/dotbackup_restore.ps1's second restore.
have scripts/dotrestore.ps1 "Refusing to overwrite existing SSH file"

finish
