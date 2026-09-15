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

forbid() {
    if grep -Fq -- "$2" "$repo_root/$1"; then
        fail "$1: must not contain '$2'"
    fi
}

require README.md "16-group taxonomy"
require README.md "Platform installers (16-group gated)"
require README.md "Config template (16 promptBoolOnce groups)"
require README.md "cloudflared only"
require README.md "Linux/macOS/WSL"
require README.md "select-packages.ps1"
require README.md "Join-Path (chezmoi source-path)"
require README.md "~/.claude/skills"
require README.md "~/.agents/skills"
require README.md "OpenCode and Codex discover"
require README.md "~/.config/opencode/commands"
require README.md "~/.gemini/antigravity-cli/skills"
require README.md "/teach"
require README.md "update_ai_tools.sh"
require README.md "update_ai_tools.ps1"
require README.md "restart OpenCode"
require README.md 'Claude Code, Antigravity CLI, and OpenCode use `/teach <topic>`.'
require README.md "Codex CLI:"
require README.md '`/skills`, then enter `$teach <topic>`.'
require README.md "Only OpenCode receives generated command adapters."
require README.md "Codex has no generated command files."
forbid README.md 'OpenCode and Codex discover `~/.agents/skills`'
require docs/skills-install-strategy.md "~/.agents/skills"
require docs/skills-install-strategy.md "OpenCode and Codex discover"
require docs/skills-install-strategy.md "~/.gemini/antigravity-cli/skills"
require docs/skills-install-strategy.md "Only OpenCode receives generated command adapters."
require docs/skills-install-strategy.md "Codex has no generated command files."
forbid docs/skills-install-strategy.md 'Codex `/teach'
require docs/agent-skill-wiring-design.md "Only OpenCode receives generated command adapters."
require docs/agent-skill-wiring-design.md "Codex has no generated command files."
require docs/tool-parity.md "Only OpenCode receives generated command adapters."
require docs/tool-parity.md "Codex has no generated command files."
require docs/package-groups.md 'shared `~/.agents/skills` (OpenCode and Codex)'
forbid docs/package-groups.md "Zero wiring by design"
forbid docs/package-groups.md "no codex surface"
require docs/menu-demo.md "opencode_cli"
require docs/menu-demo.md "opencode_desktop"

printf 'PASS: documentation package-group consistency\n'
