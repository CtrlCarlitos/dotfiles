#!/bin/sh
set -e

#===============================================================================
# DEVCONTAINER ENTRY POINT
# This script is called by VS Code's "Dotfiles" features.
# It ensures Chezmoi is installed and applied.
#===============================================================================

# Get script directory (POSIX-compatible, works with /bin/sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🐳 Devcontainer Dotfiles Setup..."

# 1. Delegate to the Universal Installer for core tools & chezmoi apply
if [ -f "$DOTFILES_DIR/install.sh" ]; then
    (cd "$DOTFILES_DIR" && sh install.sh)
else
    echo "Error: Universal install.sh not found!"
    exit 1
fi

# 2. Setup Complete
# The universal installer (step 1) runs 'chezmoi apply' which handles:
# - .chezmoiexternal.toml (installs Oh-My-Zsh, plugins, themes)
# - dot_zshrc (links config)

echo "✅ Devcontainer specific setup complete."
