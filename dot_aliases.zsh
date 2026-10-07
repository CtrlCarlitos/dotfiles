#===============================================================================
# SHELL ALIASES
# Sourced by dot_zshrc as ~/.aliases.zsh
#===============================================================================

#-------------------------------------------------------------------------------
# Navigation
#-------------------------------------------------------------------------------
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias -- -='cd -'

#-------------------------------------------------------------------------------
# Directory Listing
#-------------------------------------------------------------------------------
# Use eza if available (modern ls replacement)
if command -v eza &> /dev/null; then
  alias ls='eza --icons'
  alias ll='eza -la --icons --git'
  alias la='eza -a --icons'
  alias lt='eza --tree --icons --level=2'
  alias lta='eza --tree --icons --level=2 -a'
else
  alias ll='ls -alF'
  alias la='ls -A'
  alias l='ls -CF'
fi

# bat (better cat). Ubuntu/Debian ship the binary as `batcat`; the installer
# symlinks it to `bat` in ~/.local/bin, but check both. Plain cat stays
# reachable as `\cat` or `command cat`.
if command -v bat &> /dev/null; then
  alias cat='bat --paging=never'
elif command -v batcat &> /dev/null; then
  alias cat='batcat --paging=never'
fi

#-------------------------------------------------------------------------------
# Safety
#-------------------------------------------------------------------------------
alias rm='rm -i'
alias mv='mv -i'
alias cp='cp -i'
alias mkdir='mkdir -p'

# Git aliases are now managed in ~/.gitconfig
# Run 'git config --list --show-origin | grep alias' to see them

#-------------------------------------------------------------------------------
# Docker
#-------------------------------------------------------------------------------
# Short docker/compose aliases (dco, dcupd, dcdn, dclf, dce, ...) come from Oh My
# Zsh's `docker` and `docker-compose` plugins now (see ~/.zshrc) - not
# redefined here. Only the cleanup helpers the plugins don't provide are kept.
#-------------------------------------------------------------------------------
alias d='docker'
alias docker-clean='docker system prune -af --volumes'
alias docker-stop-all='docker stop $(docker ps -aq) 2>/dev/null || true'
# serena-clean (oraios/serena#2122): agy leaves serena shim+python trees
# running after exit; the next session's /mcp reload fails until they are
# gone. Close the agent CLIs first, then run it.
alias serena-clean='pkill -f serena 2>/dev/null; true'
# clip-to-file (psmux#719): pastes into agent TUIs through psmux arrive as a
# raw blob, so substantial content goes via a file instead - write the
# clipboard (Windows clipboard, read through interop) to a timestamped file,
# print the path and put it back on the clipboard; in the agent reference it
# as @<path> (or just paste the path) and the agent reads the content.
clip-to-file() {
    local f
    f="/tmp/clip-$(date +%Y%m%d-%H%M%S).txt"
    powershell.exe -NoProfile -Command 'Get-Clipboard -Raw' | tr -d '\r' > "$f"
    print -r -- "$f" | clip.exe 2>/dev/null
    print -r -- "$f"
}

#-------------------------------------------------------------------------------
# Development
#-------------------------------------------------------------------------------
alias py='python3'
alias pip='pip3'
alias serve='python3 -m http.server 8000'

# Node
alias ni='npm install'
alias nr='npm run'
alias nrd='npm run dev'
alias nrb='npm run build'

# lazygit
if command -v lazygit &> /dev/null; then
  alias lg='lazygit'
fi

#-------------------------------------------------------------------------------
# Editing
#-------------------------------------------------------------------------------
if command -v nvim &> /dev/null; then
  alias vim='nvim'
  alias vi='nvim'
  alias v='nvim'
fi

alias zshrc='${EDITOR:-vim} ~/.zshrc'
alias aliases='${EDITOR:-vim} ~/.aliases.zsh'
alias reload='source ~/.zshrc'

#-------------------------------------------------------------------------------
# System
#-------------------------------------------------------------------------------
alias df='df -h'
alias du='du -h'
alias free='free -h'
command -v htop &> /dev/null && alias top='htop'

# Rust-based replacements, only aliased if actually installed
if command -v dust &> /dev/null; then
  alias du='dust'
fi
if command -v duf &> /dev/null; then
  alias df='duf'
fi
if command -v procs &> /dev/null; then
  alias ps='procs'
fi

# Find
if command -v fdfind &> /dev/null; then
  alias fd='fdfind'
elif command -v fd &> /dev/null; then
  : # fd binary exists, no alias needed
else
  alias fd='find . -type d -name'
fi
alias ff='find . -type f -name'

# Grep with color
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

#-------------------------------------------------------------------------------
# Misc
#-------------------------------------------------------------------------------
alias c='clear'
alias h='history'
alias path='echo -e ${PATH//:/\\n}'

# Quick HTTP requests with curl
alias get='curl -sS'
alias post='curl -sS -X POST'

# Copy/Paste (Linux/WSL) - macOS has real pbcopy/pbpaste; never shadow them.
if [[ "$OSTYPE" == darwin* ]]; then
  :
elif command -v xclip &> /dev/null; then
  alias pbcopy='xclip -selection clipboard'
  alias pbpaste='xclip -selection clipboard -o'
elif [[ -n "$WAYLAND_DISPLAY" ]] && command -v wl-copy &> /dev/null; then
  alias pbcopy='wl-copy'
  alias pbpaste='wl-paste --no-newline'
elif command -v clip.exe &> /dev/null; then
  # WSL
  alias pbcopy='clip.exe'
  alias pbpaste='powershell.exe -command "Get-Clipboard"'
fi

#-------------------------------------------------------------------------------
# SSH Identity Helpers
#-------------------------------------------------------------------------------
alias devprofiles='devprofile list'
alias dp='devprofile'

#-------------------------------------------------------------------------------
# Agent CLIs
#-------------------------------------------------------------------------------
# Guardrail hooks.json remains the enforced boundary; see agent-guardrails
# ADR-0008 — prompts off, guard on.
alias agy='agy --dangerously-skip-permissions'

#-------------------------------------------------------------------------------
# Management - the dot command family (`dot up` / `dot upgrade` / `dot doctor` /
# `dot backup` / `dot restore` / `dot remote` / `dot version`;
# wiring lives in dot_zshrc and scripts/dotupgrade.*)
#-------------------------------------------------------------------------------
# `dot up` NEVER upgrades: chezmoi update pulls WITHOUT applying, init re-runs
# the config template on the pulled source (init does not fetch), then ONE
# apply runs with the fresh config. Applying before init ran the installers
# twice whenever the config template changed (once with the old config, once
# after init) and printed chezmoi's "config file template has changed" warning. `dot upgrade` is the
# single upgrade owner (apt/brew sweep + AI tools, live-session gated,
# no-op inside devcontainers - image rebuilds own those).
dot() {
    local sub="${1:-}"
    # scripts/ lives in the SOURCE repo (never deployed to $HOME); DOTFILES_DIR
    # (exported by ~/.zshrc) is the source path and the layout's single source.
    local repo_scripts="${DOTFILES_DIR:-$(chezmoi source-path)}/scripts"
    case "$sub" in
        up)
            chezmoi update --apply=false || return
            chezmoi init || return
            chezmoi apply || return
            # zsh caches every PATH dir's listing on first command lookup
            # (HASH_LIST_ALL): installs from this run stay invisible to THIS
            # shell until the cache is dropped - `codex` was "not found" in a
            # session that predated its install (2026-09-29). A full profile
            # reload is deliberately not attempted (double-loaded hooks);
            # rehash only drops the cache. Guarded: the contract executes this
            # function under bash too, where rehash does not exist, and an
            # unguarded tail would return non-zero (#116 class).
            if command -v rehash >/dev/null 2>&1; then rehash; fi
            ;;
        upgrade)  shift; bash "$repo_scripts/dotupgrade.sh" "$@" ;;
        backup)   shift; bash "$repo_scripts/dotbackup.sh" "$@" ;;
        restore)  shift; bash "$repo_scripts/dotrestore.sh" "$@" ;;
        doctor)   shift; bash "$repo_scripts/dotfiles-doctor.sh" "$@" ;;
        remote)  shift; bash "$repo_scripts/remote-access.sh" "$@" ;;
        ssh)     shift; bash "$repo_scripts/dot-ssh.sh" "$@" ;;
        version)  shift; bash "$repo_scripts/dotversion.sh" "$@" ;;
        *)
            local unknown=0
            case "$sub" in ''|help|-h|--help) ;; *)
                unknown=1
                echo "dot: unknown command '$sub'" >&2
                echo "  (a command added by a recent 'dot up' needs a new shell: this one loaded an older dot)" >&2
                ;;
            esac
            echo "dot - dotfiles command family"
            printf '  %-20s  %s\n' 'dot up' 'sync state (pull + apply + config re-init; never upgrades)'
            printf '  %-20s  %s\n' 'dot upgrade' 'upgrade ALL tooling (apt/brew + AI tools, session-gated)'
            printf '  %-20s  %s\n' 'dot backup' 'encrypted portable backup'
            printf '  %-20s  %s\n' 'dot restore' 'restore a backup'
            printf '  %-20s  %s\n' 'dot doctor' 'dotfiles health check'
            printf '  %-20s  %s\n' 'dot remote' 'remote-access setup/status/fix/keys'
            printf '  %-20s  %s\n' 'dot ssh' 'pick an SSH host and connect (--list, or a name)'
            printf '  %-20s  %s\n' 'dot version' 'which version of the dotfiles repo this is'
            return $((unknown * 2))
            ;;
    esac
}
