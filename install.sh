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
# Every temp file this script creates (the gum bootstrap downloads) lives in
# GUM_TMP and is removed by this single EXIT trap - a mid-download failure
# under `set -e` used to leak the mktemp dir (and a fixed-name gum deb
# dropped straight into the shared temp dir) (#108, #126).
GUM_TMP=""
cleanup_tmp() {
    if [ -n "$GUM_TMP" ] && [ -d "$GUM_TMP" ]; then
        rm -rf "$GUM_TMP"
    fi
}
# shellcheck disable=SC2154  # rc is assigned inside the trap body itself
trap 'rc=$?; cleanup_tmp; if [ "$rc" -ne 0 ]; then error_handler; fi' EXIT

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
        # noninteractive: a debconf question would otherwise stop the bootstrap (see
        # quiet_apt_enable in scripts/lib/agent-skills.sh - the iperf3 hang of 2026-10-23)
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$PACKAGE"
    else
        echo "Warning: Automatic installation not supported for OS: ${ID:-unknown}"
        echo "Please install '$PACKAGE' manually and rerun the script."
        exit 1
    fi
}

# Bootstrap gum (pinned) for the interactive package menu. Best-effort only:
# every failure warns and continues - without gum the menu self-skips and
# chezmoi's native config prompts take over. Each asset is verified against
# the release's published checksums.txt before it is installed.
#
# The pin's single source is .chezmoidata.yaml versions.gum (#125), read from
# the checkout - which step 1.3 below now clones BEFORE gum is bootstrapped,
# so the one-liner gets the pin too. The inline fallback only covers a failed
# read; scripts/update-versions.sh syncs it to the yaml pin, so the two cannot
# drift silently.
GUM_VERSION="${GUM_VERSION:-2.0.1}"
read_gum_pin() {
    for _gum_yaml in "$(dirname "$0")/.chezmoidata.yaml" \
                      "$HOME/.local/share/chezmoi/.chezmoidata.yaml"; do
        if [ -f "$_gum_yaml" ]; then
            _yaml_gum="$(sed -n 's/^  gum: .\{0,1\}\([^"]*\).\{0,1\}$/\1/p' "$_gum_yaml" | head -n 1)"
            if [ -n "$_yaml_gum" ]; then
                GUM_VERSION="$_yaml_gum"
                return 0
            fi
        fi
    done
}

# Print the sha256 of a file; empty output when no SHA-256 tool exists.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

gum_checksum_ok() { # $1 = downloaded file, $2 = asset base name
    _gum_want="$(grep -F "  $2" "$GUM_TMP/checksums.txt" | head -n 1 | cut -d' ' -f1)"
    if [ -z "$_gum_want" ]; then
        return 1
    fi
    _gum_got="$(sha256_of "$1")"
    if [ -z "$_gum_got" ]; then
        echo "Warning: no SHA-256 tool to verify gum - not installing it." >&2
        return 1
    fi
    [ "$_gum_got" = "$_gum_want" ]
}

bootstrap_gum() {
    if command -v gum >/dev/null 2>&1; then
        return 0
    fi
    read_gum_pin

    GUM_OS="$(uname -s)"
    GUM_ARCH="$(uname -m)"
    case "$GUM_OS/$GUM_ARCH" in
        Darwin/arm64)  GUM_ASSET="gum_${GUM_VERSION}_Darwin_arm64.tar.gz" ;;
        Darwin/x86_64) GUM_ASSET="gum_${GUM_VERSION}_Darwin_x86_64.tar.gz" ;;
        Linux/x86_64)  GUM_ASSET="gum_${GUM_VERSION}_amd64.deb" ;;
        *)
            echo "Warning: no gum bootstrap for $GUM_OS/$GUM_ARCH - menu will self-skip."
            return 0
            ;;
    esac

    GUM_BASE="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}"
    GUM_TMP="$(mktemp -d)" # removed by the EXIT trap, on failure paths too

    if ! _net 120 curl -fsSL -o "$GUM_TMP/$GUM_ASSET" "$GUM_BASE/$GUM_ASSET" \
        || ! _net 60 curl -fsSL -o "$GUM_TMP/checksums.txt" "$GUM_BASE/checksums.txt"; then
        echo "Warning: gum download failed - menu will self-skip."
        return 0
    fi
    if ! gum_checksum_ok "$GUM_TMP/$GUM_ASSET" "$GUM_ASSET"; then
        echo "Warning: gum checksum verification failed - not installing it - menu will self-skip."
        return 0
    fi

    if [ "${GUM_ASSET##*.}" = "deb" ]; then
        if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            SUDO=""
        fi
        if ! $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$GUM_TMP/$GUM_ASSET"; then
            echo "Warning: gum install failed - menu will self-skip."
        fi
    else
        mkdir -p "$HOME/.local/bin"
        if tar -xzf "$GUM_TMP/$GUM_ASSET" -C "$GUM_TMP"; then
            # tarball layout varies (flat vs nested dir) - locate the binary
            GUM_BIN="$(find "$GUM_TMP" -type f -name gum 2>/dev/null | head -n 1)"
            if [ -n "$GUM_BIN" ]; then
                mv -f "$GUM_BIN" "$HOME/.local/bin/gum"
                echo "Bootstrapped gum to ~/.local/bin (package menu enabled)."
            else
                echo "Warning: gum binary not found in tarball - menu will self-skip."
            fi
        else
            echo "Warning: gum tarball extraction failed - menu will self-skip."
        fi
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

# 1.3 The source checkout, BEFORE gum, the menu and the apply - install.ps1's
# step 2, ported (2026-10-23 fresh Ubuntu 26.04 VM). The one-liner downloads
# this script alone, so scripts/select-packages.sh and the gum/chezmoi pins
# were not on disk yet: the menu printed "package menu not found" and never
# showed on a fresh Linux machine. Only this network step is retried.
#
# DOTFILES_BRANCH (default main) installs another branch - how a fix is tried
# on a fresh machine before it is merged. An existing clone is switched to it
# when asked for explicitly, then fast-forwarded: a rerun used to reuse the
# old clone as-is, so merged fixes never reached the machine. Unauthenticated
# https on purpose: the repo is public (tests/installer_url_credentials_contract.sh).
SOURCE_DIR="$HOME/.local/share/chezmoi"
SOURCE_URL="https://github.com/CtrlCarlitos/dotfiles.git"
SOURCE_BRANCH="${DOTFILES_BRANCH:-main}"
LOCAL_SOURCE=""
if [ -f "chezmoi.toml" ] || [ -f ".chezmoi.toml.tmpl" ]; then
    LOCAL_SOURCE=1 # running from within a checkout (e.g. devcontainer feature)
    echo "Using the local checkout at $(pwd)"
elif [ -d "$SOURCE_DIR/.git" ]; then
    echo "Updating existing dotfiles clone..."
    if [ -n "${DOTFILES_BRANCH:-}" ] &&
        [ "$(git -C "$SOURCE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$SOURCE_BRANCH" ]; then
        # `git switch <b>` creates the local branch from origin/<b> on its own once fetched
        if ! _net 120 git -C "$SOURCE_DIR" fetch origin "$SOURCE_BRANCH" ||
            ! git -C "$SOURCE_DIR" switch "$SOURCE_BRANCH"; then
            echo "  could not switch the clone to $SOURCE_BRANCH (local changes?) - continuing on $(git -C "$SOURCE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        fi
    fi
    if ! _net 120 git -C "$SOURCE_DIR" pull --ff-only; then
        echo "  clone update failed (offline? local changes?) - continuing with existing source"
    fi
else
    echo "Cloning the dotfiles ($SOURCE_BRANCH) into $SOURCE_DIR..."
    _clone_attempt=1
    while :; do
        rm -rf "$SOURCE_DIR"
        if _net 300 git clone --branch "$SOURCE_BRANCH" "$SOURCE_URL" "$SOURCE_DIR" && [ -d "$SOURCE_DIR/.git" ]; then
            break
        fi
        if [ "$_clone_attempt" -ge 3 ]; then
            echo "Could not clone $SOURCE_URL ($SOURCE_BRANCH) after 3 attempts. Check the network and re-run the installer." >&2
            exit 1
        fi
        echo "clone failed (attempt $_clone_attempt of 3) - retrying in ${CHEZMOI_RETRY_DELAY:-5} seconds..."
        sleep "${CHEZMOI_RETRY_DELAY:-5}"
        _clone_attempt=$((_clone_attempt + 1))
    done
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
        echo "Note: package menu not found in the checkout - chezmoi config prompts will collect preferences."
    fi
else
    echo "Devcontainer detected - skipping package menu (tools come from devcontainer-features)."
fi

# 1.7 [data.logging] (docs/logging.md): from here on - the chezmoi install and the whole apply -
# output is tee'd to ~/.local/state/dotfiles/logs/install-<time>.log as it happens, so the install
# can be followed from another terminal (tail -f) or read afterwards. Started AFTER the menu: gum's
# screen needs the terminal itself. The environment (DOT_LOG=0|1) wins, then [data.logging] log in
# chezmoi.toml, then on. POSIX twin of scripts/lib/logging.sh (this script is sh: a FIFO stands in
# for bash's >(...)). Never fatal: any problem leaves the output as it was.
install_log_flag() { # $1 = config key, $2 = default -> true|false
    _ilf_cfg="$HOME/.config/chezmoi/chezmoi.toml"
    _ilf_val=""
    if [ -f "$_ilf_cfg" ]; then
        _ilf_val="$(awk -v key="$1" '
            /^[[:space:]]*\[data\.logging\][[:space:]]*$/ { on = 1; next }
            on && /^[[:space:]]*\[/ { exit }
            on {
                line = $0
                sub(/[[:space:]]*#.*$/, "", line)
                if (line ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*$") {
                    sub(/^[^=]*=[[:space:]]*/, "", line); sub(/[[:space:]]*$/, "", line)
                    print line; exit
                }
            }' "$_ilf_cfg" 2>/dev/null || true)"
    fi
    if [ -n "$_ilf_val" ]; then echo "$_ilf_val"; else echo "$2"; fi
}
start_install_log() {
    case "$(printf '%s' "${DOT_LOG:-}" | tr '[:upper:]' '[:lower:]')" in
        0 | false | no | off) return 0 ;;
        1 | true | yes | on) ;;
        *) [ "$(install_log_flag log true)" = true ] || return 0 ;;
    esac
    _il_dir="$HOME/.local/state/dotfiles/logs"
    mkdir -p "$_il_dir" 2>/dev/null || return 0
    INSTALL_LOG="$_il_dir/install-$(date +%Y%m%d-%H%M%S).log"
    _il_tmp="$(mktemp -d 2>/dev/null)" || return 0
    if ! mkfifo "$_il_tmp/log.fifo" 2>/dev/null; then rm -rf "$_il_tmp"; return 0; fi
    tee -a "$INSTALL_LOG" <"$_il_tmp/log.fifo" &
    # Opening the write end blocks until tee has the read end, so the FIFO can go right after.
    exec >"$_il_tmp/log.fifo" 2>&1
    rm -rf "$_il_tmp"
    echo "Live log: $INSTALL_LOG (the apply's dot-up-*.log lands beside it)"
}
start_install_log

# 2. Install Chezmoi if missing
if ! command -v chezmoi >/dev/null 2>&1; then
  echo "Installing chezmoi..."
  # Pin coherence (#133): deliberately install the SAME chezmoi CI tests -
  # the repo's .chezmoi-version pin, read when a checkout is on disk (same
  # lookup rule as the gum pin above). On the bare one-liner run the script
  # was downloaded alone and no pin file exists yet, so this falls back to
  # latest - `doctor` flags the drift after the checkout lands.
  _pin=""
  for _pin_loc in "$(dirname "$0")/.chezmoi-version" \
                   "$HOME/.local/share/chezmoi/.chezmoi-version"; do
      if [ -f "$_pin_loc" ]; then
          _pin="$(cat "$_pin_loc")"
          break
      fi
  done
  # shellcheck disable=SC2016  # $HOME and the pin must expand inside the child sh
  if [ -n "$_pin" ]; then
      CHEZMOI_PIN="$_pin"
      export CHEZMOI_PIN
      _net 180 sh -c 'curl -fsLS get.chezmoi.io | sh -s -- -b "$HOME/.local/bin" -t "$CHEZMOI_PIN"'
  else
      _net 180 sh -c 'curl -fsLS get.chezmoi.io | sh -s -- -b "$HOME/.local/bin"'
  fi
fi

# 2. Initialize & Apply
echo "Applying dotfiles..."

# Retry chezmoi across flaky-network first installs. `if "$@"` is the whole
# point: under `set -e` the original `"$@"; exitCode=$?` let the first failing
# `chezmoi init --apply` kill the script before the exit code was ever read,
# so the retry was dead code and "Attempt N of 3" never printed (#108).
# Plain (prefixed) globals instead of `local`: this file is #!/bin/sh (dash)
# and `local` is not POSIX (SC3043).
run_chezmoi_with_retry() {
    _rc_max_attempts=3
    _rc_delay="${CHEZMOI_RETRY_DELAY:-5}"
    _rc_attempt=1
    _rc_code=0

    while [ "$_rc_attempt" -le "$_rc_max_attempts" ]; do
        # `|| _code=$?` both shields the command from `set -e` and captures
        # its real exit status (an `if "$@"; then return 0; fi` shape would
        # report the *if statement's* status - 0 - not the command's).
        _rc_code=0
        "$@" || _rc_code=$?
        if [ "$_rc_code" -eq 0 ]; then
            return 0
        fi

        echo "chezmoi operation failed (exit code $_rc_code). Attempt $_rc_attempt of $_rc_max_attempts."
        if [ "$_rc_attempt" -lt "$_rc_max_attempts" ]; then
            echo "Waiting $_rc_delay seconds before retrying..."
            sleep "$_rc_delay"
        fi
        _rc_attempt=$((_rc_attempt + 1))
    done
    return "$_rc_code"
}

if [ -n "$LOCAL_SOURCE" ]; then
  run_chezmoi_with_retry chezmoi init --apply --source .
else
  # The checkout is on disk (step 1.3): init (re)generates the config from it
  # and applies. The repo is public: step 1.3 clones it unauthenticated.
  #
  # There is deliberately NO token-authenticated branch here. This used to
  # clone an https URL with a bootstrap token interpolated into the
  # userinfo position (before the host), and git persists a clone URL
  # verbatim as remote.origin.url - so that token stayed in .git/config
  # (mode 644, world-readable) for as long as the checkout lived, which is
  # exactly what docs/backup-restore.md's "do not embed a PAT in a clone
  # URL" rule forbids. One real machine carried a classic token there for
  # weeks; `git remote -v` printed it on demand, and a token in the
  # username position is not even a working push credential.
  #
  # If this repo is ever private again, authenticate by identity, not by
  # URL: SSH (dot_gitconfig's url.*.insteadOf rewrites already carry a
  # per-account identity) or a credential helper. If a token is truly
  # unavoidable, pass it as a ONE-SHOT helper BEFORE the subcommand -
  # `git -c credential.helper=... clone <tokenless-url>` - and never as
  # `git clone -c ...`, which writes the value into the new repo's config
  # and recreates this bug. tests/installer_url_credentials_contract.sh
  # pins all of that.
  run_chezmoi_with_retry chezmoi init --apply
fi
# The exact revision this run applied, for the log (twin of install.ps1's "Dotfiles source:").
if src_rev="$(git -C "$HOME/.local/share/chezmoi" rev-parse --short HEAD 2>/dev/null)"; then
  echo "Dotfiles source: $(git -C "$HOME/.local/share/chezmoi" rev-parse --abbrev-ref HEAD 2>/dev/null) @ $src_rev"
fi

# 3. Post-Install Checks (Devcontainer specific)
if [ -n "$IS_DEVCONTAINER" ] || [ -f "/.dockerenv" ]; then
    echo "Running in Devcontainer/Docker..."
    # Ensure zsh is default if not set
    if [ "$SHELL" != "$(which zsh)" ] && command -v zsh >/dev/null; then
        echo "Note: Switch to zsh by running 'exec zsh'"
    fi
fi

echo "Done!"

echo "----------------------------------------------------------------"
echo "To customize your setup (add accounts, toggle features):"
echo "1. Edit ~/.config/chezmoi/chezmoi.toml"
echo "2. Reference examples in ~/.local/share/chezmoi/docs/"
echo "3. Run 'chezmoi apply'"
echo "----------------------------------------------------------------"

# Try to switch to zsh immediately if it's the new default. Deliberately
# AFTER the tips above: `exec` replaces this shell, so anything printed after
# it never happens - the tips used to sit behind it and were unreachable in
# the interactive non-zsh case (#108). Reuses IS_DEVCONTAINER (which already
# folds in REMOTE_CONTAINERS) instead of checking $DEVCONTAINER alone.
if [ -z "$IS_DEVCONTAINER" ] && [ -x "$(command -v zsh)" ]; then
    # Only if we are interactive and NOT currently in zsh
    if [ -z "$ZSH_VERSION" ] && [ -t 1 ]; then
        echo "ℹ️  Switching to Zsh..."
        exec zsh -l
    fi
fi
