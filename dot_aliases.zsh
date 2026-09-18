#===============================================================================
# SHELL ALIASES
# Shared across zsh and bash
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

# Rust-based replacements, only aliased if actually installed (install_modern)
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

# Copy/Paste (Linux/WSL)
if command -v xclip &> /dev/null; then
  alias pbcopy='xclip -selection clipboard'
  alias pbpaste='xclip -selection clipboard -o'
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
# Management
#-------------------------------------------------------------------------------
alias dotup='chezmoi update --apply'
