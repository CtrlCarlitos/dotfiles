#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
zshrc="$repo_root/dot_zshrc"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[[ -f "$zshrc" ]] || fail "missing $zshrc"
zsh -n "$zshrc" || fail "dot_zshrc has invalid zsh syntax"

require_line() {
    local pattern="$1"
    grep -Fqx "$pattern" "$zshrc" || fail "missing required zsh-native startup contract: $pattern"
}

line_number() {
    grep -nFm1 "$1" "$zshrc" | cut -d: -f1
}

require_line 'typeset -U path'
require_line 'typeset -U fpath'
require_line '[[ -d "$HOME/.local/bin" ]] && path=("$HOME/.local/bin" "${path[@]}")'
require_line '[[ -d "$HOME/bin" ]] && path=("$HOME/bin" "${path[@]}")'
require_line '[[ -d "$HOME/.npm-global/bin" ]] && path=("$HOME/.npm-global/bin" "${path[@]}")'
require_line '[[ -d "$HOME/.opencode/bin" ]] && path=("$HOME/.opencode/bin" "${path[@]}")'
require_line '[[ -d "$HOME/sdk/go/bin" ]] && path=("$HOME/sdk/go/bin" "${path[@]}")'
require_line '[[ -d "${GOPATH:-$HOME/go}/bin" ]] && path=("${GOPATH:-$HOME/go}/bin" "${path[@]}")'
require_line '[[ -d "$HOME/.dotnet" ]] && path=("$HOME/.dotnet" "${path[@]}")'
require_line '[[ -d "$HOME/.dotnet/tools" ]] && path=("$HOME/.dotnet/tools" "${path[@]}")'
require_line '[[ -d "$HOME/.mix/escripts" ]] && path=("$HOME/.mix/escripts" "${path[@]}")'
require_line '[[ -d "$HOME/.config/composer/vendor/bin" ]] && path=("$HOME/.config/composer/vendor/bin" "${path[@]}")'
require_line '[[ -d "$HOME/.composer/vendor/bin" ]] && path=("$HOME/.composer/vendor/bin" "${path[@]}")'
require_line '[[ -d "$HOME/.zfunc" ]] && fpath=("$HOME/.zfunc" "${fpath[@]}")'

brew_line="$(line_number 'if [[ -x "/opt/homebrew/bin/brew" ]]; then')"
starship_line="$(line_number '# Starship (Prompt)')"
zoxide_line="$(line_number '# Zoxide (Smart CD)')"
direnv_line="$(line_number '# Direnv (Env vars per directory)')"
[[ -n "$brew_line" && -n "$starship_line" && -n "$zoxide_line" && -n "$direnv_line" ]] ||
    fail 'missing Homebrew or modern-tool initialization marker'
[[ "$brew_line" -lt "$starship_line" ]] || fail 'Homebrew must initialize before Starship'
[[ "$brew_line" -lt "$zoxide_line" ]] || fail 'Homebrew must initialize before Zoxide'
[[ "$brew_line" -lt "$direnv_line" ]] || fail 'Homebrew must initialize before Direnv'

printf 'PASS: dot_zshrc syntax and zsh-native startup contract\n'
