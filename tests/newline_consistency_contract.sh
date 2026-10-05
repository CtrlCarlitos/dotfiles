#!/usr/bin/env bash
set -euo pipefail

# Ctrl+Enter must be a newline in claude, codex, opencode and agy, in every terminal we
# manage. History: it used to arrive as a plain line feed (= Ctrl+J) everywhere, so it was
# a newline by accident. Claude Code 2.1.275 bound Ctrl+Enter to chat:sendNow ("send right
# away") and asks terminals for extended keys, so the same keypress started SENDING.
# Two layers keep it a newline, both executed here:
#   terminal  Windows Terminal action User.newline (sendInput LF), the VS Code terminal
#             keybinding (sendSequence LF), Ghostty `keybind = ctrl+enter=text:\n`
#   harness   ~/.claude/keybindings.json merge: "ctrl+enter": "chat:newline"
#             (Codex is pinned by codex_keymap_contract.sh; OpenCode and agy are native)
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null || { printf 'SKIP: chezmoi not installed\n'; exit 0; }
command -v jq >/dev/null || { printf 'SKIP: jq not installed\n'; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/chezmoi.toml"
render() { # $1 = template file, stdin = current target (may be empty), $2 = override data
    chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
        --with-stdin --file "$1" --override-data "${2:-{\}}"
}
# jq on Windows emits CRLF unless told otherwise
jqe() { jq -b "$@" 2>/dev/null || jq "$@"; }

# --- Claude Code keybindings merge ---------------------------------------------------------
kb="$repo_root/dot_claude/modify_keybindings.json"
[ -f "$kb" ] || fail "dot_claude/modify_keybindings.json is missing"

out="$(: | render "$kb")"
printf '%s' "$out" | jqe -e '.bindings | length == 1 and .[0].context == "Chat"
    and .[0].bindings["ctrl+enter"] == "chat:newline"' >/dev/null \
    || fail "an absent keybindings.json must be created with Chat ctrl+enter -> chat:newline (got: $out)"
printf '%s' "$out" | jqe -e '."$schema" | test("claude-code-keybindings")' >/dev/null \
    || fail "a created keybindings.json must carry the \$schema"

mine='{"bindings":[{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos"}},
  {"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor","ctrl+s":null,"ctrl+enter":"chat:sendNow"}}],"custom":1}'
out="$(printf '%s' "$mine" | render "$kb")"
printf '%s' "$out" | jqe -e '.custom == 1
    and (.bindings | length) == 2
    and .bindings[0].bindings["ctrl+t"] == "app:toggleTodos"
    and .bindings[1].bindings["ctrl+e"] == "chat:externalEditor"
    and (.bindings[1].bindings | has("ctrl+s")) and .bindings[1].bindings["ctrl+s"] == null
    and .bindings[1].bindings["ctrl+enter"] == "chat:newline"' >/dev/null \
    || fail "merge must force ctrl+enter to chat:newline (replacing sendNow) and keep every other binding, block and key (got: $out)"

out="$(printf '%s' '{"bindings":[{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos"}}]}' | render "$kb")"
printf '%s' "$out" | jqe -e '(.bindings | length) == 2 and .bindings[0].context == "Global"
    and .bindings[1].context == "Chat" and .bindings[1].bindings["ctrl+enter"] == "chat:newline"' >/dev/null \
    || fail "with no Chat block, one must be appended after the user's blocks (got: $out)"

withcomments='// my keys
{"bindings":[{"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor",},},],}'
out="$(printf '%s' "$withcomments" | render "$kb")"
printf '%s' "$out" | jqe -e '.bindings[0].bindings["ctrl+e"] == "chat:externalEditor"
    and .bindings[0].bindings["ctrl+enter"] == "chat:newline"' >/dev/null \
    || fail "full-line // comments and trailing commas must not break the merge (got: $out)"

again="$(printf '%s' "$out" | render "$kb")"
[ "$again" = "$out" ] || fail "the keybindings merge must be idempotent (no ping-pong rewrites)"
pass

# --- the ignore rule lets exactly that one file through, only where ~/.claude exists --------
render_ignore() { # $1 = fake home
    HOME="$1" USERPROFILE="$1" chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
        --file "$repo_root/.chezmoiignore" </dev/null
}
mkdir -p "$tmp/home-with/.claude" "$tmp/home-without"
render_ignore "$tmp/home-with" | grep -Fxq '!.claude/keybindings.json' \
    || fail ".chezmoiignore must un-ignore .claude/keybindings.json when ~/.claude exists"
render_ignore "$tmp/home-with" | grep -Fxq '.claude/*' \
    || fail ".chezmoiignore must keep ignoring the rest of ~/.claude (.claude/*, not .claude/**: ** also ignores the directory itself, which makes the exception unreachable)"
# End to end: a real apply creates the file where ~/.claude exists, and nothing where it does not.
apply_kb() { # $1 = fake home
    HOME="$1" USERPROFILE="$1" chezmoi --config "$tmp/chezmoi.toml" --source "$repo_root" --destination "$1" \
        --no-tty apply --force "$1/.claude/keybindings.json" >/dev/null 2>&1 || true
}
apply_kb "$tmp/home-with"
[ -f "$tmp/home-with/.claude/keybindings.json" ] \
    && jq -e '.bindings[0].bindings["ctrl+enter"] == "chat:newline"' "$tmp/home-with/.claude/keybindings.json" >/dev/null \
    || fail "a real chezmoi apply must create ~/.claude/keybindings.json with ctrl+enter -> chat:newline"
apply_kb "$tmp/home-without"
[ ! -e "$tmp/home-without/.claude" ] || fail "no ~/.claude: the apply must not create it"
if render_ignore "$tmp/home-without" | grep -Fq '!.claude/keybindings.json'; then
    fail "no ~/.claude means no keybindings.json: a modify_ template would create the file for a tool that is not installed"
fi
pass

# --- Windows Terminal: User.newline sends LF on ctrl+enter ----------------------------------
wt="$repo_root/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/modify_settings.json"
out="$(printf '%s' '{"keybindings":[{"id":"User.mine","keys":"ctrl+alt+k"}]}' | render "$wt" '{}')"
printf '%s' "$out" | jqe -e '
    ([.actions[] | select(.id == "User.newline")][0].command == {"action": "sendInput", "input": "\n"})
    and ([.keybindings[] | select(.keys == "ctrl+enter")] == [{"id": "User.newline", "keys": "ctrl+enter"}])
    and any(.keybindings[]; .id == "User.mine")' >/dev/null \
    || fail "Windows Terminal: ctrl+enter must be bound to User.newline = sendInput LF, keeping user keybindings"
pass

# --- VS Code integrated terminal: sendSequence LF on ctrl+enter ------------------------------
vsc="$repo_root/dot_config/Code/User/modify_keybindings.json"
out="$(printf '%s' '[{"key":"ctrl+k","command":"user.keep"}]' | render "$vsc" '{}')"
printf '%s' "$out" | jqe -e '
    ([.[] | select(.key == "ctrl+enter")] | length == 1)
    and ([.[] | select(.key == "ctrl+enter")][0]
         | .command == "workbench.action.terminal.sendSequence" and .args.text == "\n" and .when == "terminalFocus")
    and any(.[]; .command == "user.keep")' >/dev/null \
    || fail "VS Code: ctrl+enter must send LF to the focused terminal only (when terminalFocus), keeping user keybindings"
pass

# --- Ghostty --------------------------------------------------------------------------------
gh="$(: | render "$repo_root/dot_config/ghostty/config.tmpl" '{}')"
printf '%s\n' "$gh" | grep -Fxq 'keybind = ctrl+enter=text:\n' \
    || fail 'Ghostty: need `keybind = ctrl+enter=text:\n` (kitty protocol would otherwise deliver a distinct Ctrl+Enter)'
pass

finish
