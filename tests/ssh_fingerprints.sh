#!/usr/bin/env bash
# Standard-library unit tests for surgical TOML updates and fingerprint lookup.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$root/tests/ssh_fingerprints_test.py"
echo 'PASS: fingerprint synchronization preserves configuration and verifies agent identity'
