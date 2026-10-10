#!/usr/bin/env bash
set -euo pipefail

# install_mobile_dev() contract (SDD plan 2026-10-10-mobile-dev-wsl-linux-macos,
# Task 2): Maestro CLI, agent-device, and a standalone JDK 17+.
#
# Maestro is NOT installed via the vendor's own
# `curl -fsSL https://get.maestro.mobile.dev | bash` one-liner (the task
# brief's original plan). Task 1's review found that installer only runs
# `unzip -qt` on what it downloads - a corruption check, not an authenticity
# one - which is exactly why .chezmoidata.yaml pins versions.maestro_version
# and versions.maestro_sha256 (tests/mobile_dev_version_pins_contract.sh).
# Running the vendor script would make that pin meaningless: "latest" would
# be fetched with no checksum enforced at all. install_mobile_dev() therefore
# downloads the pinned release asset directly and verifies it itself, the
# same shape install_powershell() already uses for its own pinned, verified
# download (net_timeout-wrapped curl, sha256_cmd, warn-and-continue on a
# mismatch - never abort under `set -e`).
#
# The release asset lives at a URL built from versions.maestro_version with a
# "cli-" tag prefix that is NOT part of the stored version string itself
# (confirmed directly against the real mobile-dev-inc/maestro release via
# `gh release view`/`gh release download` while writing this test - see the
# exact URL required below). Maestro is a single-user tool: it installs
# under $HOME/.local/opt (no $SUDO, unlike install_powershell()'s
# /opt/microsoft/... system install) with its binary symlinked into
# $HOME/.local/bin, which docs/agent-context-tools.md already documents as
# on PATH (uv's own tool shims land there the same way).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"

. "$repo_root/tests/lib.sh"

[ -f "$tmpl" ] || { fail "$tmpl missing"; finish; }

# --- Structure: the function exists and is wired at the established gate ---
require "$tmpl" 'install_mobile_dev()'

# --- Maestro: manual pinned+verified install, NOT the vendor curl|bash ----
forbid "$tmpl" 'get.maestro.mobile.dev'
require "$tmpl" 'mobile-dev-inc/maestro/releases/download/cli-'
require "$tmpl" '.versions.maestro_version'
require "$tmpl" '.versions.maestro_sha256'
require "$tmpl" 'maestro CHECKSUM MISMATCH'
require "$tmpl" '$HOME/.local/opt'
require "$tmpl" '$HOME/.local/bin/maestro'

# --- agent-device: npm global, reusing core's Node, command -v guarded ----
require "$tmpl" 'npm install -g agent-device'
require "$tmpl" 'command -v agent-device'

# --- Standalone JDK 17+: apt + brew branches, JAVA_HOME persisted ----------
require "$tmpl" 'openjdk-{{ .versions.jdk_version }}-jdk'
require "$tmpl" 'openjdk@{{ .versions.jdk_version }}'
require "$tmpl" 'JAVA_HOME'

# --- Maestro MCP registration for Claude Code and Codex, idempotent -------
# (Task 3): mirrors the serena precedent's own gating shape (command -v
# <agent> guard, "mcp get" idempotency check, warn-and-continue on failure -
# never abort under `set -e`). Maestro has no vendor setup helper, unlike
# serena, so the raw "mcp add" call is used directly.
require "$tmpl" 'claude mcp add maestro'
require "$tmpl" 'codex mcp add maestro'
require "$tmpl" 'claude mcp get maestro'
require "$tmpl" 'codex mcp get maestro'

# --- Wiring: the placeholder comment is replaced by a real call -----------
forbid "$tmpl" 'a sibling task (WSL/Windows installer plan) inserts the mobile_dev install call here'
require "$tmpl" 'install_mobile_dev'

# --- Executable: render the real template with mobile_dev+agent_toolkit on
# and confirm the call actually reaches main(), is bash-syntax-valid, and
# that toggling mobile_dev off removes the call (same render-based style as
# tests/mobile_dev_agent_toolkit_dependency_contract.sh's Part D). ----------
if command -v chezmoi >/dev/null 2>&1; then
    groups() { # $1 = mobile_dev bool, $2 = agent_toolkit bool
        printf '{"core":true,"modern_cli":true,"fonts":true,"agent_toolkit":%s,"opencode_cli":true,"opencode_desktop":false,"claude_cli":true,"claude_desktop":false,"chatgpt_cli":true,"chatgpt_desktop":false,"antigravity_cli":true,"antigravity_desktop":false,"remote_access":true,"remote_access_server":true,"guardrail":false,"dev_desktop":true,"vscode_settings":false,"mobile_dev":%s}' "$2" "$1"
    }

    out="$(mktemp -d)/rendered.sh"
    render_to "$out" sh "$(groups true true)"
    grep -Fq 'install_mobile_dev' "$out" || fail "render (mobile_dev=true, agent_toolkit=true): install_mobile_dev call missing"
    if command -v bash >/dev/null 2>&1; then
        bash -n "$out" || fail "rendered installer has invalid bash syntax with mobile_dev=true"
    fi
    pass

    render_to "$out" sh "$(groups false true)"
    if grep -Fq 'install_mobile_dev$' "$out" || grep -Eq '^\s*install_mobile_dev\s*$' "$out"; then
        fail "render (mobile_dev=false): install_mobile_dev must not be CALLED"
    else
        pass
    fi
    # The function DEFINITION is unconditional (like install_powershell()'s);
    # only the call site is gated.
    grep -Fq 'install_mobile_dev()' "$out" || fail "render (mobile_dev=false): install_mobile_dev() definition must still be present"

    render_to "$out" sh "$(groups true false)"
    grep -Fq 'mobile_dev requires agent_toolkit' "$out" || fail "render (mobile_dev=true, agent_toolkit=false): safety-net warning missing"
    if grep -Eq '^\s*install_mobile_dev\s*$' "$out"; then
        fail "render (agent_toolkit=false): install_mobile_dev must not be called without agent_toolkit"
    else
        pass
    fi
else
    skip "chezmoi not installed"
fi

finish
