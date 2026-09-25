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
# shellcheck disable=SC2088  # literal ~ assertion: docs must reference the tilde form
require README.md "~/.claude/skills"
# shellcheck disable=SC2088
require README.md "~/.agents/skills"
require README.md "OpenCode and Codex discover"
require README.md "/teach"
require README.md "update_ai_tools.sh"
require README.md "update_ai_tools.ps1"
require README.md "restart OpenCode"
forbid README.md 'OpenCode and Codex discover `~/.agents/skills`'
# The agent-skills detail moved out of README into the strategy doc (#139);
# the assertions moved with it.
# shellcheck disable=SC2088  # literal ~ assertion: docs must reference the tilde form
require docs/skills-install-strategy.md "~/.claude/skills"
# shellcheck disable=SC2088
require docs/skills-install-strategy.md "~/.config/opencode/commands"
# shellcheck disable=SC2088
require docs/skills-install-strategy.md "~/.gemini/antigravity-cli/skills"
require docs/skills-install-strategy.md 'Claude Code, Antigravity CLI, and OpenCode use `/teach <topic>`.'
require docs/skills-install-strategy.md "Codex CLI:"
require docs/skills-install-strategy.md '`/skills`, then enter `$teach <topic>`.'
require docs/skills-install-strategy.md "restart OpenCode"
# shellcheck disable=SC2088
require docs/skills-install-strategy.md "~/.agents/skills"
require docs/skills-install-strategy.md "OpenCode and Codex discover"
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
# shellcheck disable=SC2088
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

# ---------------------------------------------------------------- #137 sweep
# Stale references that made agents/users type commands that fail. Forbidden
# phrases, so they cannot come back:
#   - dead install_* toggle names (the config template has zero install_*
#     keys; dotfiles-doctor errors on them) - allowed ONLY in the
#     docs/package-groups.md rename map, which documents them on purpose
#   - the never-existed docker-compose aliases dc/dcu/dcd/dcl (OMZ's real
#     ones are dco/dcupd/dcdn/dclf) - matched as the literal 'alias dcu'
#   - 'dotup', the pre-`dot`-family command name (\b keeps this from
#     matching the legit scripts/dotupgrade.* mentions)
#   - 'opencode antigravity', the pre-codex `-a` agent list (codex replaced it)
for d in README.md docs/*.md; do
    [ "${d##*/}" = "package-groups.md" ] && continue
    forbid_regex "$d" 'install_ai_tools|install_modern'
    forbid_regex "$d" '\bdotup\b'
    forbid_regex "$d" 'opencode antigravity'
done
forbid_regex docs/zsh-tips.md 'alias dcu'
forbid_regex docs/tmux-nvim-tutorial.md 'alias dcu'

finish
