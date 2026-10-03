#!/usr/bin/env bash
# Executable unittest entrypoint for the cross-platform authorization engine.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$root/tests/ssh_authorization_test.py"
echo 'PASS: authoritative incoming SSH authorization'
