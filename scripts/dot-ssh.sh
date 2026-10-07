#!/usr/bin/env bash
# dot ssh - pick one of your SSH hosts and connect (`dot ssh`, zsh twin of dot-ssh.ps1).
#
# The hosts are chezmoi.toml's [[data.ssh_hosts]] - the same entries that become
# ~/.ssh/config Host blocks and, on Windows, the "SSH: <name>" Windows Terminal profiles.
# Ghostty and other terminals have no profiles, so this is the cross-terminal picker:
#
#   dot ssh            pick with fzf (a numbered menu without fzf), then connect
#   dot ssh <name>     connect to that host directly
#   dot ssh --list     print the hosts
#
# DOT_SSH_PICKER=menu uses the numbered menu even where fzf is installed.
#
# A host with tmux set joins its remote session, as its Windows Terminal profile does:
# `ssh -t <name> "tmux new-session -A -s <session>"` (tmux = true -> "main").
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
dot ssh - connect to one of your [[data.ssh_hosts]]
  dot ssh            pick a host (fzf, or a numbered menu), then connect
  dot ssh <name>     connect to that host
  dot ssh --list     list the hosts
EOF
}

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
esac

hosts="$(chezmoi execute-template --file "$here/lib/ssh-hosts.tsv.tmpl" 2>/dev/null || true)"
hosts="$(printf '%s\n' "$hosts" | sed '/^[[:space:]]*$/d')"
if [ -z "$hosts" ]; then
    echo "dot ssh: no SSH hosts yet - add a [[data.ssh_hosts]] block to ~/.config/chezmoi/chezmoi.toml (docs/secrets.md), then dot up" >&2
    exit 1
fi

# One aligned display line per host (columns as wide as their longest value); the first word
# is always the host name.
display() {
    awk -F'\t' '
        { n[NR] = $1; t[NR] = $2; o[NR] = $3; s[NR] = $4; c[NR] = $5
          if (length($1) > wn) wn = length($1); if (length($2) > wt) wt = length($2); if (length($3) > wo) wo = length($3) }
        END {
            fmt = "%-" wn "s  %-" wt "s  %-" wo "s  %s"
            for (i = 1; i <= NR; i++) {
                x = c[i]
                if (s[i] != "") x = "tmux:" s[i] (c[i] != "" ? "  " c[i] : "")
                line = sprintf(fmt, n[i], t[i], o[i], x)
                sub(/ +$/, "", line)
                print line
            }
        }' <<<"$hosts"
}

name=""
case "${1:-}" in
    -l | --list) display; exit 0 ;;
    "")
        if [ "${DOT_SSH_PICKER:-}" != menu ] && command -v fzf >/dev/null 2>&1; then
            choice="$(display | fzf --prompt='ssh> ' --height=40% --reverse --no-multi \
                --header='enter: connect  esc: cancel')" || exit 130
        else
            display | nl -w2 -s') '
            printf 'Host number (empty to cancel): '
            read -r pick || exit 130
            [ -n "$pick" ] || exit 130
            choice="$(display | sed -n "${pick}p")"
            [ -n "$choice" ] || { echo "dot ssh: no host number $pick" >&2; exit 2; }
        fi
        name="${choice%% *}"
        ;;
    *) name="$1" ;;
esac

line="$(awk -F'\t' -v n="$name" '$1 == n' <<<"$hosts" | head -n 1)"
if [ -z "$line" ]; then
    echo "dot ssh: no host named '$name' (dot ssh --list shows them)" >&2
    exit 2
fi
# awk, not `IFS=$'\t' read`: read treats a run of TABs as ONE separator (tab is IFS
# whitespace), so a host without an os shifted its tmux session out of place.
session="$(awk -F'\t' '{print $4}' <<<"$line")"

if [ -n "$session" ]; then
    exec ssh -t "$name" "tmux new-session -A -s $session"
fi
exec ssh "$name"
