# Skills install strategy — findings

Investigation (2026-08-30) into how this repo should install curated skill
subsets across agents, prompted by wanting a few [GStack](https://github.com/garrytan/gstack)
skills without the whole thing.

## TL;DR

- The repository-owned curated-skill catalog uses `~/.claude/skills`, the
  shared `~/.agents/skills` for OpenCode and Codex, and
  `~/.gemini/antigravity-cli/skills` for Antigravity.
- The `skills` CLI is used with the Claude Code, OpenCode, and Codex adapters.
  OpenCode and Codex discover `~/.agents/skills`; the verified Claude Code copy supplies
  Antigravity because the Antigravity adapter has an incompatible destination.
- The installer verifies every `<target>/<name>/SKILL.md`, then generates an
  OpenCode-only command at `~/.config/opencode/commands/<name>.md`. Claude
  Code, Antigravity CLI, and OpenCode use `/teach <topic>`; Codex uses
  `/skills`, then `$teach <topic>`.
- Only OpenCode receives generated command adapters.
- Codex has no generated command files. It discovers the shared skill catalog.
- Generated commands carry a dotfiles ownership marker. Refresh replaces or
  removes only marker-owned commands; a user-owned name conflict is preserved
  with a warning.
- Refresh explicitly with `scripts/update_ai_tools.sh` on Linux/macOS/WSL or
  `scripts/update_ai_tools.ps1` on Windows, then restart OpenCode. Start a new
  Claude Code, Antigravity CLI, or Codex CLI session before using a refreshed
  skill. `chezmoi apply` is not a reliable upstream-skill refresh trigger.
- New installs refresh catalog-managed entries in `~/.agents/skills` without
  deleting other content there.

## The `skills` CLI

`npx skills@latest <cmd>` — `add`, `remove`, `update`, `list`, `find`, `use`, `init`.
Requires Node ≥ 22.20 (repo installs Node 24 — fine, but gate on `command -v npx`).

### `skills add` — the flags that matter

| Flag | Meaning |
| :--- | :--- |
| `-s, --skill <names…>` | install only these skills (space-separated; `'*'` = all) |
| `-a, --agent <ids…>` | install to these agents (`'*'` = all detected) |
| `-g, --global` | user-level (`~/…`) instead of project-level (`./…`) |
| `-y, --yes` | no prompts |
| `--copy` | real file copies, not symlinks |
| `-l, --list` | print the repo's skills and exit (no install) |
| `--all` | `= --skill '*' --agent '*' -y` |

Valid agent ids include: `claude-code`, `opencode`, `antigravity`,
`antigravity-cli`, `codex`, `cursor`, `windsurf`, `zed`, … (~75).

Sources: `owner/repo`, full GitHub/GitLab URL, any git URL, local path, or a
direct `SKILL.md` / archive URL.

### Current shared-directory behaviour

```
npx skills add mattpocock/skills -s retro -a claude-code opencode -g -y --copy
```
→ creates **`~/.agents/skills/retro/SKILL.md`** and
**`~/.claude/skills/retro/SKILL.md`** (both real directories). OpenCode and
Codex discover the shared directory; Antigravity receives its copy at
`~/.gemini/antigravity-cli/skills`. The CLI also runs a Socket/Snyk risk check
per skill.

### `--copy` vs symlink

Use `--copy`. The default symlinks the agent dirs at a cache/clone location
that isn't guaranteed to persist, and this repo already fights symlink
fragility on Windows (see `run_onchange_generate_identities.ps1.tmpl`).

### npm 12 + `npx` gotchas (live-confirmed 2026-08-30, first real deploy)

- **npm 12's npx prints a benign two-line hint to STDERR on every
  invocation** (exit 0): `npm notice run npx` / `npm notice run 'skills'
  add …`. Verified on npm 12.0.2.
- **On Windows PowerShell 5.1** under `$ErrorActionPreference=Stop`, the
  installers' `2>&1` redirect promotes that first stderr line into a
  terminating error: all three `skills add` calls died instantly and were
  reported as "install failed - npm notice run npx" while nothing landed in
  `~\.agents\skills` / `~\.claude\skills`. (Mechanism reproduced in
  isolation: any native stderr line → immediate throw, message = that line.)
- **Fix: `--loglevel=error` on every `npx skills@latest` call** — suppresses
  notice-level output entirely (verified: stderr empty, exit 0), so only a
  real error reaches stderr and trips the `Invoke-Quietly` catch. Applied in
  all four files.
- **On Linux/WSL**, the same notices are only console noise, but the first
  real `chezmoi update` run hung indefinitely at the skills CLI's intro
  banner: chezmoi run_onchange scripts inherit the terminal TTY on stdin, and
  nothing redirected it. **Fix: `< /dev/null` on every `$SK add` call**
  (stdin at EOF can never block on a prompt); with it, the exact full command
  completes non-interactively in ~5s. `net_timeout` stays as the wall-clock
  backstop for genuine network stalls.

## Historical investigation notes (pre-native-target lifecycle)

The remaining notes preserve prior source evaluation and implementation history.
They do not describe the current installation destinations or refresh workflow;
follow the TL;DR above for the supported lifecycle.

### Matt Pocock's skills — proposed change

> **Update (2026-09-02):** curated set widened from 9 → 12 (11 as-is +
> `mp-code-review`). Added `teach` (`/teach`; user-invoked, scaffolds a
> per-workspace lesson tree — run it in a dedicated folder, not a real repo),
> `writing-for-agents` (model-invoked; complements Superpowers'
> `writing-skills`), and `resolving-merge-conflicts` (no Superpowers
> equivalent). Upstream is nested again under `skills/engineering/` and
> `skills/productivity/`; the `skills` CLI still resolves by skill name, so the
> `-s` list is unaffected. Deliberately still skipped: `tdd`, `diagnosing-bugs`
> (Superpowers `test-driven-development` / `systematic-debugging` cover these),
> and the tracker/process skills (`to-spec`, `to-tickets`, `wayfinder`,
> `triage`, `implement`) plus `setup-matt-pocock-skills` — the latter is a
> per-repo config wizard (writes `docs/agents/*.md` + a `## Agent skills` block;
> downloads nothing) that only those tracker skills need.

The 9 curated skills all still exist, now as **flat** names:

`codebase-design`, `domain-modeling`, `grill-with-docs`,
`improve-codebase-architecture`, `code-review`, `prototype`, `research`,
`grilling`, `handoff`

Replace the entire clone + `cp -r` curated-copy + `plugin.json` +
`agy plugin install` block (in `run_onchange_install_packages.sh.tmpl`,
`.ps1.tmpl`, and both `scripts/update_ai_tools.*`) with:

```sh
npx --yes skills@latest add mattpocock/skills \
  -s codebase-design domain-modeling grill-with-docs improve-codebase-architecture \
     code-review prototype research grilling handoff \
  -a claude-code opencode antigravity -g -y --copy
```

Update path: `npx --yes skills@latest update -g -y` (or re-run the `add`).

### Open decision: the `code-review` name — RESOLVED

> **Resolved (2026-08-30): option 3** — staged-rename to `mp-code-review`
> (clone, copy to a staging dir, patch `name:` frontmatter, `skills add
> <local dir>`). Not option 1: `code-review` as a plain skill name proved
> too confusable in practice with the repo's own `/code-review` command and
> Superpowers' `receiving-code-review` skill. The brittle part of option 3
> (skills update re-creating the original name) doesn't apply — the staging
> re-runs on every install/update, always writing the patched name. What
> follows is the original analysis for the record.

The current block renames Matt Pocock's `code-review` → `mp-code-review` to
avoid confusion with this repo's own `/code-review` command and Superpowers'
`receiving-code-review`. The `skills` CLI has **no rename flag**. Options:
1. Keep it as `code-review` (it's a *skill*, the repo's is a *command* — different
   surfaces; likely fine).
2. Drop `code-review` from the `-s` list.
3. `mv ~/.agents/skills/code-review ~/.agents/skills/mp-code-review` (and the
   `~/.claude/skills/` copy) as a post-step — brittle, `skills update` would
   re-create the original.

~~Recommend **1**.~~

## `frontend-design` (parked note)

Anthropic's `frontend-design` skill lives in **`anthropics/skills`** (not
`vercel-labs/agent-skills` — the `skills` README example is wrong).
`anthropics/skills` also has `canvas-design`, `brand-guidelines`,
`artifacts-builder`, `webapp-testing`, `mcp-builder`.

If wanted:
```sh
npx --yes skills@latest add anthropics/skills -s frontend-design \
  -a claude-code opencode antigravity -g -y --copy
```
User's call — candidate, not decided.

## Curated set widened (2026-09-13): +3 skills

Three more single-skill installs joined the same sequence (all counts from
skills.sh at add time):

| Skill | Source | Installs | What it does |
| :-- | :-- | :-- | :-- |
| `find-skills` | `vercel-labs/skills` | 3.4M | lets an agent search and install skills from skills.sh mid-session |
| `agent-browser` | `vercel-labs/agent-browser` | 843.8K | browser automation: navigate, click, fill, scrape, screenshot |
| `skill-creator` | `anthropics/skills` | 380.0K | Anthropic's skill-authoring lifecycle tool with benchmarks and eval viewer |

(`writing-great-skills` from `mattpocock/skills` was in this batch too, but was
removed 2026-09-14: mattpocock renamed it upstream to `writing-for-agents`
(commit 1fc6573), which the Matt Pocock batch above already installs — the old
name failed silently on every run.)

Each gets its own `skills add` (one skill per source repo, so no `-s` list to
keep in sync), same `-a claude-code opencode antigravity -g -y --copy` flags:

```sh
npx --yes --loglevel=error skills@latest add vercel-labs/skills -s find-skills -a claude-code opencode antigravity -g -y --copy
npx --yes --loglevel=error skills@latest add vercel-labs/agent-browser -s agent-browser -a claude-code opencode antigravity -g -y --copy
npx --yes --loglevel=error skills@latest add anthropics/skills -s skill-creator -a claude-code opencode antigravity -g -y --copy
```

No overlap with Superpowers or the existing curated set: `skill-creator` is a
lifecycle/benchmark harness (vs Superpowers' `writing-skills` process guide),
and `find-skills` / `agent-browser` have no installed equivalent.

## Curated set widened (2026-09-24): +2 taste skills

Two skills from `Leonxlnx/taste-skill` (MIT), picked for function rather than
install count. Counts from skills.sh on 2026-09-19.

| Skill | Source | Installs | What it does |
| :-- | :-- | :-- | :-- |
| `design-taste-frontend` | `Leonxlnx/taste-skill` | 497.0K | greenfield visual direction for landing/marketing pages: infers a style from the brief, three tunable dials (variance, motion, density), pre-flight anti-slop checklist |
| `redesign-existing-projects` | `Leonxlnx/taste-skill` | 361.9K | brownfield: scans an existing UI's styling, diagnoses generic patterns against a checklist, applies targeted upgrades without changing behaviour |

One `skills add` with a two-name `-s` list, since both come from the same repo:

```sh
npx --yes --loglevel=error skills@latest add Leonxlnx/taste-skill -s design-taste-frontend redesign-existing-projects -a claude-code opencode codex -g -y --copy
```

Overlap, accepted on purpose: `design-taste-frontend` fires on the same work
as `anthropics/frontend-design`, which stays installed. If they double-trigger
in practice, drop one; nothing else depends on either.

Considered from the same repo and left out:

- `design-taste-frontend-v1` — frozen pre-rewrite ruleset, kept upstream for
  compatibility only.
- `high-end-visual-design`, `minimalist-ui`, `industrial-brutalist-ui` — style
  presets, mutually exclusive aesthetics. Add one per project once its look is
  chosen (`npx skills add Leonxlnx/taste-skill -s <name>` in that repo), not
  globally where all three would compete on the same prompt.
- `gpt-taste` — the same rules tuned for GPT/Codex failure modes; a
  model-specific duplicate of the flagship.
- `stitch-design-taste` — emits a DESIGN.md for Google Stitch; inert without a
  Stitch integration.
- `brandkit`, `image-to-code`, `imagegen-frontend-web`, `imagegen-frontend-mobile`
  — need an image-generation capability the Claude Code, OpenCode and Codex
  CLIs do not have; they produce images, not code.
- `full-output-enforcement` — not a design skill; a completeness guard that
  Claude Code and the Superpowers verification workflow already cover.

Note: the names above are the skills' `name:` fields, which is what `-s`
matches; the repo folders are named differently (`taste-skill/`,
`redesign-skill/`). The wiring contract test checks the on-disk `SKILL.md`,
so a renamed skill fails loudly on the next apply rather than silently.

## GStack — do not wire in

Confirmed by reading `design-review/SKILL.md` and `qa-only/SKILL.md` (2 of the
9 requested): both are, verbatim, *"tightly coupled to gstack infrastructure"*:

- shell out to `~/.claude/skills/gstack/bin/gstack-*` (`gstack-slug`,
  `gstack-skill-start`/`-end`, `gstack-decision-log`, `gstack-config`, …)
- require the `browse` binary — built from source with `bun run build`, which
  is what `./setup` does
- read hardcoded paths: `~/.claude/skills/gstack/{ETHOS.md, docs/, scripts/}`,
  `<skill>/templates/`, `<skill>/references/`
- write to `~/.gstack/projects/<slug>/`

`skills add garrytan/gstack -s design-review` copies just that one dir →
broken (no `bin/`, no `browse`). There is no `--only`/subset flag in GStack's
`./setup` either.

The only working install is the full one:
```sh
git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack \
  && (cd ~/.claude/skills/gstack && ./setup)
# OpenCode: ./setup --host opencode  → ~/.config/opencode/skills/gstack-*/
```
~40 skills, pulls `bun` + Playwright + builds `browse`.

**Decision (2026-08-30): GStack stays out of the install entirely.** Also has
no `--host antigravity` (hosts: `claude, codex, opencode, cursor, kiro,
factory` + informational `slate/openclaw/hermes/gbrain`), so "full install for
Claude + Antigravity + OpenCode" isn't even possible — only Claude + OpenCode.

### To evaluate it later (do this in a worktree, not the dotfiles)

1. `git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack`
   then `(cd ~/.claude/skills/gstack && ./setup)` — and `./setup --host opencode`
   for OpenCode. (~40 skills, `bun`, Playwright, builds `browse`.)
2. Use the 9 of interest for real work; note which shared pieces each actually
   touches (`bin/gstack-*`, `browse`, `ETHOS.md`, `docs/`, `scripts/`,
   `<skill>/templates|references`, `~/.gstack/`).
3. Try to lift just the wanted skills + the minimum shared plumbing into a
   standalone dir, stripping the telemetry / decision-log / question-log
   wiring that isn't wanted. Track that curated set as its own thing and diff
   it against upstream periodically.
4. Or find standalone equivalents elsewhere (`skills find <keyword>`,
   `anthropics/skills`, `vercel-labs/agent-skills`, `mattpocock/skills`) — a
   plain `SKILL.md` with no factory harness is far cheaper to carry.

Skills of interest: `plan-devex-review`, `devex-review`, `qa-only`,
`document-release`, `codex`, `plan-design-review`, `design-review`,
`design-consultation`, `design-shotgun`.

## Other parked notes

- **`benchmark cso vs Cloudflare / Trail of Bits / Anthropic`** — about
  GStack's `/cso` (OWASP + STRIDE security skill, not in the 9). Separate
  future evaluation.

## Implementation status (done in this worktree)

1. ✅ Matt Pocock block → `skills` CLI in all four files. New
   `install_agent_skills()` in `run_onchange_install_packages.sh.tmpl`
   (called from both the apt and brew branches), equivalent inline block in
   `.ps1.tmpl`, and both `scripts/update_ai_tools.*`. Gated on `npx`.
2. ✅ `frontend-design` from `anthropics/skills` added to the same sequence.
3. ✅ `mp-code-review` staged (rename + `name:` patch → `skills add <local dir>`).
4. ✅ `docs/tool-parity.md` + `README.md` rows updated.
5. ✅ GStack: no code; this doc is the record.
6. ✅ 2026-09-13: `find-skills`, `agent-browser`, `skill-creator`,
    `writing-great-skills` added to all four files (see the
    "Curated set widened" section above); `tests/install_agent_skills_arguments.sh`
    expected-call count bumped 3 → 7 to match. 2026-09-14:
    `writing-great-skills` removed again (renamed upstream to
    `writing-for-agents`, already installed) — expected-call count now 6.
7. ✅ 2026-09-24: `design-taste-frontend` and `redesign-existing-projects`
    from `Leonxlnx/taste-skill` added to all four files as one two-name
    `skills add` (see "Curated set widened (2026-09-24)"); expected-call
    count now 7, catalog fallback `skipped=18`.

Not done / open:
- ~~`-a antigravity` unverified with `agy` present on a box~~ **Verified
  2026-08-31**: with agy installed on both Windows and WSL, agy loads the
  skills from `~/.agents/skills/` on both - no `agy plugin install <staged
  dir>` fallback needed.
- 2026-08-30 follow-up (post first real deploy): npm-12 `npm notice` stderr
  hint + PS 5.1 `2>&1` promotion killed all Windows installs, and an
  inherited-TTY stdin hang froze the WSL run — both fixed with
  `--loglevel=error` (+ `< /dev/null` on the Unix side); see the npm 12
  gotchas section above. WSL side now fully populated (8 + mp-code-review +
  frontend-design verified in `~/.agents/skills` and `~/.claude/skills`).
- 2026-08-31 post-review hardening (adversarial code review findings): the
  PS-side skills/clone calls moved from `Invoke-Quietly` to
  `Invoke-WithTimeout` jobs (wall-clock guard per tool-parity's Network-step
  timeouts contract + detached stdin + fresh-EAP session; exit-code throw
  keeps real failures reported); `choco install opencode` got a Get-Command
  guard + try/catch (a bare call aborts the whole script under
  `$ErrorActionPreference=Stop` on choco-less non-admin runs); the bash-side
  `sed` rename got a SKILL.md existence guard (bare failure trips `set -e`);
  both clones are timeout-wrapped; PATH refresh after the choco install now
  prepends choco's bin instead of a full registry rebuild (which can drop a
  session-only `%APPDATA%\npm` and silently skip later npm/npx steps).
- Verification state: full elevated Windows `chezmoi update` passes verified
  twice live (incl. the choco-opencode → PATH → skills sequence); full WSL
  pass verified live; **the macOS/brew branch has never executed this code**
  — reasoning-only for BSD sed / `cp -r "$src/."` portability. Run one manual
  `install_agent_skills` on a Mac when available.
- 2026-09-15 P2 follow-up: Unix updater and installer now report all four
  curated-skill summaries as skipped when `npx` is unavailable. The wiring
  contract executes the Unix lifecycle with a stale Antigravity target and a
  simulated promotion failure, verifying both the failed summary and rollback.
