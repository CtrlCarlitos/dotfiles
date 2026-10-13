#!/usr/bin/env bash
set -euo pipefail

# Oh-My-Zsh never asks to update itself. It is a pinned chezmoi external (.chezmoiexternal.toml: a
# commit SHA plus its sha256, moved by the weekly auto-update PR and applied by `dot up`), so its own
# updater must stay off: an accepted "[oh-my-zsh] Would you like to update?" git-pulled over the tree
# chezmoi writes and left ~/.oh-my-zsh/.git with 15 unmerged files (WSL, 2026-10-12).
#   1. dot_zshrc sets `zstyle ':omz:update' mode disabled` BEFORE sourcing oh-my-zsh.sh (the check
#      runs while oh-my-zsh.sh loads, so a later line would be too late)
#   2. the external stays a pinned archive with no refreshPeriod
#   3. docs/zsh-tips.md says so, and names the one-time .git removal for pre-dotfiles installs
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
zshrc="$repo_root/dot_zshrc"
externals="$repo_root/.chezmoiexternal.toml"
docs="$repo_root/docs/zsh-tips.md"

require "$zshrc" "zstyle ':omz:update' mode disabled"
style_line="$(grep -nF "zstyle ':omz:update' mode disabled" "$zshrc" | head -1 | cut -d: -f1)"
source_line="$(grep -nF 'source "$ZSH/oh-my-zsh.sh"' "$zshrc" | head -1 | cut -d: -f1)"
[ -n "$source_line" ] || fail "dot_zshrc: oh-my-zsh.sh is not sourced?"
[ "$style_line" -lt "$source_line" ] || fail "dot_zshrc: the update mode must be set before oh-my-zsh.sh is sourced (zstyle at $style_line, source at $source_line)"
if grep -Eq '^\s*(DISABLE_AUTO_UPDATE|DISABLE_UPDATE_PROMPT)=' "$zshrc"; then fail "dot_zshrc: use the zstyle, not the deprecated DISABLE_* variables"; else pass; fi
if command -v zsh >/dev/null 2>&1; then
    zsh -n "$zshrc" || fail "dot_zshrc does not parse"
    pass
fi

# 2. the external: a pinned archive, no refreshPeriod (the URL carries the version)
grep -Fq '[".oh-my-zsh"]' "$externals" || fail ".chezmoiexternal.toml: no .oh-my-zsh external"
omz_block="$(awk '/^\[".oh-my-zsh"\]/ {f=1; next} /^\[/ {f=0} f' "$externals")"
printf '%s\n' "$omz_block" | grep -Eq 'type\s*=\s*"archive"' || fail ".oh-my-zsh external must stay a pinned archive (got: $(printf '%s' "$omz_block" | tr '\n' ' '))"
printf '%s\n' "$omz_block" | grep -Eq 'checksum\.sha256' || fail ".oh-my-zsh external must carry its sha256"
if printf '%s\n' "$omz_block" | grep -q refreshPeriod; then fail ".oh-my-zsh external must not refresh on a period (the pin moves it)"; else pass; fi

# 3. docs
require "$docs" '## Updating Oh-My-Zsh'
require "$docs" "zstyle ':omz:update' mode disabled"
require "$docs" 'rm -rf ~/.oh-my-zsh/.git'
require "$docs" 'Do not run `omz update`'

finish
