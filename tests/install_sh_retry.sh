#!/usr/bin/env bash
set -euo pipefail

# install.sh's chezmoi retry loop must actually retry under `set -e` (#108):
# the old body ran `"$@"; exitCode=$?` at top level, so the first failing
# `chezmoi init --apply` killed the script before the exit code was read and
# "Attempt N of 3" never printed. Proven for real: install.sh runs end to end
# with a stub chezmoi that fails twice and succeeds on the third attempt -
# no sudo, apt, or network (every command the bootstrap checks for is
# stubbed, and DEVCONTAINER=1 skips the gum download and the package menu).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
install_sh="$repo_root/install.sh"

. "$repo_root/tests/lib.sh"

[ -f "$install_sh" ] || { fail "install.sh missing"; exit 1; }
command -v timeout >/dev/null 2>&1 || skip "coreutils timeout not installed"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bin="$tmp/bin"
home="$tmp/home"
mkdir -p "$bin" "$home"

# Everything install.sh checks for before reaching the chezmoi step (the
# 7zz stub keeps the p7zip-full apt install out of the picture).
for c in git curl gpg wget 7zz; do
    printf '#!/bin/sh\nexit 0\n' >"$bin/$c"
    chmod +x "$bin/$c"
done

run_install() { # $1 = destination for combined output; writes the exit code to $rc
    local out_file="$1"
    rc=0
    # Neutral cwd: the repo root contains .chezmoi.toml.tmpl, which would
    # send install.sh down its `--source .` branch (the stub handles both,
    # but the test should exercise one path deterministically).
    cd "$tmp" || return 1
    env HOME="$home" DEVCONTAINER=1 CHEZMOI_RETRY_DELAY=0 STUB_DIR="$tmp" \
        PATH="$bin:$PATH" timeout 120 sh "$install_sh" >"$out_file" 2>&1 || rc=$?
    return "$rc"
}

# --- 1. Transient failure: fails twice, succeeds on attempt 3 ---------------
cat >"$bin/chezmoi" <<'EOF'
#!/bin/sh
n="$(cat "$STUB_DIR/count" 2>/dev/null || echo 0)"
n=$((n + 1))
echo "$n" >"$STUB_DIR/count"
if [ "$n" -le 2 ]; then
    echo "stub chezmoi: simulated transient failure ($n)" >&2
    exit 1
fi
: >"$STUB_DIR/applied"
EOF
chmod +x "$bin/chezmoi"

out="$tmp/flaky.log"
run_install "$out" || true

[ "$rc" -eq 0 ] ||
    fail "install.sh must exit 0 when chezmoi succeeds on a retry (got $rc): $(tail -3 "$out")"
require "$out" 'Attempt 1 of 3'
require "$out" 'Attempt 2 of 3'
[ -f "$tmp/applied" ] || fail "stub chezmoi never succeeded: $(tail -3 "$out")"
count="$(cat "$tmp/count")"
[ "$count" -eq 3 ] || fail "expected exactly 3 chezmoi invocations (2 failures + success), got $count"

# --- 2. Permanent failure: all three attempts run, then install.sh fails ----
cat >"$bin/chezmoi" <<'EOF'
#!/bin/sh
n="$(cat "$STUB_DIR/count" 2>/dev/null || echo 0)"
n=$((n + 1))
echo "$n" >"$STUB_DIR/count"
echo "stub chezmoi: always failing" >&2
exit 1
EOF
chmod +x "$bin/chezmoi"
rm -f "$tmp/count" "$tmp/applied"

out="$tmp/always.log"
run_install "$out" || true

[ "$rc" -ne 0 ] ||
    fail "install.sh must exit non-zero when chezmoi never succeeds (got $rc): $(tail -5 "$out")"
require "$out" 'Attempt 3 of 3'
count="$(cat "$tmp/count" 2>/dev/null || echo 0)"
[ "$count" -eq 3 ] || fail "expected exactly 3 attempts before giving up, got $count"

finish
