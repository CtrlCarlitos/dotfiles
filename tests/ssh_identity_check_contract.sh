#!/usr/bin/env bash
# ssh_identity_check contract: every SSH key filename the config references
# (accounts key/signingKey, ssh_hosts identity) must exist as a key file on
# the machine that owns keys, and `dot doctor` must say so BEFORE
# `dot ssh-fingerprints --write` dies on it (the id_penn-elcom outage,
# 2026-11-17).
#
# Pinned behaviors:
#   - every referenced key present  -> one "ok" line, exit 0
#   - a referenced key missing      -> "warn" naming the file and its source
#   - a reference that is not a bare filename -> "warn" (malformed, distinct)
#   - a WSL kernel release          -> "skip" (keys live in the Windows agent;
#     the Windows twin is authoritative)
#   - exit code is always 0: warn-only check
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$repo_root/scripts/ssh_identity_check.py"

. "$repo_root/tests/lib.sh"

[ -f "$checker" ] || { fail "ssh_identity_check.py missing"; finish; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/ssh" "$tmp/config"

config="$tmp/config/chezmoi.toml"

write_config() {
    cat > "$config" <<'EOF'
[[data.accounts]]
  name       = "Test User"
  email      = "test@example.com"
  username   = "test-user"
  key        = "id_test"
  signingKey = "id_test_sign"

[[data.ssh_hosts]]
  name     = "lab"
  hostname = "10.0.0.1"
  identity = "id_lab"
EOF
    # Optional malformed reference, appended by the caller when needed.
    if [ "${1:-}" = malformed ]; then
        cat >> "$config" <<'EOF'

[[data.ssh_hosts]]
  name     = "evil"
  hostname = "10.9.9.9"
  identity = "../evil"
EOF
    fi
}

check() { # $1=expected line pattern (ERE), $2=out, $3=label
    printf '%s\n' "$2" | grep -Eq "$1" && pass || fail "$3 - got: $2"
}

touch "$tmp/ssh/id_test" "$tmp/ssh/id_test_sign.pub" "$tmp/ssh/id_lab"

# 1. All present -> ok.
write_config
out="$(python3 "$checker" --config "$config" --ssh-dir "$tmp/ssh" --release '6.8.0-arch1-1')"
check '^ok +ssh-identities +every referenced key file exists' "$out" "ok line on all-present"

# 2. One missing -> warn naming the file and its source.
rm "$tmp/ssh/id_lab"
out="$(python3 "$checker" --config "$config" --ssh-dir "$tmp/ssh" --release '6.8.0-arch1-1')"
check '^warn +ssh-identities +.*id_lab \(ssh_host lab identity\)' "$out" "missing key named in warn"

# 3. Malformed reference -> its own warn, distinct from missing.
write_config malformed
out="$(python3 "$checker" --config "$config" --ssh-dir "$tmp/ssh" --release '6.8.0-arch1-1')"
check '^warn +ssh-identities +not a bare key filename.*evil.*ssh_host evil identity' "$out" "malformed reference warn"

# 4. WSL kernel -> skip, no file probing at all.
out="$(python3 "$checker" --config "$config" --ssh-dir "$tmp/ssh" --release '5.15.153.1-microsoft-standard-WSL2')"
check '^skip +ssh-identities +keys live in the Windows agent' "$out" "WSL skip line"

# 5. Warn-only: every verdict exits 0.
python3 "$checker" --config "$config" --ssh-dir "$tmp/ssh" --release '6.8.0-arch1-1' >/dev/null &&
    pass || fail "checker must exit 0 on warnings"

finish
