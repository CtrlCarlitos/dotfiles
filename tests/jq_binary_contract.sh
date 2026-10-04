#!/usr/bin/env bash
set -euo pipefail

# A native Windows jq.exe (chocolatey) opens stdout in text mode: under Git Bash
# every newline it prints is CRLF, `jq -r '.a|keys[]'` yields "x\r\ny\r\n", and
# `$(...)` strips only the \n. The stray \r then rides into variables, so a
# lookup of "opencode\r" misses and `dot remote tunnel render` died with
# "ingress opencode has no hostname" (32 of 33 failures of tests/remote_access.sh
# on a Windows box). `jq -b` (--binary) is jq's own switch for this; on
# Linux/macOS it is a no-op. A file-ending policy cannot reach a native
# executable's stdout, so every jq call in the product shell scripts carries -b.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

checked=0
for script in "$repo_root"/scripts/*.sh; do
    # An invocation = `jq` as a word followed by an option or a quoted filter.
    # "need jq or python3" messages and `command -v jq` do not match.
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        checked=$((checked + 1))
        line="${hit#*:}"
        if printf '%s\n' "$line" | grep -Eq 'jq[[:space:]]+(-b|--binary)([[:space:]]|$)'; then
            pass
        else
            fail "$(basename "$script"):${hit%%:*}: jq without -b (a native jq.exe emits CRLF under Git Bash): $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-90)"
        fi
    done < <(grep -n -E "(^|[^[:alnum:]_.-])jq[[:space:]]+[-'\"]" "$script" || true)
done
[ "$checked" -gt 0 ] || fail 'no jq invocation found in scripts/*.sh (the pattern no longer matches how jq is called)'

finish
