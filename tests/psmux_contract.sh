#!/usr/bin/env bash
set -euo pipefail

# psmux contract: dot_config/psmux/psmux.conf is the Windows twin of
# dot_tmux.conf. psmux (Chocolatey "psmux") is a native Windows tmux that
# reads tmux-compatible config, so the two multiplexers must feel like one
# tool: same prefix, same keys, same copy mode, same Catppuccin bar. The
# "uniform" list below is asserted VERBATIM in BOTH files - change a binding
# in one and CI fails until it is changed in the other.
#
# Not uniform, on purpose:
#   tmux-only: TPM + resurrect/continuum, the per-OS copy pipes
#              (clip.exe/xclip/wl-copy/pbcopy), ~/.tmux.conf reload path
#   psmux-only: set-clipboard (OSC 52 to Windows Terminal), pwsh panes,
#               ~/.config/psmux/psmux.conf reload path
# Windows-only deployment: no psmux outside Windows (ConPTY), same rule as
# Windows Terminal's AppData/** in .chezmoiignore.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmux_conf="$repo_root/dot_tmux.conf"
psmux_conf="$repo_root/dot_config/psmux/psmux.conf"

. "$repo_root/tests/lib.sh"

[ -f "$tmux_conf" ] || { fail "dot_tmux.conf missing"; exit 1; }
[ -f "$psmux_conf" ] || { fail "dot_config/psmux/psmux.conf missing (psmux reads it first in its search order on Windows)"; exit 1; }

# Uniform in both multiplexers: these exact lines must exist in each file.
for line in \
    'set -g mouse on' \
    'set -g base-index 1' \
    'setw -g pane-base-index 1' \
    'set -g renumber-windows on' \
    'set -g history-limit 50000' \
    'set -s escape-time 0' \
    'set -g focus-events on' \
    'setw -g mode-keys vi' \
    'set -g prefix C-a' \
    'bind C-a send-prefix' \
    'bind | split-window -h -c "#{pane_current_path}"' \
    'bind - split-window -v -c "#{pane_current_path}"' \
    'bind c new-window -c "#{pane_current_path}"' \
    'bind -T copy-mode-vi v send -X begin-selection' \
    'bind -T copy-mode-vi y send -X copy-selection-and-cancel' \
    'set -g status-position bottom' \
    'set -g status-style "bg=#1e1e2e,fg=#cdd6f4"' \
    'set -g pane-border-style "fg=#45475a"' \
    'set -g pane-active-border-style "fg=#89b4fa"' \
    ; do
    grep -Fq "$line" "$tmux_conf" || fail "dot_tmux.conf: uniform line missing: $line"
    grep -Fq "$line" "$psmux_conf" || fail "psmux.conf: uniform line missing (drift from tmux): $line"
done

# psmux-only behavior.
grep -Fq 'set -s set-clipboard on' "$psmux_conf" ||
    fail "psmux.conf: set-clipboard must be on (OSC 52 reaches Windows Terminal's clipboard)"
grep -Fq 'default-shell pwsh' "$psmux_conf" ||
    fail "psmux.conf: panes must run pwsh, like the Windows Terminal profiles"
grep -Fq 'source-file ~/.config/psmux/psmux.conf' "$psmux_conf" ||
    fail "psmux.conf: prefix+r must reload this file"
grep -Fq 'scan_timeout = 100' "$repo_root/dot_config/starship.toml" ||
    fail "starship.toml: scan_timeout must be raised (the 30ms default times out on big Windows directories)"

# tmux-only, by design: must NOT leak into psmux.
! grep -q '@plugin' "$psmux_conf" ||
    fail "psmux.conf: TPM plugins have no psmux equivalent"
! grep -q 'copy-pipe' "$psmux_conf" ||
    fail "psmux.conf: copy-pipe is tmux's route to the OS clipboard; psmux copies natively"

# Windows-only deployment.
grep -Fq '.config/psmux/**' "$repo_root/.chezmoiignore" ||
    fail ".chezmoiignore: .config/psmux/** must be excluded on non-Windows (no psmux outside Windows)"

# The operator guide (issue #188): must exist, teach the canonical prefix (not
# stock Ctrl+b), and be linked from every surface an operator starts from.
guide="$repo_root/docs/remote-agent-sessions.md"
[ -f "$guide" ] || fail "docs/remote-agent-sessions.md missing (issue #188 operator guide)"
for want in 'Ctrl+a' 'not stock tmux' '`Ctrl+a`, `d`' '`Ctrl+a`, `\|`' '`Ctrl+a`, `-`' 'h`/`j`/`k`/`l' '`Ctrl+a`, `[' '`Ctrl+a`, `r`' 'escape-time 0'; do
    grep -Fq -- "$want" "$guide" || fail "remote-agent-sessions.md: missing canonical content: $want"
done
for linker in "$repo_root/README.md" "$repo_root/docs/terminal.md" "$repo_root/docs/tmux.md" "$repo_root/docs/remote-access.md"; do
    grep -Fq 'remote-agent-sessions' "$linker" || fail "$(basename "$linker"): must link the remote-agent-sessions guide"
done

finish
