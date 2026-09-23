#!/usr/bin/env bash
set -euo pipefail

# Windows Terminal contract: settings.json is a Windows-only chezmoi
# modify-template that MERGES into the file Terminal itself keeps rewriting
# (owning the whole file made every apply hit the "changed since chezmoi last
# wrote it" prompt, confirmed live). Pinned behaviors:
#   - user/Terminal-owned keys and profiles survive a merge
#   - styled profiles are updated only if present, never created
#   - the WSL profile gets the Nerd Font back (WSL's fragment forces Ubuntu Mono)
#   - one "SSH: <name>" profile per [[data.ssh_hosts]], GUID from the name,
#     and a removed host loses its profile
#   - the merge is idempotent (no ping-pong rewrites)

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpl="$repo_root/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/modify_settings.json"
ignore="$repo_root/.chezmoiignore"
config_tmpl="$repo_root/.chezmoi.toml.tmpl"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$tmpl" ] || fail "Windows Terminal modify template missing"
grep -Fq 'chezmoi:modify-template' "$tmpl" || fail "settings.json must be a modify-template (merge), not an owned file"
grep -Fq 'AppData/**' "$ignore" || fail ".chezmoiignore: AppData/** must be excluded on non-Windows"
grep -Fq 'os = {{ .os | quote }}' "$config_tmpl" || fail "chezmoi.toml.tmpl: ssh_hosts os field would be dropped on re-init"

if command -v chezmoi >/dev/null && command -v jq >/dev/null; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    : >"$tmp/chezmoi.toml"
    merge() {  # $1 = override data; stdin = current settings.json
        chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
            --with-stdin --file "$tmpl" --override-data "$1"
    }
    hosts='{"ssh_hosts":[{"name":"mac1","hostname":"a","os":"mac"},{"name":"box","hostname":"b","os":"linux"},{"name":"nohost"}]}'
    wsl='{4e32b81b-1048-573a-93b5-97a765b27f69}'

    # Fresh machine: empty file.
    : | merge '{}' | jq -e '.theme == "Catppuccin Mocha" and (.profiles.list | length) == 0' >/dev/null ||
        fail "empty settings.json: expected theme set and no invented profiles"

    # Existing file with a user key, a WSL profile in Ubuntu Mono, a
    # Terminal-generated profile, a stale owned SSH profile, and a user
    # keybinding that collides with one of ours.
    cat >"$tmp/cur.json" <<JSON
{"copyOnSelect": false, "showTabsInTitlebar": false,
 "profiles": {"defaults": {"font": {"face": "Consolas"}},
   "list": [
     {"guid": "$wsl", "name": "Ubuntu-24.04", "source": "Microsoft.WSL", "font": {"face": "Ubuntu Mono"}, "colorScheme": "Ubuntu"},
     {"guid": "{01dd2430-8c3c-573c-be55-3bb966a856a1}", "name": "VS", "source": "Windows.Terminal.VisualStudio"},
     {"guid": "{00000000-0000-0000-0000-000000000000}", "name": "SSH: gone", "commandline": "ssh.exe gone"}]},
 "keybindings": [{"id": "User.mine", "keys": "ctrl+shift+p"}, {"id": "User.keep", "keys": "ctrl+alt+k"}]}
JSON
    out=$(merge "$hosts" <"$tmp/cur.json")
    j() { printf '%s' "$out" | jq -e "$1" >/dev/null || fail "$2"; }
    j '.copyOnSelect == true' "copyOnSelect must be on (highlight copies, same as the VS Code terminal)"
    j '.showTabsInTitlebar == false' "user-owned global key was clobbered"
    j '.profiles.defaults.font.face == "MesloLGS Nerd Font Mono"' "defaults font not forced"
    j ".profiles.list[] | select(.guid == \"$wsl\") | .font.face == \"MesloLGS Nerd Font Mono\" and .colorScheme == \"Catppuccin Mocha\"" \
        "WSL profile must get the Nerd Font + scheme back"
    j 'any(.profiles.list[]; .source == "Windows.Terminal.VisualStudio")' "Terminal-generated profile was dropped"
    j 'all(.profiles.list[]; .guid != "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}")' "styled profile was created on a machine without it"
    j '[.profiles.list[].name | select(startswith("SSH: "))] == ["SSH: mac1", "SSH: box"]' \
        "SSH profiles: expected exactly mac1 + box (stale removed, hostless skipped)"
    j '.profiles.list[] | select(.name == "SSH: mac1") | .tabColor == "#A6E3A1"' "mac host should get the green tab color"
    j '[.profiles.list[].guid] | all(test("^\\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\}$"))' \
        "every profile GUID must be well-formed"
    j 'any(.keybindings[]; .id == "User.keep")' "unrelated user keybinding was dropped"
    j '[.keybindings[] | select(.keys == "ctrl+shift+p")] | length == 1' "colliding chord must have exactly one owner"

    [ "$(printf '%s' "$out" | merge "$hosts")" = "$out" ] || fail "merge is not idempotent"

    # WSL styling is by source, so a distro with an unknown GUID (e.g.
    # Ubuntu-26.04 on another machine) gets the same look.
    printf '%s' '{"profiles":{"list":[{"guid":"{11111111-2222-3333-4444-555555555555}","name":"Ubuntu-26.04","source":"Microsoft.WSL","font":{"face":"Ubuntu Mono"}}]}}' |
        merge '{}' | jq -e '.profiles.list[0].font.face == "MesloLGS Nerd Font Mono" and .profiles.list[0].tabColor == "#FAB387"' >/dev/null ||
        fail "any Microsoft.WSL distro must get the Nerd Font + WSL tab color"

    # Alt+Enter is unbound so it reaches the CLIs as a newline; F11 keeps full
    # screen. A user's own null-id unbind on another key must survive.
    ub=$(printf '%s' '{"keybindings":[{"id":null,"keys":"ctrl+q"},{"id":"Terminal.ToggleFullscreen","keys":"alt+enter"}]}' | merge '{}')
    printf '%s' "$ub" | jq -e '([.keybindings[] | select(.keys == "alt+enter")] == [{"id": null, "keys": "alt+enter"}])
        and any(.keybindings[]; .keys == "f11" and .id == "User.toggleFullscreen")
        and any(.keybindings[]; .keys == "ctrl+q" and .id == null)' >/dev/null ||
        fail "Alt+Enter must be unbound (F11 = full screen) without dropping other null-id unbinds"

    # Agent chords: 4 in-place + 4 split, each bound exactly once.
    j '[.actions[] | select(.id | startswith("User.agent"))] | length == 8' "expected 8 agent actions"
    j '[.keybindings[].keys] | (length == (unique | length))' "every Terminal chord must have exactly one binding"

    # VS Code keybindings: same chords on every OS (one shared template, three
    # per-OS wrappers), merged into VS Code's own JSONC.
    # includeTemplate, NOT {{ template }}: a modify-template cannot resolve
    # {{ template }} at apply time (execute-template can, which hides the bug).
    for w in "AppData/Roaming/Code/User" "Library/Application Support/Code/User" "dot_config/Code/User"; do
        grep -Fq '{{- includeTemplate "vscode-keybindings.json" . -}}' "$repo_root/$w/modify_keybindings.json" ||
            fail "$w/modify_keybindings.json must includeTemplate the shared vscode-keybindings.json"
        ! grep -Fq '{{- template "vscode-keybindings.json"' "$repo_root/$w/modify_keybindings.json" ||
            fail "$w/modify_keybindings.json: {{ template }} is not resolvable in a modify-template - use includeTemplate"
    done
    # End-to-end: a real apply of a scratch source (the path that caught it).
    mkdir -p "$tmp/src/.chezmoitemplates" "$tmp/dest"
    cp "$repo_root/.chezmoitemplates/vscode-keybindings.json" "$tmp/src/.chezmoitemplates/"
    cp "$repo_root/dot_config/Code/User/modify_keybindings.json" "$tmp/src/modify_dot_kb.json"
    printf '[]' >"$tmp/dest/.kb.json"
    chezmoi --source "$tmp/src" --destination "$tmp/dest" --config "$tmp/chezmoi.toml" --no-tty apply --force >/dev/null 2>&1
    jq -e 'length == 8 and any(.[]; .key == "ctrl+alt+c")' "$tmp/dest/.kb.json" >/dev/null ||
        fail "applying the keybindings modify-template produced no agent keys (shared template unresolved?)"
    for g in 'Library/Application Support/Code/**' '.config/Code/**' 'AppData/Roaming/Code/**'; do
        grep -Fq "$g" "$ignore" || fail ".chezmoiignore: missing VS Code keybindings guard $g"
    done
    kb_tmpl="$repo_root/dot_config/Code/User/modify_keybindings.json"
    kb() { chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" --with-stdin --file "$kb_tmpl"; }
    kb_out=$(printf '// VS Code header\n[\n  { "key": "ctrl+alt+c", "command": "old" },\n  { "key": "ctrl+k ctrl+t", "command": "keep" },\n]\n' | kb)
    printf '%s' "$kb_out" | jq -e 'any(.[]; .command == "keep") and ([.[] | select(.key == "ctrl+alt+c")] | length == 1 and .[0].command == "workbench.action.terminal.sendSequence")' >/dev/null ||
        fail "VS Code keybindings: user entries must survive and ours must own their chords"
    [ "$(printf '%s' "$kb_out" | kb)" = "$kb_out" ] || fail "VS Code keybindings merge is not idempotent"

    # tmux = true / "<name>": the profile re-attaches to a remote tmux session.
    tm=$(: | merge '{"ssh_hosts":[{"name":"a","hostname":"x","tmux":true},{"name":"b","hostname":"y","tmux":"work"},{"name":"c","hostname":"z","tmux":false}]}')
    printf '%s' "$tm" | jq -e '[.profiles.list[].commandline] == ["ssh.exe -t a \"tmux new-session -A -s main\"", "ssh.exe -t b \"tmux new-session -A -s work\"", "ssh.exe c"]' >/dev/null ||
        fail "tmux field: expected main / named session / plain ssh"

    guid() { printf '%s' "$1" | jq -r '.profiles.list[] | select(.name == "SSH: box") | .guid'; }
    [ "$(guid "$out")" = "$(guid "$(: | merge '{"ssh_hosts":[{"name":"box","hostname":"changed"}]}')")" ] ||
        fail "SSH profile GUID must depend only on the host name"
fi

# OpenCode draws its own colors (the other agent CLIs use the terminal's), so
# its TUI theme is pinned to catppuccin (dark variant = Mocha, the Terminal
# scheme) through a merge of ~/.config/opencode/tui.json on every OS.
oc_tmpl="$repo_root/dot_config/opencode/modify_tui.json"
[ -f "$oc_tmpl" ] || fail "opencode tui.json modify template missing"
if command -v chezmoi >/dev/null && command -v jq >/dev/null; then
    printf '// header\n{"theme":"opencode","keybinds":{"leader":"ctrl+x"},}\n' |
        chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" --with-stdin --file "$oc_tmpl" |
        jq -e '.theme == "catppuccin" and .keybinds.leader == "ctrl+x"' >/dev/null ||
        fail "opencode tui.json: theme must be catppuccin and user keybinds kept"
fi

# Ghostty = the Mac/Linux twin of Windows Terminal: same theme, font, clipboard
# and keys; installed only by the opt-in dev_desktop group; never on
# Windows/WSL.
gh_tmpl="$repo_root/dot_config/ghostty/config.tmpl"
[ -f "$gh_tmpl" ] || fail "Ghostty config template missing"
grep -Fq '.config/ghostty/**' "$ignore" || fail ".chezmoiignore: Ghostty must be excluded on Windows/WSL"
grep -Fq 'visual-studio-code ghostty' "$repo_root/run_onchange_install_packages.sh.tmpl" || fail "macOS dev_desktop: ghostty cask missing"
grep -Fq 'apt install -y ghostty' "$repo_root/run_onchange_install_packages.sh.tmpl" || fail "Linux dev_desktop: ghostty apt install missing"
! grep -Fq 'snap install' "$repo_root/run_onchange_install_packages.sh.tmpl" || fail "no snap packages: favor the distro package manager"
if command -v chezmoi >/dev/null; then
    for os in darwin linux; do
        cfg=$(chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
            --override-data "{\"chezmoi\":{\"os\":\"$os\"}}" <"$gh_tmpl")
        for want in 'theme = Catppuccin Mocha' 'font-family = MesloLGS Nerd Font Mono' \
            'copy-on-select = clipboard' 'right-click-action = paste' \
            'keybind = ctrl+alt+c=text:claude\r' 'keybind = chain=text:agy\r' 'toggle_quick_terminal'; do
            printf '%s\n' "$cfg" | grep -Fq -- "$want" || fail "Ghostty ($os): missing '$want'"
        done
    done
fi

echo "windows terminal contract: ok"
