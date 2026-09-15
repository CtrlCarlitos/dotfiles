# Agent Skill Wiring Design

## Goal

Install the same curated skill set globally for Claude Code, OpenCode,
Antigravity CLI, and Codex CLI. Each tool must load skills from its own
configured directory. OpenCode must additionally expose every curated skill as
a slash command, such as `/teach`.

This design replaces new writes to `~/.agents/skills`. It does not delete an
existing directory there because it may contain user-managed skills.

## Scope

- Apply the same curated set in the Linux/macOS and Windows installers.
- Apply the same refresh behavior in `update_ai_tools.sh` and
  `update_ai_tools.ps1`.
- Generate OpenCode slash-command adapters only for installed curated skills.
- Document installation locations, refresh commands, and the restart
  requirement.
- Add contracts for target paths, generated commands, and documentation.

Out of scope:

- Symlinks between agent directories.
- Changing Superpowers, Guardrail, MCP, or agent-plugin installation.
- Removing pre-existing `~/.agents/skills` content.
- Claiming Codex discovery is confirmed before the requested user test.

## Native Targets

| Tool | Curated skill target | Installation method |
| --- | --- | --- |
| Claude Code | `~/.claude/skills/<name>/SKILL.md` | `skills add -a claude-code -g --copy` |
| OpenCode | `~/.config/opencode/skills/<name>/SKILL.md` | `skills add -a opencode -g --copy` |
| Antigravity CLI | `~/.gemini/antigravity-cli/skills/<name>/SKILL.md` | copy the fetched curated skill directories to the documented CLI path |
| Codex CLI | `~/.codex/skills/<name>/SKILL.md` | `skills add -a codex -g --copy` for this trial |

The official sources for these paths are Claude Code's skills guide,
OpenCode's skills guide, Antigravity CLI's plugins guide, and Codex's skills
guide. The `skills` CLI adapters are used only where their output matches the
chosen target. The Antigravity adapter is not used as its final destination.

## Curated Catalog

Add a repository-owned, line-oriented curated-skill catalog containing the
installed names:

```text
codebase-design
domain-modeling
grill-with-docs
improve-codebase-architecture
prototype
research
grilling
handoff
teach
writing-for-agents
resolving-merge-conflicts
mp-code-review
frontend-design
find-skills
agent-browser
skill-creator
```

The existing source-specific fetch logic remains responsible for downloading
these skills, including the staged `code-review` to `mp-code-review` rename.
The catalog is the single source of truth for the post-install fan-out and
OpenCode command generation. Tests require every catalog entry to reach each
agent target; individual upstream source fetches are expected to supply only
their own subsets.

## Installer And Updater Flow

Both platform installers and both AI-tool updaters use this order:

1. Fetch or refresh every curated source.
2. Install the fetched skills with the Claude Code, OpenCode, and Codex
   adapters. The completed Claude Code copy is the verified source for the
   Antigravity CLI copy, so Antigravity never depends on the `skills` CLI's
   incompatible adapter destination.
3. Verify `<target>/<name>/SKILL.md` for every catalog entry.
4. Generate or refresh OpenCode commands for verified OpenCode skills.
5. Print a per-agent summary of installed, skipped, and failed skills.

The update scripts are the explicit refresh interface. `chezmoi apply` is not
documented as a reliable upstream-skill update trigger because `run_onchange`
only runs when Chezmoi detects a changed rendered script.

The user-facing update commands are:

```sh
bash "$(chezmoi source-path)/scripts/update_ai_tools.sh"
```

```powershell
& (Join-Path (chezmoi source-path) 'scripts\update_ai_tools.ps1')
```

## OpenCode Commands

For each catalog entry with an existing
`~/.config/opencode/skills/<name>/SKILL.md`, generate:

```text
~/.config/opencode/commands/<name>.md
```

Each file uses the supported OpenCode Markdown-command format:

```md
---
description: Run the <name> skill
---
Load the native `<name>` skill with the skill tool, then follow it for: $ARGUMENTS
```

This makes `/teach <topic>`, `/research <question>`, and every other curated
skill directly invokable. Commands are generated after skill verification, so
a missing skill never receives a dangling command.

Generated files include a dotfiles ownership marker. On refresh, the
command already uses a curated skill name, preserve it, emit a warning, and do
not overwrite it.

OpenCode reads configuration and command files at startup. Documentation must
tell users to restart OpenCode after installation or refresh.

## Migration

New installs do not populate `~/.agents/skills`. Existing content at that path
is left untouched. It can continue to be discovered by tools that support it
until the user removes it after validating the native-target installation.

This avoids deleting unknown user-managed skills and avoids symlink behavior
that is fragile across Windows and Unix hosts.

## Documentation

The README gains a concise Agent Skills section covering:

- the four target directories;
- OpenCode's generated slash commands and examples;
- the Linux/macOS/WSL and Windows refresh commands;
- restart requirements; and
- the Codex target's trial status pending user validation.

The detailed skill-install strategy document is updated to remove stale claims
that one `skills add` command universally writes `~/.agents/skills` or that
all agents discover it.

## Verification

Automated contracts must verify:

- all four installer/update paths target the curated catalog;
- no new curated install targets `~/.agents/skills`;
- Antigravity receives its documented CLI path;
- Codex receives the requested Vercel target;
- OpenCode commands are generated only after a matching `SKILL.md` exists;
- marker-owned commands update safely and user-owned conflicts are preserved;
- README and strategy documentation state the supported refresh workflow.

Manual acceptance on the WSL host:

1. Run the updater.
2. Restart Claude Code, OpenCode, Antigravity CLI, and Codex CLI.
3. Invoke `/teach` and one additional curated command in each agent.
4. Report Codex behavior before treating its Vercel target as established.
