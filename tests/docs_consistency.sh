#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repo_root"

. "$repo_root/tests/lib.sh"

forbid_regex() {
    if grep -Eqi -- "$2" "$repo_root/$1"; then
        fail "$1: must not match '$2'"
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
require docs/package-groups.md 'no generated command adapters'
# The zero-wiring / no-codex-surface claims (#118) described a third
# behavior that no longer exists anywhere - chatgpt_cli gates the curated
# skills pass on both installer twins, so Codex skills wiring is real and
# documented. Forbidden repo-wide (source, docs, comments), not just in
# package-groups.md, so the wording cannot quietly return in a twin.
repo_files() {
    # git ls-files keeps this to tracked (+ untracked, minus ignored) files,
    # but a linked worktree's .git pointer can be unreadable from a translated
    # path (WSL on a Windows checkout) - fall back to walking the tree.
    if git -C "$repo_root" rev-parse >/dev/null 2>&1; then
        git -C "$repo_root" ls-files -coz --exclude-standard
    else
        (
            cd -- "$repo_root" &&
                find . \( -name .git -o -name node_modules -o -name graft \) -prune -o -type f -print0
        )
    fi
}
while IFS= read -r -d '' f; do
    forbid_regex "$f" 'zero[[:space:]]+wiring'
    forbid_regex "$f" 'no[[:space:]]+codex[[:space:]]+surface'
done < <(repo_files)
require docs/menu-demo.md "opencode_cli"
require docs/menu-demo.md "opencode_desktop"

require docs/backup-restore.md "dotbackup.sh"
require docs/backup-restore.md "dotrestore.sh"
require docs/backup-restore.md "dotbackup.ps1"
require docs/backup-restore.md "dotrestore.ps1"
require docs/backup-restore.md "~/.dot_backups"
require docs/backup-restore.md ".7z"
require docs/backup-restore.md "-mhe=on"
require docs/backup-restore.md "Dotfiles backup passphrase"
require docs/backup-restore.md "refuses to overwrite"
require docs/backup-restore.md "chezmoi init"
require docs/backup-restore.md "chezmoi apply"
forbid_regex docs/backup-restore.md '(^|[[:space:]`])(tar|zip|unzip|compress-archive|expand-archive)[[:space:]]'
forbid_regex docs/backup-restore.md '(^|[^[:alnum:]])[^[:space:]`]+\.(tar|tar\.gz|tgz|zip)([^[:alnum:]]|$)'
forbid_regex docs/backup-restore.md '(^|[[:space:]`])(cp|copy-item|scp|rsync|robocopy|xcopy)[[:space:]].*(\.ssh|\\\.ssh)'

finish
