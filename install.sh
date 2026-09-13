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

# Bootstrap gum (pinned v2.0.1) for the interactive package menu. Best-effort
# only: every failure warns and continues - without gum the menu self-skips
# and chezmoi's native config prompts take over.
bootstrap_gum() {
    if command -v gum >/dev/null 2>&1; then
        return 0
    fi

    GUM_OS="$(uname -s)"
    GUM_ARCH="$(uname -m)"

    if [ "$GUM_OS" = "Darwin" ]; then
        case "$GUM_ARCH" in
        arm64)
            GUM_URL="https://github.com/charmbracelet/gum/releases/download/v2.0.1/gum_2.0.1_Darwin_arm64.tar.gz"
            ;;
        x86_64)
            GUM_URL="https://github.com/charmbracelet/gum/releases/download/v2.0.1/gum_2.0.1_Darwin_x86_64.tar.gz"
            ;;
        *)
            echo "Warning: no gum tarball for macOS/$GUM_ARCH - menu will self-skip."
            return 0
        esac
        mkdir -p "$HOME/.local/bin"
        GUM_TMP="$(mktemp -d)"
        if _net 120 curl -fsSL -o "$GUM_TMP/gum.tar.gz" "$GUM_URL"; then
            tar -xzf "$GUM_TMP/gum.tar.gz" -C "$GUM_TMP"
            # tarball layout varies (flat vs nested dir) - locate the binary
            GUM_BIN="$(find "$GUM_TMP" -type f -name gum 2>/dev/null | head -n 1)"
            if [ -n "$GUM_BIN" ]; then
                mv -f "$GUM_BIN" "$HOME/.local/bin/gum"
                echo "Bootstrapped gum to ~/.local/bin (package menu enabled)."
            else
                echo "Warning: gum binary not found in tarball - menu will self-skip."
            fi
        else
            echo "Warning: gum download failed - menu will self-skip."
        fi
        rm -rf "$GUM_TMP"
    elif [ "$GUM_OS" = "Linux" ] && [ "$GUM_ARCH" = "x86_64" ]; then
        if _net 180 curl -fsSL -o /tmp/gum.deb "https://github.com/charmbracelet/gum/releases/download/v2.0.1/gum_2.0.1_amd64.deb"; then
            if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
                SUDO="sudo"
            else
                SUDO=""
            fi
            if ! $SUDO apt-get install -y /tmp/gum.deb; then
                echo "Warning: gum install failed - menu will self-skip."
            fi
            rm -f /tmp/gum.deb
        else
            echo "Warning: gum download failed - menu will self-skip."
        fi
    else
        echo "Warning: no gum bootstrap for $GUM_OS/$GUM_ARCH - menu will self-skip."
    fi
}

# 0.5 Consent - ask before touching anything. Interactive only: non-TTY stdin
# (e.g. some curl|sh variants) and CI ($CHEZMOI_TEST_MINIMAL) auto-proceed.
if [ -t 0 ] && [ -z "${CHEZMOI_TEST_MINIMAL:-}" ]; then
    echo "This installer installs prerequisites (git, curl, ...), chezmoi, and"
    echo "applies the CtrlCarlitos dotfiles to this machine."
    # printf+read rather than `read -p`: dash < 0.5.11 lacks -p and dies under set -e
    printf '%s' "Proceed? [Y/n] "
    read -r reply || reply=""
    if [ "$reply" = "n" ]; then
        echo "Aborted - nothing was installed. Re-run any time."
        exit 0
    fi
fi

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

# 1.5 Interactive package menu - runs BEFORE `chezmoi init --apply` so the
# selection lands in ~/.config/chezmoi/chezmoi.toml ahead of the config
# template. The menu self-skips without a TTY or gum; chezmoi's native config
# prompts are always the fallback.
#
# In devcontainers: skip both the gum bootstrap AND the menu entirely — the
# non-interactive path renders all groups false (config-only apply), and
# downloading gum just to have the menu self-skip wastes bandwidth on every
# container start. Tools in devcontainers come from devcontainer-features
# during image build, not from here.
IS_DEVCONTAINER="${DEVCONTAINER:-}${REMOTE_CONTAINERS:-}"
if [ -z "$IS_DEVCONTAINER" ]; then
    export PATH="$HOME/.local/bin:$PATH" # moved up from the chezmoi block: a bootstrapped gum is usable immediately
    bootstrap_gum

    SELECT_PACKAGES=""
    if [ -f "scripts/select-packages.sh" ]; then
        SELECT_PACKAGES="scripts/select-packages.sh"
    elif [ -f "$HOME/.local/share/chezmoi/scripts/select-packages.sh" ]; then
        SELECT_PACKAGES="$HOME/.local/share/chezmoi/scripts/select-packages.sh"
    fi
    if [ -n "$SELECT_PACKAGES" ]; then
        # never fatal: a failed menu just falls through to chezmoi's prompts
        if ! bash "$SELECT_PACKAGES"; then
            echo "Warning: package menu failed - continuing with chezmoi config prompts."
        fi
    else
        echo "Note: package menu not found (fresh one-liner install) - chezmoi config prompts will collect preferences."
    fi
else
    echo "Devcontainer detected - skipping package menu (tools come from devcontainer-features)."
fi

# 2. Install Chezmoi if missing
if ! command -v chezmoi >/dev/null 2>&1; then
  echo "Installing chezmoi..."
  # shellcheck disable=SC2016  # $HOME must expand inside the child sh, not here
  _net 180 sh -c 'curl -fsLS get.chezmoi.io | sh -s -- -b "$HOME/.local/bin"'
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
