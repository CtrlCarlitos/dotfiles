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
# Short docker/compose aliases (dc, dcup, dcdn, dcl, dce, ...) come from Oh My
# Zsh's `docker` and `docker-compose` plugins now (see ~/.zshrc) - not
# redefined here. Only the cleanup helpers the plugins don't provide are kept.
#-------------------------------------------------------------------------------
alias d='docker'
alias docker-clean='docker system prune -af --volumes'
alias docker-stop-all='docker stop $(docker ps -aq) 2>/dev/null || true'

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
# Management - the dot command family (`dot init` / `dot up` / `dot upgrade`;
# wiring lives in dot_zshrc and scripts/dotupgrade.*)
#-------------------------------------------------------------------------------
# `dot up` NEVER upgrades: chezmoi update owns the pull; init re-runs the
# config template AFTER the pull (init does not fetch); a final apply
# fires only when init actually rewrote the config. `dot upgrade` is the
# single upgrade owner (apt/brew sweep + AI tools, live-session gated,
# no-op inside devcontainers - image rebuilds own those).
dot() {
    local sub="${1:-}" cfg before after
    # scripts/ lives in the SOURCE repo (never deployed to $HOME); DOTFILES_DIR
    # (exported by ~/.zshrc) is the source path and the layout's single source.
    local repo_scripts="${DOTFILES_DIR:-$(chezmoi source-path)}/scripts"
    case "$sub" in
        up)
            chezmoi update --apply || return
            cfg="$HOME/.config/chezmoi/chezmoi.toml"
            before=""; [ -f "$cfg" ] && before="$(md5 -q "$cfg" 2>/dev/null || md5sum "$cfg" | cut -d' ' -f1)"
            chezmoi init || return
            after=""; [ -f "$cfg" ] && after="$(md5 -q "$cfg" 2>/dev/null || md5sum "$cfg" | cut -d' ' -f1)"
            # An if, not `[ ... ] && cmd`: the config being unchanged is the
            # NORMAL path, and the failed test there made the whole function
            # return 1 - breaking every `dot up && ...` chain (#116).
            if [ "$before" != "$after" ]; then
                chezmoi apply
            fi
            ;;
        upgrade)  shift; bash "$repo_scripts/dotupgrade.sh" "$@" ;;
        backup)   shift; bash "$repo_scripts/dotbackup.sh" "$@" ;;
        restore)  shift; bash "$repo_scripts/dotrestore.sh" "$@" ;;
        doctor)   shift; bash "$repo_scripts/dotfiles-doctor.sh" "$@" ;;
        *)
            echo "dot - dotfiles command family"
            echo "  dot up        sync state (pull + apply + config re-init; never upgrades)"
            echo "  dot upgrade   upgrade ALL tooling (apt/brew + AI tools, session-gated)"
            echo "  dot backup    encrypted portable backup"
            echo "  dot restore   restore a backup"
            echo "  dot doctor    dotfiles health check"
            ;;
    esac
}
