#!/usr/bin/env bash
set -euo pipefail

# Tests for scripts/select-packages.sh — the gum package-group menu.
#
# The script's contract (docs/research/package-groups-spec.md §4):
#   - no TTY or no gum  -> exit 0, "skipping menu", config untouched (CI-safe)
#   - fresh config      -> preset prompt (gum choose), then group multi-select,
#                          then write [data.packages] with exactly the 16 keys
#   - existing section  -> NO preset prompt; current true keys become the gum
#                          --selected pre-check set; rewrite ONLY the section
#   - gum canceled      -> exit 0, config untouched
#
# The real menu needs a TTY, so interactive runs go through util-linux
# `script` (pty wrapper) — that makes the gum path reachable from CI and from
# non-interactive harnesses alike. Fake gum serves canned `choose` results and
# tees its argv to $FAKE_GUM_LOG so tests can assert the --selected set.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script_under_test="$repo_root/scripts/select-packages.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass_count=0
ok() { printf '  ok: %s\n' "$1"; pass_count=$((pass_count + 1)); }

# The 16 groups in taxonomy order — the single vocabulary shared by menu,
# config, and CI (plan Global Constraints).
PKG_GROUPS=(core modern_cli fonts agent_toolkit opencode_cli opencode_desktop \
    claude_cli claude_desktop chatgpt_cli chatgpt_desktop antigravity_cli \
    antigravity_desktop dev_desktop remote_access remote_access_server guardrail)

# Canonical section body the script is expected to write.
expected_section() { # $@ = keys that are true
    local trues=("$@")
    printf '[data.packages]\n'
    local g t found
    for g in "${PKG_GROUPS[@]}"; do
        found=false
        for t in "${trues[@]}"; do
            [ "$g" = "$t" ] && found=true
        done
        if $found; then
            printf '  %s = true\n' "$g"
        else
            printf '  %s = false\n' "$g"
        fi
    done
}

list_has() { # $1 = item, rest = list
    local want="$1" item
    shift
    for item in "$@"; do [ "$item" = "$want" ] && return 0; done
    return 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"        # fake gum lives here
EMPTYBIN="$TMP/empty" # a PATH with only bash on it (no gum anywhere)
GUM_LOG="$TMP/gum.log"
mkdir -p "$BIN" "$EMPTYBIN"
ln -s "$(command -v bash)" "$EMPTYBIN/bash"

# Fake gum: logs its argv, then serves canned results.
#   choose --no-limit ... -> $FAKE_MULTI words, one per line ("__FAIL__" = exit 130)
#   choose (preset)       -> $FAKE_PRESET (default "custom")
cat >"$BIN/gum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GUM_LOG:?}"
if [[ "$*" == *--no-limit* ]]; then
    [[ "$FAKE_MULTI" == "__FAIL__" ]] && exit 130
    tr ' ' '\n' <<<"${FAKE_MULTI:?}" | sed '/^$/d'
else
    printf '%s\n' "${FAKE_PRESET:-custom}"
fi
EOF
chmod +x "$BIN/gum"

# Run the script under a pty so [ -t 0 ] holds regardless of the harness.
# $1 = FAKE_MULTI, $2 = FAKE_PRESET (default custom), $3 = HOME (default $TMP/home)
run_menu() {
    : >"$GUM_LOG"
    local home="${3:-$TMP/home}"
    timeout 30 script -qec \
        "HOME='$home' PATH='$BIN:$PATH' FAKE_GUM_LOG='$GUM_LOG' FAKE_MULTI='$1' FAKE_PRESET='${2:-custom}' bash '$script_under_test'" \
        /dev/null >/dev/null 2>&1
}

# Run without a pty (stdin is a pipe) — the CI/no-TTY path.
run_no_tty() { # $1 = HOME
    : >"$GUM_LOG"
    HOME="$1" PATH="$BIN:$PATH" FAKE_GUM_LOG="$GUM_LOG" FAKE_MULTI=x FAKE_PRESET=custom \
        bash "$script_under_test" </dev/null 2>&1
}

assert_file_equals() { # $1 = file, $2 = expected content, $3 = label
    local actual
    actual="$(cat "$1")"
    [ "$actual" = "$2" ] || fail "$3: $1 does not match expected content
--- expected ---
$2
--- actual ---
$actual
---"
}

SEED='# seeded by the test
[data]
  # keep this comment byte-identical

[[data.accounts]]
  name = "Work Account"
  email = "work@example.com"
  username = "work"
  provider = "github"
  key = "id_work"
  dirs = ["projects/work"]

[add]
  secrets = "warning"
'

# --- (a) fresh machine, no config: file created with exactly the 16 keys ----
echo "[1] fresh run creates the config with the 16 keys"
H1="$TMP/home1"
mkdir -p "$H1"
run_menu "core fonts guardrail" custom "$H1" || fail "fresh run: script exited non-zero"
CFG="$H1/.config/chezmoi/chezmoi.toml"
[ -f "$CFG" ] || fail "fresh run: $CFG was not created"
assert_file_equals "$CFG" "$(expected_section core fonts guardrail)" "(a) fresh config content"
ok "16 keys written, correct true/false values"

# preset prompt happened (section was absent): 2 gum calls
[ "$(wc -l <"$GUM_LOG")" -eq 2 ] || fail "fresh run: expected preset + groups calls, got $(wc -l <"$GUM_LOG")"
ok "preset prompt shown when no existing section"

# --- (b) existing accounts survive verbatim; section appended --------------
echo "[2] existing config gains only the packages section"
H2="$TMP/home2"
mkdir -p "$H2/.config/chezmoi"
printf '%s' "$SEED" >"$H2/.config/chezmoi/chezmoi.toml"
run_menu "core fonts guardrail" custom "$H2" || fail "seeded run: script exited non-zero"
# seed ends with a newline; the section follows after one blank line
assert_file_equals "$H2/.config/chezmoi/chezmoi.toml" \
    "${SEED}
$(expected_section core fonts guardrail)" \
    "(b) seeded config content"
ok "[[data.accounts]] and every other section byte-preserved"

# --- (c) re-run rewrites ONLY the packages section -------------------------
echo "[3] re-run with a different selection rewrites only the section"
run_menu "dev_desktop remote_access_server antigravity_desktop" custom "$H2" || fail "re-run: script exited non-zero"
assert_file_equals "$H2/.config/chezmoi/chezmoi.toml" \
    "${SEED}
$(expected_section dev_desktop remote_access_server antigravity_desktop)" \
    "(c) re-run content"
ok "only [data.packages] changed on re-run"

# --- (d) existing keys become the --selected set; no preset on re-run ------
echo "[4] re-run pre-checks existing keys"
# run 3 saw: core,fonts,guardrail = true (taxonomy order) and NO preset call
[ "$(wc -l <"$GUM_LOG")" -eq 1 ] || fail "(d): expected 1 gum call on re-run, got $(wc -l <"$GUM_LOG")"
grep -q -- '--selected core,fonts,guardrail ' "$GUM_LOG" ||
    fail "(d): --selected set is not the existing keys: $(cat "$GUM_LOG")"
ok "existing true keys became --selected, preset prompt skipped"

# --- preset mapping: full pre-checks all but the server opt-in ---------------
echo "[5] full preset omits the server opt-in"
H3="$TMP/home3"
mkdir -p "$H3"
run_menu "${PKG_GROUPS[*]}" full "$H3" || fail "preset run: script exited non-zero"
[ "$(wc -l <"$GUM_LOG")" -eq 2 ] || fail "preset run: expected 2 gum calls, got $(wc -l <"$GUM_LOG")"
head -1 "$GUM_LOG" | grep -qv -- '--no-limit' || fail "preset run: first call was not the preset prompt"
grep -q -- '--selected core,modern_cli,fonts,agent_toolkit,opencode_cli,opencode_desktop,claude_cli,claude_desktop,chatgpt_cli,chatgpt_desktop,antigravity_cli,antigravity_desktop,dev_desktop,remote_access,guardrail ' "$GUM_LOG" ||
    fail "preset run: full --selected set wrong: $(cat "$GUM_LOG")"
assert_file_equals "$H3/.config/chezmoi/chezmoi.toml" "$(expected_section "${PKG_GROUPS[@]}")" "preset run: all true"
ok "full preset omits remote_access_server; full selection persisted"

# --- installer gate: preserve an explicit value with a TOML comment ---------
echo "[6] re-run preserves the VS Code gate"
printf '%s\n' "$(expected_section core)" "  vscode_settings = false # unmanaged on this machine" >"$H3/.config/chezmoi/chezmoi.toml"
run_menu "fonts" custom "$H3" || fail "VS Code gate run: script exited non-zero"
grep -Eq '^[[:space:]]*vscode_settings[[:space:]]*=[[:space:]]*false([[:space:]]|$)' "$H3/.config/chezmoi/chezmoi.toml" ||
    fail "VS Code gate run: explicit false value was lost"
ok "explicit VS Code gate remains disabled"

# --- gum cancel: config untouched ------------------------------------------
echo "[7] canceled menu leaves the config untouched"
before="$(cat "$H2/.config/chezmoi/chezmoi.toml")"
run_menu "__FAIL__" custom "$H2" || fail "cancel run: script exited non-zero"
assert_file_equals "$H2/.config/chezmoi/chezmoi.toml" "$before" "cancel run: config changed"
ok "gum cancel = exit 0, no write"

# --- CI safety: no TTY, or no gum on PATH ----------------------------------
echo "[8] no TTY -> skipping menu"
H4="$TMP/home4"
mkdir -p "$H4"
out="$(run_no_tty "$H4")" || fail "no-tty run: script exited non-zero"
case "$out" in *"skipping menu"*) ;; *) fail "no-tty run: missing skipping message: $out" ;; esac
[ ! -e "$H4/.config/chezmoi/chezmoi.toml" ] || fail "no-tty run: config was written anyway"
[ ! -s "$GUM_LOG" ] || fail "no-tty run: gum was invoked anyway"
ok "no TTY: exit 0 + skipping message, no write, no gum call"

echo "[9] no gum on PATH -> skipping menu"
out="$(timeout 30 script -qec "HOME='$H4' PATH='$EMPTYBIN' bash '$script_under_test'" /dev/null 2>/dev/null | tr -d '\r')" ||
    fail "no-gum run: script exited non-zero"
case "$out" in *"skipping menu"*) ;; *) fail "no-gum run: missing skipping message: $out" ;; esac
ok "pty but no gum: exit 0 + skipping message"

printf 'PASS: select-packages.sh (%d assertions)\n' "$pass_count"
