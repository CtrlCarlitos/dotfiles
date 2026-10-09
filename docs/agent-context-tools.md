# Agent context tools — Serena

Practical guide to the agent-context tool this repo installs under the
`agent_toolkit` package group: what it is for and what the installer already
wired up. Graft, the second tool this page used to cover, was removed on
2026-10-09 — see [Graft (removed)](#graft-removed).

## TL;DR

- **Serena** ([`oraios/serena`](https://github.com/oraios/serena)) is an MCP
  server that gives agents **semantic** code retrieval and editing — LSP-backed
  find-symbol / find-references / replace-symbol instead of regex greps. Use it
  when precision matters (renames, call-site edits, navigating a big codebase).
- **Installer state**: installed wherever the `agent_toolkit` group runs and
  registered as an MCP server in every client it finds. There is no per-repo
  step.

## What the installer set up

| | Serena |
| :--- | :--- |
| Install | `uv tool install -p 3.13 serena-agent` (uv auto-manages Python 3.13; no system Python needed) |
| Client wiring | Registered as an MCP server per client: Claude first checks `claude mcp get serena` and runs `serena setup claude-code` only when missing; `serena setup codex` (run once the Codex CLI is installed); JSON merge into OpenCode's global `mcp` key (opencode reads MCP only from that block); Antigravity gets it in the top-level `~/.gemini/config/mcp_config.json` with `forceAllToolsEager: true` — agy marks every server's tools lazy by default, lazy tools are only reachable through the generic `call_mcp_tool` invoker guardrail denies, and a plugin bundle would prefix the server names into forms guardrail's registry does not know (#175) |
| agy command form | `serena start-mcp-server --context ide-assistant` (the installed binary, not an `npx -y` form: with one, agy exposed no tools at all, a slow npx cold start being the prime suspect, #175) |
| Per-repo step | None — works in whatever project the client opens; a per-project `.serena/` memory dir is optional |
| Upgrade | `dot upgrade` only (via `scripts/update_ai_tools.*`; `dot up` never upgrades): `uv tool upgrade serena-agent` |

`dot upgrade` skips Serena while a serena process is live (uv recreates the
package directory a running server resolves from): close the agents first, as
`dot upgrade` says.

## Serena notes

- **Per-project memory**: Serena maintains memories under a `.serena/` dir per
  project. It's optional — created on demand, never required for the MCP tools
  to work. Add `.serena/` to your `.gitignore` if you don't want it committed
  (or do want it shared across machines — your call).
- **Language servers are per-language and optional**: Serena drives real
  language servers (pyright, gopls, typescript-language-server, …) for its
  semantic tools. Without one for a language, it falls back to regex-based
  tools for that language — install the LSP you actually work in, skip the
  rest.

## Troubleshooting

- **`command not found: serena` right after install**: PATH refresh. uv puts
  its tool shims in `~/.local/bin`; a fresh shell (or `exec $SHELL`) fixes it.
  On Windows, uv's tool shim dir (`%USERPROFILE%\.local\bin`) must be on PATH —
  the installer already prepends it for the current session.
- **Serena's semantic tools inert for a language**: no language server
  installed for it — see the note above; the LSPs are opt-in per language.

## Where the wiring values live

The MCP server definitions the installers register for OpenCode and agy
(Serena's `start-mcp-server --context ide-assistant`, the installed binary),
the Codex package name and the list of agent CLIs the curated skills are
installed for all come from one file: `.chezmoidata/agents.yaml`. Both
installers render from it and `scripts/update_ai_tools.{sh,ps1}` read it at
runtime, so a change is one edit; `tests/agent_catalog_contract.sh` fails if
any value reappears as a literal elsewhere.

OpenCode's entries **converge** on that catalog on every apply (#230). A server
whose binary is installed is added when absent, and an existing entry has its
`command` repaired if it differs: an older `npx -y <package> mcp` entry, which
made OpenCode wait about 46 s for npx on every start, becomes the installed
binary. Your `enabled` flag and every other key you set are kept, and the file
is only written when something actually changes. If a tool rewrites an entry in
another form, the next apply repairs it. `tests/opencode_mcp_sync_contract.sh`
runs both installers' registration code against these cases.

## Serena dashboard auto-open

Serena opens its web dashboard in a browser tab every time a client starts the
MCP server, which with four agents means a tab per session. The dotfiles turn
that off by default: `agents.serena.open_dashboard: false` in
`.chezmoidata/agents.yaml`. The dashboard still runs; the installers only
re-assert Serena's `web_dashboard_open_on_launch` line in
`~/.serena/serena_config.yml` after every `serena init`, so a fresh machine or
a Serena upgrade converges too. Open it by hand at
`http://localhost:24282/dashboard/` (Serena picks the next port when several
instances run).

The interface is managed the same way: `agents.serena.dashboard_interface:
browser`. Left empty, Serena picks the platform default, which on Windows and
macOS is the native app mode with one tray icon per instance. Every agent
session and every `claude -p` run spawns its own instance, and instances that
exit leave ghost icons behind until the tray is hovered (48 were counted on
2026-09-24 after a description-optimizer run). `browser` creates no icon.

To get the tab or the tray icons back on one machine, override the catalog in
that machine's `~/.config/chezmoi/chezmoi.toml` and re-apply (config data beats
catalog data):

```toml
[data.agents.serena]
open_dashboard = true
dashboard_interface = "tray_manager"   # one global icon for all instances; or "app"
```

`tests/serena_dashboard_contract.sh` keeps the default, both twins and this
section in step.

## Graft (removed)

Graft ([`@nanonets/graft`](https://www.npmjs.com/package/@nanonets/graft)), a
per-repo context graph with its own MCP server and agent hooks, was installed
under `agent_toolkit` until 2026-10-09. A benchmark on two real codebases
(Odoo and Phoenix), across Sonnet and Haiku, showed no gain in accuracy or
cost: Sonnet mostly ignored the graph, and every session paid for graft's
hooks and instructions anyway. It was dropped.

The installers and `dot upgrade` now **retire** it from machines an earlier
run set it up on, quietly and only where something is left
(`graft_retire` in `scripts/lib/agent-skills.sh`, `Invoke-GraftRetirement` in
`scripts/lib/ps-skills.ps1`; `tests/graft_retirement_contract.sh` executes both).
Only what is unambiguously graft's goes:

- the `graft` MCP entries the dotfiles registered: OpenCode's global
  `opencode.json`, agy's `~/.gemini/config/mcp_config.json`, Codex
  (`codex mcp remove graft`) and Claude Code's user scope
  (`claude mcp remove graft -s user`) — an entry named `graft` that runs
  something else is kept;
- what `graft init` wrote for every project: the hook entries that run
  `graft-hooks.cjs` in `~/.claude/settings.json` and `~/.codex/hooks.json`, a
  statusLine that runs `graft-statusline.cjs`, graft's `Bash(graft…)` allow
  entries and `graft/` footer regex, the shims
  (`~/.claude/helpers/graft-*.cjs`, `~/.codex/hooks/graft/`) and graft's skill
  (a skills dir named `graft` whose `SKILL.md` says `name: graft`);
- the global npm package `@nanonets/graft` (from the prefix it lives in), then
  graft's own state directory `~/.graft`.

**Repos you ran `graft init` in keep their local files** — the gitignored
`graft/` graph, `.claude/helpers/graft-*.cjs`, `.claude/skills/graft/`, the
`graft` entry in the repo's `.mcp.json` / `opencode.json`, graft's fenced
section in `AGENTS.md` and its entries in the repo's `.claude/settings.json`.
Nothing runs them once the package is gone; delete them by hand when you next
touch the repo. This source tree's `.gitignore` and `.chezmoiignore` keep
ignoring those leftovers so they are never committed or applied to `$HOME`.
