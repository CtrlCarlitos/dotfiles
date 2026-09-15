#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require() {
    grep -Fq -- "$2" "$repo_root/$1" || fail "$1: missing '$2'"
}

require README.md "16-group taxonomy"
require README.md "Platform installers (16-group gated)"
require README.md "Config template (16 promptBoolOnce groups)"
require README.md "cloudflared only"
require README.md "Linux/macOS/WSL"
require README.md "select-packages.ps1"
require README.md "Join-Path (chezmoi source-path)"
require README.md "~/.claude/skills"
require README.md "~/.config/opencode/skills"
require README.md "~/.config/opencode/commands"
require README.md "~/.gemini/antigravity-cli/skills"
require README.md "~/.codex/skills"
require README.md "/teach"
require README.md "update_ai_tools.sh"
require README.md "update_ai_tools.ps1"
require README.md "restart OpenCode"
require README.md "user-validation trial"
require docs/skills-install-strategy.md "~/.config/opencode/skills"
require docs/skills-install-strategy.md "~/.gemini/antigravity-cli/skills"
require docs/skills-install-strategy.md "~/.codex/skills"
require docs/skills-install-strategy.md "user-validation trial"
require docs/menu-demo.md "opencode_cli"
require docs/menu-demo.md "opencode_desktop"

printf 'PASS: documentation package-group consistency\n'
