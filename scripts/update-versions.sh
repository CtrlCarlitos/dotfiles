#!/usr/bin/env bash

set -e

echo "Starting Auto-Update Script..."

# 1. Update Chezmoi Version
echo "Fetching latest Chezmoi version..."
LATEST_CHEZMOI=$(curl -s "https://api.github.com/repos/twpayne/chezmoi/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
if [ -n "$LATEST_CHEZMOI" ]; then
    echo "Latest Chezmoi: $LATEST_CHEZMOI"
    # Update in .chezmoi-version
    echo "$LATEST_CHEZMOI" > .chezmoi-version
else
    echo "Warning: Could not fetch Chezmoi version."
fi

# 2. Antigravity version updates were removed (2026-09-11): the desktop
# surfaces (IDE + hub app) are gone from every platform - agy, the one
# remaining Antigravity surface, is a floating Chocolatey/Homebrew/install-
# script install with no pin to maintain. Auto-update is chezmoi-only now.

# Note: Node.js is not dynamically bumped here. It is pinned to 24.x in
# three installers by hand - run_onchange_install_packages.ps1.tmpl (choco
# nodejs --version), the NodeSource setup_24.x script (Linux), and brew
# node@24 (macOS) - bump those together when moving majors.

echo "Version updates complete."
