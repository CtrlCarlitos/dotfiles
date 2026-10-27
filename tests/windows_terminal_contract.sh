#!/usr/bin/env bash
set -euo pipefail

# Windows Terminal contract: settings.json is a Windows-only chezmoi
# modify-template that MERGES into the file Terminal itself keeps rewriting
# (owning the whole file made every apply hit the "changed since chezmoi last
# wrote it" prompt, confirmed live). Pinned behaviors:
#   - user/Terminal-owned keys and profiles survive a merge
#   - styled profiles are updated only if present, never created - except PowerShell 7's,
#     created when pwsh.exe is installed (Terminal adds it only on its next launch, so a
#     fresh install's merge never saw it, #430 Run 7)
#   - the Meslo font is forced only once its files are installed (forcing a missing face
#     made Terminal pop "font not available" mid-install)
#   - run_after_windows-terminal-settings.ps1.tmpl repeats the same merge at the END of
#     every apply, after the package installer added pwsh and the font, and writes only
#     when the result differs (byte-identical to the modify_ output: no ping-pong)
#   - the WSL profile gets the Nerd Font back (WSL's fragment forces Ubuntu Mono)
#   - one "SSH: <name>" profile per [[data.ssh_hosts]], GUID from the name,
#     and a removed host loses its profile
#   - a "psmux" profile always exists: commandline psmux.exe and
#     startingDirectory %USERPROFILE% (a bare commandline override starts in
#     C:\Windows\System32, where starship's dir scan times out every prompt)
#   - the merge is idempotent (no ping-pong rewrites)

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpl="$repo_root/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/modify_settings.json"
ignore="$repo_root/.chezmoiignore"
config_tmpl="$repo_root/.chezmoi.toml.tmpl"

. "$repo_root/tests/lib.sh"

[ -f "$tmpl" ] || { fail "Windows Terminal modify template missing"; exit 1; }
grep -Fq 'chezmoi:modify-template' "$tmpl" || fail "settings.json must be a modify-template (merge), not an owned file"
grep -Fq 'AppData/**' "$ignore" || fail ".chezmoiignore: AppData/** must be excluded on non-Windows"
# Re-emitted either as a literal key or through the "=" column padding (printf "%-*s",
# docs/invariants.md #15); tests/config_toml_alignment_contract.sh round-trips the value.
grep -Eq '(os[[:space:]]*|"os" \}\} )=[[:space:]]*\{\{ \.os \| quote \}\}' "$config_tmpl" || fail "chezmoi.toml.tmpl: ssh_hosts os field would be dropped on re-init"

if command -v chezmoi >/dev/null && command -v jq >/dev/null; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    : >"$tmp/chezmoi.toml"
    # The merge probes the machine for pwsh.exe and the Meslo font through ProgramW6432, WINDIR
    # and LOCALAPPDATA; these fixtures stand in for them. Default: font installed, no pwsh.
    mkdir -p "$tmp/pf" "$tmp/pf7/PowerShell/7" "$tmp/win/Fonts" "$tmp/nofont/Fonts" "$tmp/lad" \
        "$tmp/ladfont/Microsoft/Windows/Fonts"
    : >"$tmp/pf7/PowerShell/7/pwsh.exe"
    : >"$tmp/win/Fonts/MesloLGSNerdFontMono-Regular.ttf"
    : >"$tmp/ladfont/Microsoft/Windows/Fonts/MesloLGSNerdFontMono-Regular.ttf"
    wt_pf="$tmp/pf" wt_win="$tmp/win" wt_lad="$tmp/lad"
    merge() {  # $1 = override data; stdin = current settings.json
        ProgramW6432="$wt_pf" WINDIR="$wt_win" LOCALAPPDATA="$wt_lad" \
            chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
            --with-stdin --file "$tmpl" --override-data "$1"
    }
    grep -Fq '{{- includeTemplate "windows-terminal-settings.json"' "$tmpl" ||
        fail "modify_settings.json must includeTemplate the shared windows-terminal-settings.json"
    hosts='{"ssh_hosts":[{"name":"mac1","hostname":"a","os":"mac"},{"name":"box","hostname":"b","os":"linux"},{"name":"nohost"}]}'
    wsl='{4e32b81b-1048-573a-93b5-97a765b27f69}'

    # Fresh machine: only the owned psmux profile - no invented styled or SSH
    # profiles.
    : | merge '{}' | jq -e '.theme == "Catppuccin Mocha" and (.profiles.list | length) == 1
        and .profiles.list[0].name == "psmux" and .profiles.list[0].commandline == "psmux.exe"
        and .profiles.list[0].startingDirectory == "%USERPROFILE%" and .profiles.list[0].tabColor == "#94E2D5"' >/dev/null ||
        fail "empty settings.json: expected theme + exactly the psmux profile (psmux.exe, %USERPROFILE% start, teal tab)"

    # Existing file with a user key, a WSL profile in Ubuntu Mono, a
    # Terminal-generated profile, a stale owned SSH profile, and a user
    # keybinding that collides with one of ours.
    cat >"$tmp/cur.json" <<JSON
{"copyOnSelect": false, "showTabsInTitlebar": false,
 "profiles": {"defaults": {"font": {"face": "Consolas"}},
   "list": [
     {"guid": "$wsl", "name": "Ubuntu-24.04", "source": "Microsoft.WSL", "font": {"face": "Ubuntu Mono"}, "colorScheme": "Ubuntu"},
     {"guid": "{01dd2430-8c3c-573c-be55-3bb966a856a1}", "name": "VS", "source": "Windows.Terminal.VisualStudio"},
     {"guid": "{00000000-0000-0000-0000-000000000000}", "name": "SSH: gone", "commandline": "ssh.exe gone"},
     {"guid": "{11111111-2222-3333-4444-555555555555}", "name": "psmux", "commandline": "psmux.exe", "startingDirectory": "C:/Windows/System32"}]},
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
    j '[.profiles.list[] | select(.name == "psmux")] | length == 1' \
        "psmux profile must exist exactly once (a stale copy is replaced, not duplicated)"
    j '.profiles.list[] | select(.name == "psmux") | .startingDirectory == "%USERPROFILE%" and .tabColor == "#94E2D5"' \
        "stale psmux profile must be re-owned: home-folder start + teal tab color forced"
    j '.profiles.list[] | select(.name == "SSH: mac1") | .tabColor == "#A6E3A1"' "mac host should get the green tab color"
    j '[.profiles.list[].guid] | all(test("^\\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\}$"))' \
        "every profile GUID must be well-formed"
    j 'any(.keybindings[]; .id == "User.keep")' "unrelated user keybinding was dropped"
    j '[.keybindings[] | select(.keys == "ctrl+shift+p")] | length == 1' "colliding chord must have exactly one owner"

    [ "$(printf '%s' "$out" | merge "$hosts")" = "$out" ] || fail "merge is not idempotent"

    # WSL styling is by source, so a distro with an unknown GUID (e.g.
    # Ubuntu-26.04 on another machine) gets the same look.
    printf '%s' '{"profiles":{"list":[{"guid":"{11111111-2222-3333-4444-555555555555}","name":"Ubuntu-26.04","source":"Microsoft.WSL","font":{"face":"Ubuntu Mono"}}]}}' |
        merge '{}' | jq -e '.profiles.list[] | select(.source == "Microsoft.WSL") | .font.face == "MesloLGS Nerd Font Mono" and .tabColor == "#FAB387"' >/dev/null ||
        fail "any Microsoft.WSL distro must get the Nerd Font + WSL tab color"

    # One order on every machine (2026-10-13: the dropdown differed per box because Terminal appends
    # generated profiles in first-seen order): PowerShell + psmux, the WSL distros by name, the SSH
    # hosts in config order, then Windows PowerShell + Command Prompt (after the hosts, by request),
    # then whatever else; Developer * and Azure Cloud Shell hidden, not removed; newTabMenu with a
    # separator between the four segments; a legacy Windows.Terminal.Wsl profile that shares its
    # name with a Microsoft.WSL one (the store generator's orphaned twin, drawn with no chord on one
    # machine) stays in the list but out of the menu. Ctrl+Shift+1..9 are Terminal's position
    # chords: the label beside index i is the default action Terminal.OpenNewTabProfile<i>'s chord
    # and ignores user bindings that take the chord, so the earlier version's User.tab<n> actions and
    # null unbinds of ctrl+shift+<n> are retired on the way through.
    grouped='{"profiles":{"list":[
      {"guid":"{574e775e-4f2a-5b96-ac1e-a2962a402336}","name":"PowerShell","source":"Windows.Terminal.PowershellCore"},
      {"guid":"{4e32b81b-1048-573a-93b5-97a765b27f69}","name":"Ubuntu-26.04","source":"Microsoft.WSL"},
      {"guid":"{61c54bbd-c2c6-5271-96e7-009a87ff44bf}","name":"Windows PowerShell"},
      {"guid":"{0caa0dad-35be-5f56-a8ff-afceeeaa6101}","name":"Command Prompt"},
      {"guid":"{b453ae62-4e3d-5e58-b989-0a998ec441b8}","name":"Azure Cloud Shell","source":"Windows.Terminal.Azure"},
      {"guid":"{01dd2430-8c3c-573c-be55-3bb966a856a1}","name":"Developer Command Prompt for VS 2022","source":"Windows.Terminal.VisualStudio"},
      {"guid":"{d3333333-3333-3333-3333-333333333333}","name":"Ubuntu-26.04","source":"Windows.Terminal.Wsl"},
      {"guid":"{a1111111-1111-1111-1111-111111111111}","name":"Ubuntu-24.04","source":"Windows.Terminal.Wsl"},
      {"guid":"{c2222222-2222-2222-2222-222222222222}","name":"Git Bash"}]},
     "actions":[{"id":"User.tab4","name":"Tab 4: x","command":{"action":"newTab","profile":"{x}"}},{"id":"User.keepme","command":"closePane"}],
     "keybindings":[{"id":"User.tab4","keys":"ctrl+shift+4"},{"id":null,"keys":"ctrl+shift+5"},{"id":null,"keys":"ctrl+q"},{"id":"User.keepme","keys":"ctrl+alt+k"}]}'
    four='{"ssh_hosts":[{"name":"web","hostname":"a","os":"linux"},{"name":"bioptic","hostname":"b"},{"name":"pc","hostname":"c"},{"name":"pennit","hostname":"d"}]}'
    g=$(printf '%s' "$grouped" | merge "$four")
    jg() { printf '%s' "$g" | jq -e "$1" >/dev/null || fail "grouped: $2"; }
    jg '[.profiles.list[].name] == ["PowerShell","psmux","Ubuntu-24.04","Ubuntu-26.04","SSH: web","SSH: bioptic","SSH: pc","SSH: pennit","Windows PowerShell","Command Prompt","Ubuntu-26.04","Azure Cloud Shell","Developer Command Prompt for VS 2022","Git Bash"]' \
        "profile order: PowerShell+psmux, WSL by name, SSH, Windows PowerShell+Command Prompt, the legacy twin, the rest (got: $(printf '%s' "$g" | jq -c '[.profiles.list[].name]'))"
    jg '[.profiles.list[] | select(.hidden == true) | .name] == ["Azure Cloud Shell","Developer Command Prompt for VS 2022"]' "Developer * and Azure Cloud Shell must be hidden, nothing else"
    jg '[.newTabMenu[] | .type] == ["profile","profile","separator","profile","profile","separator","profile","profile","profile","profile","separator","profile","profile","remainingProfiles"]' \
        "newTabMenu must draw the four segments with separators and end with remainingProfiles (got: $(printf '%s' "$g" | jq -c '[.newTabMenu[].type]'))"
    jg '(.profiles.list | map({(.guid): .name}) | add) as $n | [.newTabMenu[] | select(.type == "profile") | $n[.profile]] == ["PowerShell","psmux","Ubuntu-24.04","Ubuntu-26.04","SSH: web","SSH: bioptic","SSH: pc","SSH: pennit","Windows PowerShell","Command Prompt"]' \
        "newTabMenu entries must reference the segments by guid, in order"
    jg 'all(.newTabMenu[] | select(.type == "profile"); .profile != "{d3333333-3333-3333-3333-333333333333}") and any(.newTabMenu[]; .profile == "{4e32b81b-1048-573a-93b5-97a765b27f69}")' \
        "the legacy Windows.Terminal.Wsl twin must be left out of the menu in favour of the Microsoft.WSL profile"
    jg 'all(.actions[]; (.id // "") | test("^User\\.tab[1-9]$") | not) and any(.actions[]; .id == "User.keepme")' "the earlier User.tab<n> actions must be retired, other user actions kept"
    jg 'all(.keybindings[]; ((.id // "") | test("^User\\.tab[1-9]$") | not) and ((.id == null and ((.keys | ascii_downcase) | test("^ctrl\\+shift\\+[1-9]$"))) | not))' \
        "no ctrl+shift+<n> entry of ours may remain: Terminal's position chords label the dropdown (got: $(printf '%s' "$g" | jq -c '[.keybindings[] | select(.keys | test("^ctrl\\+shift\\+[0-9]$"))]'))"
    jg 'any(.keybindings[]; .keys == "ctrl+q" and .id == null) and any(.keybindings[]; .id == "User.keepme" and .keys == "ctrl+alt+k")' "a user's own null unbind and binding must survive the retirement"
    [ "$(printf '%s' "$g" | merge "$four")" = "$g" ] || fail "grouped merge is not idempotent"
    # Terminal 1.25 writes our file back in its own form: the legacy persistedWindowLayout becomes
    # persistedLayoutAndContent, and every newTabMenu profile entry and our theme gain explicit
    # defaults. A running Terminal rewrote the merge that way within the second, on every apply
    # (#430 Run 16). The merge must take that form as already merged, or the two never settle.
    t125=$(printf '%s' "$g" | jq '.firstWindowPreference = "persistedLayoutAndContent"
        | .newTabMenu |= map(if .type == "profile" then .icon = null else . end)
        | .themes |= map(if .name == "Catppuccin Mocha" then .tab.iconStyle = "default"
            | .window += {"experimental.rainbowFrame": false, "frame": null, "unfocusedFrame": null} else . end)')
    [ "$(printf '%s' "$t125" | merge "$four" | jq -S .)" = "$(printf '%s' "$t125" | jq -S .)" ] ||
        fail "Terminal 1.25's own form of the merge must merge to itself (got: $(diff <(printf '%s' "$t125" | jq -S .) <(printf '%s' "$t125" | merge "$four" | jq -S .) | tr '\n' '|'))"
    printf '%s' '{"firstWindowPreference":"defaultProfile","themes":[{"name":"Catppuccin Mocha","window":{"useMica":true},"tab":{"showCloseButton":"always"}}]}' | merge '{}' |
        jq -e '.firstWindowPreference == "persistedWindowLayout" and (.themes[] | select(.name == "Catppuccin Mocha") | .window.useMica == false and .tab.showCloseButton == "hover")' >/dev/null ||
        fail "any other firstWindowPreference, and our theme's own keys, must still be forced"
    bare=$(: | merge '{}')
    jq -e '([.newTabMenu[].type] == ["profile","remainingProfiles"]) and ([.keybindings[] | select(.keys | test("^ctrl\\+shift\\+[0-9]$"))] == [])' <<<"$bare" >/dev/null ||
        fail "bare machine: the menu is psmux + remainingProfiles and no chord entry is written"
    pass

    # The font is forced only once installed: a missing face pops "font not available" in a
    # running Terminal. Machine-wide (WINDIR\Fonts) or per-user (LOCALAPPDATA) both count.
    wsl_in='{"profiles":{"list":[{"guid":"{4e32b81b-1048-573a-93b5-97a765b27f69}","name":"Ubuntu-24.04","source":"Microsoft.WSL","font":{"face":"Ubuntu Mono"}}]}}'
    nf=$(printf '%s' "$wsl_in" | wt_win="$tmp/nofont" merge '{}')
    printf '%s' "$nf" | jq -e '(.profiles.defaults | has("font") | not) and .profiles.defaults.colorScheme == "Catppuccin Mocha"
        and (.profiles.list[] | select(.source == "Microsoft.WSL") | .font.face == "Ubuntu Mono" and .tabColor == "#FAB387")' >/dev/null ||
        fail "no Meslo installed: the font must not be forced (everything else still is)"
    [ "$(printf '%s' "$nf" | wt_win="$tmp/nofont" merge '{}')" = "$nf" ] || fail "font-less merge is not idempotent"
    : | wt_win="$tmp/nofont" wt_lad="$tmp/ladfont" merge '{}' | jq -e '.profiles.defaults.font.face == "MesloLGS Nerd Font Mono"' >/dev/null ||
        fail "a per-user Meslo install (LOCALAPPDATA\\Microsoft\\Windows\\Fonts) must count as installed"

    # pwsh.exe installed: the PowerShell 7 profile is created (Terminal's own guid and source, so
    # its generator merges into it), styled, first in the list and the menu - never duplicated.
    ps7='{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    p7=$(: | wt_pf="$tmp/pf7" merge '{}')
    printf '%s' "$p7" | jq -e --arg g "$ps7" '.profiles.list[0] | .guid == $g and .name == "PowerShell"
        and .source == "Windows.Terminal.PowershellCore" and .tabColor == "#89B4FA" and .hidden == false' >/dev/null ||
        fail "pwsh.exe installed: PowerShell 7 must be created first, with Terminal's guid/source and the blue tab"
    printf '%s' "$p7" | jq -e --arg g "$ps7" '.newTabMenu[0].profile == $g' >/dev/null || fail "pwsh.exe installed: PowerShell 7 must open the menu"
    [ "$(printf '%s' "$p7" | wt_pf="$tmp/pf7" merge '{}')" = "$p7" ] || fail "PowerShell 7 creation is not idempotent"
    printf '%s' "$grouped" | wt_pf="$tmp/pf7" merge "$four" | jq -e --arg g "$ps7" '[.profiles.list[] | select(.guid == $g)] | length == 1' >/dev/null ||
        fail "pwsh.exe installed and PowerShell 7 already listed: it must not be duplicated"

    # The end-of-apply pass: renders the same merge from the live file, decodes it (base64 - the
    # profile icons are not ASCII, and Windows PowerShell 5.1 reads a BOM-less script as
    # Windows-1252) and writes only on a difference.
    ra="$repo_root/run_after_windows-terminal-settings.ps1.tmpl"
    [ -f "$ra" ] || fail "run_after_windows-terminal-settings.ps1.tmpl missing (the end-of-apply merge)"
    grep -Fq 'includeTemplate "windows-terminal-settings.json"' "$ra" || fail "$ra must includeTemplate the shared merge"
    grep -Fq 'b64enc' "$ra" || fail "$ra must carry the merge base64-encoded (non-ASCII icons, 5.1 reads ANSI)"
    home="$tmp/home"; live="$home/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
    mkdir -p "$(dirname "$live")"
    # Git Bash converts paths in the environment for a native chezmoi, not inside JSON.
    home_native="$home"; command -v cygpath >/dev/null 2>&1 && home_native="$(cygpath -m "$home")"
    render_ra() {  # $1 = os
        ProgramW6432="$tmp/pf7" WINDIR="$wt_win" LOCALAPPDATA="$wt_lad" \
            chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
            --override-data "{\"chezmoi\":{\"os\":\"$1\",\"homeDir\":\"$home_native\"},\"ssh_hosts\":[{\"name\":\"mac1\",\"hostname\":\"a\",\"os\":\"mac\"}]}" <"$ra"
    }
    [ -z "$(render_ra linux | tr -d '[:space:]')" ] || fail "$ra must render empty off Windows"
    printf '%s' "$wsl_in" >"$live"
    want_live=$(printf '%s' "$wsl_in" | wt_pf="$tmp/pf7" merge '{"ssh_hosts":[{"name":"mac1","hostname":"a","os":"mac"}]}')
    if command -v pwsh >/dev/null 2>&1; then
        render_ra windows >"$tmp/ra.ps1"
        pwsh -NoProfile -File "$tmp/ra.ps1" >/dev/null 2>&1 || fail "$ra: the rendered script failed"
        [ "$(cat "$live")" = "$want_live" ] || fail "$ra must write exactly the modify_ merge of the live file (no ping-pong)"
        printf '%s' "$want_live" | jq -e --arg g "$ps7" 'any(.profiles.list[]; .guid == $g) and any(.profiles.list[]; .name == "SSH: mac1" and .icon == "🍎")' >/dev/null ||
            fail "$ra: PowerShell 7 and the SSH profile (with its non-ASCII icon) must come through"
        render_ra windows >"$tmp/ra2.ps1"
        touch -t 200101010000 "$live"; touch "$tmp/stamp"
        pwsh -NoProfile -File "$tmp/ra2.ps1" >/dev/null 2>&1 || fail "$ra: the second run failed"
        [ -z "$(find "$live" -newer "$tmp/stamp")" ] || fail "$ra rewrote an already-merged file (it must write only on a difference)"
        rm -f "$live"; render_ra windows >"$tmp/ra3.ps1"
        pwsh -NoProfile -File "$tmp/ra3.ps1" >/dev/null 2>&1 || fail "$ra must skip quietly when Terminal never created settings.json"
        [ ! -e "$live" ] || fail "$ra must not create settings.json (the modify_ target owns first creation)"
    else
        printf 'SKIP (end-of-apply run needs PowerShell): pwsh not installed\n'
    fi

    # End-to-end: a real apply of a scratch source with the shared template (docs/invariants.md #4).
    mkdir -p "$tmp/wtsrc/.chezmoitemplates" "$tmp/wtdest"
    cp "$repo_root/.chezmoitemplates/windows-terminal-settings.json" "$tmp/wtsrc/.chezmoitemplates/"
    cp "$tmpl" "$tmp/wtsrc/modify_wt.json"
    printf '{}' >"$tmp/wtdest/wt.json"
    ProgramW6432="$tmp/pf7" WINDIR="$wt_win" LOCALAPPDATA="$wt_lad" \
        chezmoi --source "$tmp/wtsrc" --destination "$tmp/wtdest" --config "$tmp/chezmoi.toml" --no-tty apply --force >/dev/null 2>&1 ||
        fail "applying the Terminal modify-template from a scratch source failed"
    jq -e --arg g "$ps7" '.profiles.list[0].guid == $g and .profiles.defaults.font.face == "MesloLGS Nerd Font Mono"' "$tmp/wtdest/wt.json" >/dev/null ||
        fail "scratch apply: expected PowerShell 7 first and the Meslo font forced"

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
    jq -e 'length == 18 and any(.[]; .key == "ctrl+alt+c") and any(.[]; .key == "ctrl+shift+w" and .command == "workbench.action.terminal.kill") and any(.[]; .key == "alt+shift+d" and .command == "workbench.action.terminal.split" and .when == "terminalFocus") and any(.[]; .key == "ctrl+0" and .command == "workbench.action.terminal.fontZoomReset")' "$tmp/dest/.kb.json" >/dev/null ||
        fail "applying the keybindings modify-template produced the wrong keybinding set (8 agent chords + 9 terminal-parity chords + Ctrl+Enter = newline expected)"
    # Alt+Left/Right move between split panes, as in Windows Terminal (focusLeft/Right) and
    # Ghostty (goto_split). terminal.focusPrevious/focusNext cycle terminal tabs instead, so
    # in a single split terminal they did nothing (#431 Run 18).
    jq -e 'any(.[]; .key == "alt+left" and .command == "workbench.action.terminal.focusPreviousPane") and any(.[]; .key == "alt+right" and .command == "workbench.action.terminal.focusNextPane") and any(.[]; .key == "ctrl+tab" and .command == "workbench.action.terminal.focusNext")' "$tmp/dest/.kb.json" >/dev/null ||
        fail "Alt+Left/Right must focus the previous/next split pane (focusPreviousPane/focusNextPane); Ctrl+Tab the next terminal"
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
    printf '%s' "$tm" | jq -e '[.profiles.list[] | select(.name | startswith("SSH: ")) | .commandline] == ["ssh.exe -t a \"tmux new-session -A -s main\"", "ssh.exe -t b \"tmux new-session -A -s work\"", "ssh.exe c"]' >/dev/null ||
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
# The cask list renders from the package catalog (#83): ghostty must be a
# dev_desktop cask there.
grep -Fq 'cask: ghostty' "$repo_root/.chezmoidata/packages.yaml" || fail "macOS dev_desktop: ghostty cask missing from .chezmoidata/packages.yaml"
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

finish
