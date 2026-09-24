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
# So the checks below are about honesty and framing, not about excluding keys.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

have() { grep -Fq -- "$2" "$repo_root/$1" || fail "$1: missing '$2'"; }

# 1. Keys are still backed up. If someone "tidies" this away, the recovery path
#    for a non-GitHub server key disappears with it.
# shellcheck disable=SC2016  # literal $HOME: matching the script's source text
grep -q 'find "$HOME/.ssh" -type f -print0' "$repo_root/scripts/dotbackup.sh" ||
    fail "scripts/dotbackup.sh no longer collects ~/.ssh - that is the disaster-recovery path"
grep -Fq 'ssh' "$repo_root/scripts/dotbackup.ps1" ||
    fail "scripts/dotbackup.ps1 no longer collects ~/.ssh"

# 2. Both twins say what the archive holds. The docs listed it; the person
#    holding the file is the one who needs to be told.
for f in scripts/dotbackup.sh scripts/dotbackup.ps1; do
    have "$f" "private key file(s) from ~/.ssh"
    have "$f" "Treat this archive as key material"
    have "$f" "not a way to set up another one"
    have "$f" "docs/ssh-agents.md"
    have "$f" "Re-run after rotating a key"
done

# 3. The count is taken by EXCLUSION - nothing in the backup path opens a
#    private key to identify it. Reading key material to count it would be a
#    silly way to leak it into a log or a crash dump.
if grep -Fq 'BEGIN' "$repo_root/scripts/dotbackup.sh"; then
    fail "scripts/dotbackup.sh appears to inspect key contents - count by filename instead"
fi
grep -Fq "*.pub | config | known_hosts" "$repo_root/scripts/dotbackup.sh" ||
    fail "scripts/dotbackup.sh: key counting is no longer exclusion-based"

# 4. Restore still refuses to overwrite. This is what stops the archive from
#    quietly becoming a provisioning tool for a second live machine.
have scripts/dotrestore.sh "refusing to overwrite existing SSH file"
have scripts/dotrestore.ps1 "Refusing to overwrite existing SSH file"

# 5. The docs carry the distinction, and each points at the other, so a reader
#    landing on either one finds the case it does not cover.
have docs/backup-restore.md "## What This Is For"
have docs/backup-restore.md "not how you set up an additional machine"
have docs/backup-restore.md "(ssh-agents.md)"
have docs/backup-restore.md "When a key rotates"
have docs/ssh-agents.md "(backup-restore.md)"
have docs/ssh-agents.md "If the machine dies"

if [ "$failures" -gt 0 ]; then
    printf '\nFAIL: backup key handling (%d problem(s))\n' "$failures" >&2
    exit 1
fi
printf 'PASS: backups keep keys for recovery, say so, and cannot provision a second machine\n'
