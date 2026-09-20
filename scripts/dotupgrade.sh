#!/bin/bash
# dot upgrade - the single owner of ALL tool upgrades.
# Spec: docs/superpowers/specs/2026-09-20-dot-cli-design.md
# `dot up` NEVER upgrades; this script does, with live-session guards.
set -u

# --- Devcontainer: upgrades ship via image rebuild, never in-place. ---
# Same detection expression as .chezmoiignore.
if [ -n "${DEVCONTAINER:-}" ] || [ -n "${REMOTE_CONTAINERS:-}" ] || [ -e /.dockerenv ]; then
    echo "devcontainer detected: upgrades ship via image rebuild - skipping."
    exit 0
fi

echo "dot upgrade - sweeping all tooling..."

# --- Live-session scan: defer dir-recreating upgrades while agent hosts run. ---
live() { for p in "$@"; do pgrep -x "$p" >/dev/null 2>&1 && return 0; done; return 1; }
DEFER=""
pgrep -x codex >/dev/null 2>&1 && DEFER="codex"
live opencode claude codex agy && DEFER="${DEFER:+$DEFER,}graft"
pgrep -x serena >/dev/null 2>&1 && DEFER="${DEFER:+$DEFER,}serena"
pgrep -x opencode >/dev/null 2>&1 && DEFER="${DEFER:+$DEFER,}opencode"
export DOTUPGRADE_DEFER="$DEFER"
if [ -n "$DEFER" ]; then
    LIVE_NAMES="$(for p in opencode claude codex agy serena; do pgrep -x "$p" >/dev/null 2>&1 && echo "$p"; done | sort -u | tr '\n' ' ')"
    echo "  Live agent session(s): ${LIVE_NAMES}- deferring: $DEFER"
else
    echo "  No live agent sessions - full sweep."
fi

# --- 1. System packages: apt on Linux/WSL, brew on macOS. ---
case "$(uname -s)" in
    Linux)
        if command -v apt-get &>/dev/null; then
            echo "  Upgrading apt packages..."
            sudo apt-get update && sudo apt-get upgrade -y
        else
            echo "  apt-get not found - skipping system packages."
        fi
        ;;
    Darwin)
        if command -v brew &>/dev/null; then
            echo "  Upgrading brew packages..."
            brew update && brew upgrade
        else
            echo "  brew not found - skipping system packages."
        fi
        ;;
esac

# --- 2. AI tools: the update_ai_tools section, defer-aware. ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/update_ai_tools.sh"

# --- Deferred report: what to re-run when quiet. ---
if [ -n "$DEFER" ]; then
    echo ""
    echo "Deferred (live sessions): $DEFER"
    echo "  Re-run 'dot upgrade' with those sessions closed to pick them up."
else
    echo "dot upgrade complete."
fi
unset DOTUPGRADE_DEFER
