# Agent context tools — Serena & Graft

Practical guide (2026-09-12) to the two agent-context tools this repo installs
under the `agent_toolkit` package group: what each is for, what the installer
already wired
up, and the one manual step (per-repo Graft activation) that's deliberately
left to you.

## TL;DR

- **Serena** ([`oraios/serena`](https://github.com/oraios/serena)) is an MCP
  server that gives agents **semantic** code retrieval and editing — LSP-backed
  find-symbol / find-references / replace-symbol instead of regex greps. Use it
  when precision matters (renames, call-site edits, navigating a big codebase).
- **Graft** ([`@nanonets/graft`](https://www.npmjs.com/package/@nanonets/graft))
  is a **repo map / context graph**: small linked markdown nodes with exact
  file:line spans, built per repo. Use it for orientation ("where does X
  live?") and token savings (read a node's crux instead of whole files).
- **They complement each other**: Graft answers *where things are and how they
  fit together* cheaply and statically; Serena answers *exactly what this
  symbol references* at edit time. Graft first for orientation, Serena when
  you're about to cut.
- **Installer state**: both are installed wherever the `agent_toolkit` group
  runs,
  Serena is registered as an MCP server in every client it finds, Graft's
  telemetry is off. The only manual step is per-repo: `graft init && graft
  build`.

## What the installer set up

| | Serena | Graft |
| :--- | :--- | :--- |
| Install | `uv tool install -p 3.13 serena-agent` (uv auto-manages Python 3.13; no system Python needed) | `npm i -g @nanonets/graft` (with npm's `--allow-scripts` allowlist for its tree-sitter native builds) |
| Client wiring | Registered as an MCP server per client: Claude first checks `claude mcp get serena` and runs `serena setup claude-code` only when missing; `serena setup codex`; JSON merge into OpenCode's global `mcp` key (graft joins it there too — opencode reads MCP only from that block); Antigravity gets both via the `dotfiles-mcp` plugin bundle (`~/.gemini/config/plugins/`), because agy defers plain global `mcp_config.json` servers until a manual `/mcp` while plugin-bundled servers start eagerly | Plugin bundle alongside serena's (same file); Claude and Codex get graft's MCP via graft's own global registration on first `graft init` |
| Per-repo step | None — works in whatever project the client opens; a per-project `.serena/` memory dir is optional | `graft init` + `graft build` (see below) |
| Telemetry | n/a | Disabled by the installer (`graft telemetry disable`) |
| Upgrade | `uv tool upgrade serena-agent` (also run by `scripts/update_ai_tools.*`) | `graft upgrade` (also run by `scripts/update_ai_tools.*`) |

Both MCP registrations use the same launch command:
`serena start-mcp-server --context ide-assistant`.

## Graft per-repo activation

Graft's graph is per-repo and gitignored (`graft/`), so activation is a
one-time, per-repo choice:

```sh
graft init          # interactive client picker — commits AGENTS.md wiring etc.
graft build         # builds the local graft/ graph (deterministic, $0, no key)
```

Non-interactive equivalent: `graft init --agents claude agents`. Re-run
`graft build` after big code changes to refresh the graph. This repo is
already wired (dogfooding) — see the Graft block in `AGENTS.md` for how to
query it.

### CLI greatest hits

The only in-repo copy of this table — `AGENTS.md` deliberately does not
repeat it. Note the graph itself only covers `dot_config/nvim/init.lua` in
this repo (graft has no parser for `.sh`/`.ps1`/`.tmpl`/`.toml`), so these
commands answer only for that file here.

| Command | What it's for |
| :--- | :--- |
| `graft ask "<question>" --source` | Ranked nodes with the relevant code spans inlined |
| `graft grep "<literal>"` | Exhaustive match list over indexed files (ask is top-N, not complete) |
| `graft callers <symbol>` | Precomputed, exact who-calls-this edges (`--direction out`, `--depth N`) |
| `graft map` | Token-budgeted orientation for a repo you're new to |
| `graft skeleton <file>` | Every definition's signature + span, ~10× cheaper than reading the file |

Graft `--deep` LLM summaries need a user-supplied `GRAFT_API_KEY`/provider —
see Graft's own docs (the [`@nanonets/graft`](https://www.npmjs.com/package/@nanonets/graft)
npm page) for setup; everything above works without a key.

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

- **`command not found: serena` / `graft` right after install**: PATH refresh.
  Both land on PATH via their installers (`~/.local/bin` for uv tools, npm's
  global bin for graft); a fresh shell (or `exec $SHELL`) fixes it. On
  Windows, uv's tool shim dir (`%USERPROFILE%\.local\bin`) must be on PATH —
  the installer already prepends it for the current session.
- **Graft install blocked / binary errors about tree-sitter**: npm 12 blocks
  install scripts by default, which silently skips graft's tree-sitter parser
  native builds. The installers pass the exact `--allow-scripts` allowlist
  npm's own warning prints; if you install by hand, include it.
- **Serena's semantic tools inert for a language**: no language server
  installed for it — see the note above; the LSPs are opt-in per language.

## Where the wiring values live

The MCP server definitions the installers register for OpenCode and agy
(Serena's `start-mcp-server --context ide-assistant`, Graft's
`npx -y @nanonets/graft mcp`), Graft's npm `--allow-scripts` list, the Codex
package name and the list of agent CLIs the curated skills are installed for
all come from one file: `.chezmoidata/agents.yaml`. Both installers render
from it and `scripts/update_ai_tools.{sh,ps1}` read it at runtime, so a change
is one edit; `tests/agent_catalog_contract.sh` fails if any value reappears as
a literal elsewhere.

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
