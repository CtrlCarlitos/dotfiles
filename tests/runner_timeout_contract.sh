#!/usr/bin/env bash
# Exercise timeout accounting: a timed-out test fails, but later tests still run.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$root/tests/run.sh" "$tmp/run.sh"
printf '#!/bin/bash\nsleep 10\necho PASS\n' > "$tmp/a_slow.sh"
printf '#!/bin/bash\necho PASS\n' > "$tmp/b_fast.sh"
if TEST_TIMEOUT_SECONDS=1 bash "$tmp/run.sh" --strict > "$tmp/log" 2>&1; then
    echo 'FAIL: timed-out test accepted' >&2; exit 1
fi
grep -q 'RUN  a_slow.sh' "$tmp/log"
grep -q 'FAIL a_slow.sh (exit 124)' "$tmp/log"
grep -q 'ok   b_fast.sh' "$tmp/log"
grep -q 'suite: 1 passed, 0 skipped, 1 failed' "$tmp/log"
echo 'PASS: runner reports timeout and continues with later tests'
