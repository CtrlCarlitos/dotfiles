#!/usr/bin/env bash
set -euo pipefail

# Codex config merge contract (dot_codex/modify_config.toml).
#
# ~/.codex/config.toml is rewritten by Codex itself - per-project trust levels
# keyed by absolute path, SHA-256 hook hashes, model-migration notices. The
# template must therefore force exactly one key (tui.keymap.editor.insert_newline)
# and pass every other byte through untouched. A bug here does not merely lose a
# setting: a duplicate table or a dangling array element makes config.toml
# unparseable and Codex refuses to start.
#
# Each case renders the template with a crafted config on stdin and asserts both
# halves: our key won, and the surrounding content survived.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/dot_codex/modify_config.toml"
want='insert_newline = ["shift-enter", "ctrl-j", "ctrl-enter", "alt-enter"]'

. "$repo_root/tests/lib.sh"

[ -f "$template" ] || { fail "dot_codex/modify_config.toml missing"; exit 1; }

# 1. Static guarantees that hold without chezmoi installed.
head -n 1 "$template" | grep -Fq 'chezmoi:modify-template' ||
    fail "template lacks the chezmoi:modify-template directive on line 1 - chezmoi would treat it as a plain file and OWN config.toml"

# Go's lexer only recognises a comment action when "/*" sits exactly two bytes
# after "{{"; `{{-     /*` parses as a command and fails with "unexpected /".
# This cost a debugging round once - keep it impossible to reintroduce.
! grep -nE '\{\{-[[:space:]]{2,}/\*' "$template" ||
    fail "indented template comment: use '{{- /*' exactly (Go parses '{{-   /*' as a command)"

# The template holds the path and the value separately ($forced), so assert the
# value literal and the key path, not the rendered line.
grep -Fq -- '["shift-enter", "ctrl-j", "ctrl-enter", "alt-enter"]' "$template" ||
    fail "template no longer carries the expected newline binding list"
grep -Fq -- 'tui.keymap.editor.insert_newline' "$template" ||
    fail "template no longer forces tui.keymap.editor.insert_newline"

if ! command -v chezmoi >/dev/null 2>&1; then
    skip "codex keymap contract (static checks only - requires chezmoi)"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_config() { chezmoi execute-template --with-stdin --file "$template"; }

assert_once() {
    # $1 = file, $2 = description. Exactly one binding, one owning table.
    local n
    n="$(grep -c '^insert_newline = ' "$1" || true)"
    [ "$n" = 1 ] || fail "$2: expected 1 insert_newline line, got $n"
    n="$(grep -c '^\[tui\.keymap\.editor\]$' "$1" || true)"
    [ "$n" = 1 ] || fail "$2: expected 1 [tui.keymap.editor] table, got $n"
    grep -Fqx -- "$want" "$1" || fail "$2: forced binding not present verbatim"
}

# 2. Empty config (a machine where Codex has never run).
: | render_config > "$tmp/empty.out"
assert_once "$tmp/empty.out" "empty input"

# 3. A realistic Codex-written config: the table is appended, and every
#    machine-specific line survives byte-for-byte.
cat > "$tmp/real.toml" <<'EOF'
model = "gpt-5.6-sol"

[projects.'C:\Users\me\projects\thing']
trust_level = "trusted"

[tui.model_availability_nux]
gpt-6-astra = 4

[hooks.state.'C:\Users\me\.codex\hooks.json:stop:0:0']
trusted_hash = "sha256:deadbeef"
EOF
render_config < "$tmp/real.toml" > "$tmp/real.out"
assert_once "$tmp/real.out" "realistic config"
while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -Fqx -- "$line" "$tmp/real.out" ||
        fail "realistic config: template dropped or rewrote the line: $line"
done < "$tmp/real.toml"

# 4. Idempotent: applying to our own output changes nothing. (chezmoi re-runs
#    modify templates on every apply; drift here would mean an endless diff.)
render_config < "$tmp/real.out" > "$tmp/real.out2"
diff -u "$tmp/real.out" "$tmp/real.out2" >/dev/null ||
    fail "not idempotent: a second render changes the file"

# 5. An existing, conflicting binding in the owned table is replaced in place -
#    not duplicated - and the user's other editor keys are kept.
cat > "$tmp/conflict.toml" <<'EOF'
[tui.keymap.editor]
insert_newline = ["ctrl-j"]
kill_whole_line = ["ctrl-u"]
EOF
render_config < "$tmp/conflict.toml" > "$tmp/conflict.out"
assert_once "$tmp/conflict.out" "conflicting binding"
! grep -Fq '["ctrl-j"]' "$tmp/conflict.out" || fail "conflicting binding: old value survived"
grep -Fq 'kill_whole_line' "$tmp/conflict.out" ||
    fail "conflicting binding: unrelated editor key was dropped"

# 6. A multi-line array value is swallowed whole. Dropping only its first line
#    would leave orphan elements behind and break the TOML.
cat > "$tmp/multiline.toml" <<'EOF'
[tui.keymap.editor]
insert_newline = [
  "ctrl-j",
  "shift-enter",
]
kill_whole_line = ["ctrl-u"]
EOF
render_config < "$tmp/multiline.toml" > "$tmp/multiline.out"
assert_once "$tmp/multiline.out" "multi-line array"
# An orphan is a line that is ONLY an array element; the forced one-line value
# legitimately contains `"ctrl-j",` inside it, so anchor the match.
! grep -Eq '^[[:space:]]*"[a-z-]+",?[[:space:]]*$|^[[:space:]]*\]$' "$tmp/multiline.out" ||
    fail "multi-line array: orphan continuation line left behind"
grep -Fq 'kill_whole_line' "$tmp/multiline.out" ||
    fail "multi-line array: skipped past the end of the value"

# 7. The dotted top-level spelling of the same key is recognised, so we never
#    end up with both `tui.keymap.editor.insert_newline` and a table defining
#    it (a duplicate-key error in TOML).
cat > "$tmp/dotted.toml" <<'EOF'
tui.keymap.editor.insert_newline = ["ctrl-j"]
model = "gpt-5.6-sol"
EOF
render_config < "$tmp/dotted.toml" > "$tmp/dotted.out"
grep -Fq 'tui.keymap.editor.insert_newline = ["shift-enter", "ctrl-j", "ctrl-enter", "alt-enter"]' "$tmp/dotted.out" ||
    fail "dotted key: not replaced in place"
! grep -q '^\[tui\.keymap\.editor\]$' "$tmp/dotted.out" ||
    fail "dotted key: a duplicate table was appended anyway"

# 8. Every rendered case is valid TOML. This is the assertion that matters -
#    the others describe intent, this one catches the config that won't load.
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    py="$(command -v python3 || command -v python)"
    if "$py" -c 'import tomllib' 2>/dev/null; then
        for f in "$tmp"/*.out "$tmp"/*.out2; do
            "$py" - "$f" <<'PY' || fail "rendered output is not valid TOML: see above"
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    try:
        tomllib.load(fh)
    except Exception as exc:
        print(f"{sys.argv[1]}: {exc}", file=sys.stderr)
        raise SystemExit(1)
PY
        done
    fi
fi

finish
