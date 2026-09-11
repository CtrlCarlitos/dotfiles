#!/bin/sh

# Universal Install Script for Chezmoi Dotfiles
# Usage: ./install.sh
# Supported: Linux, macOS, Devcontainers, WSL

set -e

error_handler() {
    echo "----------------------------------------------------------------"
    echo "❌ Installation Failed"
    echo "Please check the error message above."
    echo "You can retry by running: chezmoi apply"
    echo "----------------------------------------------------------------"
}
trap 'if [ $? -ne 0 ]; then error_handler; fi' EXIT

# Wall-clock guard for the unbounded network fetches below - a stalled
# download otherwise freezes this `set -e` bootstrap indefinitely. Uses
# coreutils `timeout` (Linux always) / `gtimeout` (macOS with coreutils);
# runs unguarded if neither exists.
_net() {
    _s=$1; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$_s" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$_s" "$@"
    else "$@"
    fi
}

# 0. Helper Functions

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

install_package() {
    PACKAGE=$1
    
    # Reload OS info to check ID and ID_LIKE
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    fi

    # Check if ID or ID_LIKE contains debian or ubuntu
    # "linuxmint" usually has ID=linuxmint and ID_LIKE=ubuntu (or debian)
    if echo "$ID $ID_LIKE" | grep -qE "ubuntu|debian|linuxmint"; then
        SUPPORTED=true
    else
        SUPPORTED=false
    fi

    echo "Attempting to install $PACKAGE..."

    if [ "$SUPPORTED" = "true" ]; then
        if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null; then
            SUDO="sudo"
        else
            SUDO=""
        fi
        $SUDO apt-get update
        $SUDO apt-get install -y "$PACKAGE"
    else
        echo "Warning: Automatic installation not supported for OS: ${ID:-unknown}"
        echo "Please install '$PACKAGE' manually and rerun the script."
        exit 1
    fi
}

# 1. Prerequisites Check (Git, Curl, GPG, Wget, 7zip)
if ! command -v git >/dev/null 2>&1; then
    install_package git
fi

if ! command -v curl >/dev/null 2>&1; then
    install_package curl
fi

if ! command -v gpg >/dev/null 2>&1; then
    install_package gpg
fi

if ! command -v wget >/dev/null 2>&1; then
    install_package wget
fi

if ! command -v 7z >/dev/null 2>&1 && ! command -v 7zz >/dev/null 2>&1; then
    install_package p7zip-full
fi

# 2. Install Chezmoi if missing
if ! command -v chezmoi >/dev/null 2>&1; then
  echo "Installing chezmoi..."
  # shellcheck disable=SC2016  # $HOME must expand inside the child sh, not here
  _net 180 sh -c 'curl -fsLS get.chezmoi.io | sh -s -- -b "$HOME/.local/bin"'
  export PATH="$HOME/.local/bin:$PATH"
fi

# 2. Initialize & Apply
echo "Applying dotfiles..."

run_chezmoi_with_retry() {
    local max_attempts=3
    local delay=5
    local attempt=1
    local exitCode=0

    while [ $attempt -le $max_attempts ]; do
        "$@"
        exitCode=$?
        
        if [ $exitCode -eq 0 ]; then
            return 0
        fi
        
        echo "chezmoi operation failed (exit code $exitCode). Attempt $attempt of $max_attempts."
        if [ $attempt -lt $max_attempts ]; then
            echo "Waiting $delay seconds before retrying..."
            sleep $delay
        fi
        attempt=$((attempt + 1))
    done
    return $exitCode
}

if [ -d "$HOME/.local/share/chezmoi/.git" ]; then
  # Repo exists: Run init (to ensure config exists/generates) and then apply
  # This respects existing config but ensures setup is complete
  run_chezmoi_with_retry chezmoi init --apply
else
  # If we are running from within the repo checking out (e.g. devcontainer feature)
  if [ -f "chezmoi.toml" ] || [ -f ".chezmoi.toml.tmpl" ]; then
     run_chezmoi_with_retry chezmoi init --apply --source .
  else
     # If PAT is provided (private repo), clone with PAT and init from source.
     # low-speed config aborts a stalled clone (<1KB/s for 60s); _net is a
     # hard ceiling on top.
     if [ -n "${PAT:-}" ]; then
        _net 900 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
            clone "https://${PAT}@github.com/CtrlCarlitos/dotfiles.git" "$HOME/.local/share/chezmoi"
        run_chezmoi_with_retry chezmoi init --apply --source "$HOME/.local/share/chezmoi"
     else
        # Fallback: Clone from GitHub
        run_chezmoi_with_retry chezmoi init --apply --branch main CtrlCarlitos/dotfiles
     fi
  fi
fi

# 3. Post-Install Checks (Devcontainer specific)
if [ -n "$DEVCONTAINER" ] || [ -f "/.dockerenv" ]; then
    echo "Running in Devcontainer/Docker..."
    # Ensure zsh is default if not set
    if [ "$SHELL" != "$(which zsh)" ] && command -v zsh >/dev/null; then
        echo "Note: Switch to zsh by running 'exec zsh'"
    fi
fi

echo "Done!"

# Try to switch to zsh immediately if it's the new default
if [ -z "$DEVCONTAINER" ] && [ -x "$(command -v zsh)" ]; then
    # Only if we are interactive and NOT currently in zsh
    if [ -z "$ZSH_VERSION" ] && [ -t 1 ]; then
        echo "ℹ️  Switching to Zsh..."
        exec zsh -l
    fi
fi
echo "----------------------------------------------------------------"
echo "To customize your setup (add accounts, toggle features):"
echo "1. Edit ~/.config/chezmoi/chezmoi.toml"
echo "2. Reference examples in ~/.local/share/chezmoi/docs/"
echo "3. Run 'chezmoi apply'"
echo "----------------------------------------------------------------"
