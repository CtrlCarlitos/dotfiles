#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Unix-behavior test: POSIX modes, gum, and the .sh twins are not available on
# Windows (Git Bash); the PowerShell twins have their own tests and CI runs this
# on Linux. Skip rather than fail so `bash tests/*.sh` is meaningful on Windows.
case "${OSTYPE:-}" in
    msys*|cygwin*|win32) skip "dotfiles_doctor.sh is Unix-only (the .ps1 twin covers Windows)" ;;
esac

# Behavioral tests for scripts/dotfiles-doctor.sh — the dotfiles-level
# complement to `chezmoi doctor`, covering failure classes this repo has
# actually hit live:
#   - config saved as Windows-1252 (WinMerge/Notepad-ANSI edit class:
#     one 0x97 em dash broke `chezmoi init --apply` mid-install on Windows)
#   - config that doesn't parse at all
#   - prompted keys missing from the live config (the "map has no entry for
#     key" outage class; check_workflow_config_keys.sh guards CI seeds only)
#
# Runs the real script with HOME pointed at fixture dirs; the real chezmoi
# binary handles parse/data checks (skip the suite if it's absent).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
doctor="$repo_root/scripts/dotfiles-doctor.sh"

command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
command -v iconv >/dev/null 2>&1 || { fail "iconv required"; exit 1; }

[ -x "$doctor" ] || fail "scripts/dotfiles-doctor.sh missing or not executable"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Full valid config: every prompted key present (primary* + 17 packages).
valid_config() { # $1 = target dir
    mkdir -p "$1/.config/chezmoi"
    cat > "$1/.config/chezmoi/chezmoi.toml" <<'EOF'
primaryName = "Probe User"
primaryEmail = "probe@example.com"
primaryUsername = "probe"
primaryKey = "id_probe"

[data.packages]
core = true
modern_cli = false
fonts = false
agent_toolkit = false
opencode_cli = false
opencode_desktop = false
claude_cli = false
claude_desktop = false
chatgpt_cli = false
chatgpt_desktop = false
antigravity_cli = false
antigravity_desktop = false
dev_desktop = false
remote_access = false
remote_access_server = false
guardrail = true
mobile_dev = false
EOF
}

# [1] Valid config: exit 0, no error results.
H="$TMP/home-valid"; valid_config "$H"
out="$(env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor")" ||
    fail "[1] valid config should pass; got: $out"
grep -q 'config-utf8' <<<"$out" || fail "[1] utf-8 check not reported: $out"
# The repo version rides along with every doctor run (same line as `dot version`),
# informational only: never a warn/error, so it cannot fail a valid config.
grep -Eq '^(ok|skip) +dotfiles-version ' <<<"$out" || fail "[1] dotfiles-version not reported: $out"
echo "  ok: valid config passes"

# [2] cp1252 config: detected, --fix converts, re-run passes.
H="$TMP/home-cp1252"; valid_config "$H"
printf '  # saved by an ANSI editor \x97 oops\n' >> "$H/.config/chezmoi/chezmoi.toml"
env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" >/dev/null 2>&1 &&
    fail "[2] cp1252 config must fail"
env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" --fix >/dev/null ||
    fail "[2] --fix must succeed on pure cp1252"
env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" >/dev/null ||
    fail "[2] config should pass after --fix"
echo "  ok: cp1252 detected and fixed"

# [3] Mixed encodings: --fix must refuse.
H="$TMP/home-mixed"; valid_config "$H"
printf '  # valid utf-8 em dash \xe2\x80\x94 here\n' >> "$H/.config/chezmoi/chezmoi.toml"
printf '  # stray cp1252 byte \x97 here\n' >> "$H/.config/chezmoi/chezmoi.toml"
env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" >/dev/null 2>&1 &&
    fail "[3] mixed encoding must fail"
env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" --fix >/dev/null 2>&1 &&
    fail "[3] --fix must refuse mixed encodings"
# the stray byte must still be there (refused fix = no transcode): still fails
env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" >/dev/null 2>&1 &&
    fail "[3] mixed file must still fail after refused fix"
echo "  ok: mixed encodings refused"

# [4] Missing prompted key: named in output, exit 1.
H="$TMP/home-missing"; valid_config "$H"
sed -i '/^guardrail = /d' "$H/.config/chezmoi/chezmoi.toml"
env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" >/dev/null 2>&1 &&
    fail "[4] missing key must fail"
out4="$(env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" 2>&1 || true)"
grep -q 'guardrail' <<<"$out4" || fail "[4] missing key not named in output: $out4"
echo "  ok: missing prompted key reported"

# [5] Unparseable TOML: parse check fails (independent of key presence).
H="$TMP/home-broken"; valid_config "$H"
printf 'this is not toml [[[\n' >> "$H/.config/chezmoi/chezmoi.toml"
env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" >/dev/null 2>&1 &&
    fail "[5] unparseable config must fail"
echo "  ok: unparseable config reported"

# [5b] Regression: the parse check must inspect the SAME file as every other
# check. chezmoi resolves its own config through XDG_CONFIG_HOME, so where that
# points elsewhere (GitHub runners set it; so do many desktops) a bare
# `chezmoi data` validated a different, usually absent, config and reported
# "chezmoi loads the config" while $config was broken. Caught only once this
# test was wired into CI - it had never run anywhere. XDG_CONFIG_HOME is pinned
# here rather than inherited, so the divergence is exercised on every machine.
H="$TMP/home-xdg"; valid_config "$H"
printf 'this is not toml [[[
' >> "$H/.config/chezmoi/chezmoi.toml"
mkdir -p "$TMP/xdg-elsewhere"
env -u CHEZMOI_CONFIG_DIR HOME="$H" XDG_CONFIG_HOME="$TMP/xdg-elsewhere" bash "$doctor" >/dev/null 2>&1 &&
    fail "[5b] parse check followed XDG_CONFIG_HOME instead of the config under test"
echo "  ok: parse check pinned to the config under test"

# [6a] In-apply mode: sub-chezmoi checks are skipped (chezmoi holds its
# persistent-state lock during apply - a nested chezmoi call deadlocks).
H="$TMP/home-inapply"; valid_config "$H"
out="$(env -u CHEZMOI_CONFIG_DIR HOME="$H" DOTFILES_DOCTOR_IN_APPLY=1 bash "$doctor" || true)"
grep -q 'in-apply mode' <<<"$out" || fail "[6a] in-apply skips not reported: $out"
grep -q 'config-parse     chezmoi loads' <<<"$out" &&
    fail "[6a] in-apply mode must not run chezmoi data (state-lock deadlock)"
echo "  ok: in-apply mode skips chezmoi-invoking checks"

# [6b] A source dir that is NOT a git repo (interrupted first install class)
# must be reported clean: the dirtiness checks are only meaningful inside a
# repo, and unbraced `A && !B || !C` turned the failed `git diff --cached`
# of a non-repo into a bogus "uncommitted changes" warning.
H="$TMP/home-nongit"; valid_config "$H"
mkdir -p "$H/.local/share/chezmoi"
printf 'stray file\n' > "$H/.local/share/chezmoi/stray"
out7="$(env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" 2>&1 || true)"
grep -q 'source-dir' <<<"$out7" || fail "[6b] source-dir not reported: $out7"
grep -q '(clean)' <<<"$out7" || fail "[6b] non-git source dir must pass as clean: $out7"
grep -q 'uncommitted' <<<"$out7" && fail "[6b] non-git source dir flagged uncommitted: $out7"
echo "  ok: non-git source dir reported clean"

# [6c] Contract: chezmoi runs the doctor after every apply, never with the
# fix flag, and a failure stops the apply with guidance.
run_after_sh="$repo_root/run_after_dotfiles-doctor.sh.tmpl"
run_after_ps1="$repo_root/run_after_dotfiles-doctor.ps1.tmpl"
for f in "$run_after_sh" "$run_after_ps1"; do
    [ -f "$f" ] || fail "[6] $f missing (apply-time health check)"
    grep -Fq 'dotfiles-doctor' "$f" || fail "[6] $f does not invoke the doctor"
    ! grep -Eq -- '--fix|-Fix' <<<"$(grep -v 'no --fix\|no -Fix\|# ' "$f")" ||
        fail "[6] $f invokes the fix flag - repairs must stay manual"
    grep -Fq 'exit 1' "$f" || fail "[6] $f must stop the apply on doctor failure"
done
echo "  ok: run_after hook stops apply on doctor errors (no auto-fix)"

# [7] CRLF violates the SSH text policy on all platforms.
H="$TMP/home-crlf"; valid_config "$H"
mkdir -p "$H/.ssh/nested"
printf 'Host example\r\n# lone\rCR\n' > "$H/.ssh/nested/config with spaces"
printf '\000\r\n\377' > "$H/.ssh/binary"
cp "$H/.ssh/binary" "$TMP/binary-before"
printf 'outside\r\n' > "$TMP/outside"
ln -s "$TMP/outside" "$H/.ssh/linked"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIprobe comment\r\n' > "$H/.ssh/id_probe.pub"
printf '%s\r\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'b3BlbnNzaC1rZXktdjEAAAAA' '-----END OPENSSH PRIVATE KEY-----' > "$H/.ssh/id_probe"
out="$(env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor")" || true
grep -q 'warn.*ssh-crlf' <<<"$out" || fail "[7] CRLF not detected: $out"
grep -q $'\r' "$H/.ssh/id_probe.pub" || fail '[7] read-only doctor changed file'
env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" --fix >/dev/null 2>&1 ||
    fail "[7] --fix must succeed stripping CRLF"
if grep -q $'\r' "$H/.ssh/id_probe.pub" || grep -q $'\r' "$H/.ssh/id_probe"; then
    fail "[7] CRLF must be stripped after --fix"
fi
printf 'Host example\n# lone\rCR\n' > "$TMP/expected"
cmp "$TMP/expected" "$H/.ssh/nested/config with spaces" || fail '[7] nested text conversion changed other bytes'
cmp "$TMP/binary-before" "$H/.ssh/binary" || fail '[7] binary changed'
grep -q $'\r' "$TMP/outside" || fail '[7] symlink target changed'
out="$(env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor")"
if grep -q 'warn.*ssh-crlf' <<<"$out"; then fail '[7] CRLF warning persists after repair'; fi
env -u CHEZMOI_CONFIG_DIR HOME="$H" bash "$doctor" >/dev/null 2>&1 ||
    fail "[7] doctor should pass after CRLF strip"
echo "  ok: CRLF key files detected and stripped"

# [8] Parity: the PowerShell doctor's own hardcoded $keys list (it can't
# source the bash lib) must list exactly as many package groups as the
# shared bash PKG_GROUPS taxonomy - a silent miscount here is exactly how
# mobile_dev went unchecked on Windows in the first place.
. "$repo_root/scripts/lib/chezmoi-config.sh"
ps1_doctor="$repo_root/scripts/dotfiles-doctor.ps1"
ps1_keys_line="$(grep -m1 '^\s*\$keys = @(' "$ps1_doctor")"
ps1_keys_block="$ps1_keys_line
$(awk '/\$keys = @\(/{f=1} f{print; if (/\)/) exit}' "$ps1_doctor" | tail -n +2)"
ps1_key_count="$(printf '%s' "$ps1_keys_block" | grep -o "'[a-zA-Z0-9_]*'" | wc -l | tr -d ' ')"
if [ "$ps1_key_count" -ne "${#PKG_GROUPS[@]}" ]; then
    fail "scripts/dotfiles-doctor.ps1's \$keys list has $ps1_key_count entries, PKG_GROUPS has ${#PKG_GROUPS[@]} - they must match"
fi
echo "  ok: dotfiles-doctor.ps1's \$keys list matches PKG_GROUPS in count ($ps1_key_count)"

finish
