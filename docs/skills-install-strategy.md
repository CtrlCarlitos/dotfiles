# Skills install strategy — findings

_Status (2026-10-05): implemented and current. This is the as-built
strategy; the original design rationale is
[agent-skill-wiring-design.md](agent-skill-wiring-design.md), and
`tests/agent_skill_wiring_contract.sh` enforces the wiring._

Investigation (2026-08-30) into how this repo should install curated skill
subsets across agents, prompted by wanting a few [GStack](https://github.com/garrytan/gstack)
skills without the whole thing.

## Current state (2026-10-05)

- **Catalog**: 20 curated skills, `scripts/curated-agent-skills.txt` (one name
  per line; the single source of truth for the verify pass and the OpenCode
  command shims).
- **Sources** (8 `skills add` calls, in order): `mattpocock/skills` (12:
  `codebase-design`, `domain-modeling`, `grill-with-docs`,
  `improve-codebase-architecture`, `prototype`, `research`, `grilling`,
  `handoff`, `teach`, `writing-for-agents`, `pr`, `retro`), `mattpocock/skills` staged as
  `mp-code-review`, `anthropics/skills` (`frontend-design`),
  `vercel-labs/skills` (`find-skills`), `vercel-labs/agent-browser`
  (`agent-browser`), `CtrlCarlitos/skills` (`skill-creator`, our fork, and
  `code-search`, two separate adds), `Leonxlnx/taste-skill`
  (`design-taste-frontend`, `redesign-existing-projects`).
- **Agents**: Claude Code, OpenCode and Codex through the `skills` CLI
  (`.chezmoidata/agents.yaml` `skills.agents`); Antigravity CLI by copying the
  verified Claude copy; generated commands for OpenCode only.
- **Lifecycle** (installers and `update_ai_tools.*`, which `dot upgrade` runs):
  retired-skill cleanup, then per source skip-or-`skills add --copy`, then
  verify every catalog entry's `SKILL.md` per agent, Antigravity fan-out, and
  OpenCode command generation, then a per-agent installed/skipped/failed
  summary. `dot up` never refreshes skills; the installer only runs when its
  rendered content changes.
- **Version check**: a source is skipped when every skill is present and
  upstream `HEAD` equals the commit recorded in
  `$XDG_STATE_HOME/dotfiles/skills-sources`; `DOT_SKILLS_FORCE=1` forces a
  refetch (see "Skipping sources that have not changed"). Skipped sources
  print `<name>: up to date`.
- **Retired skills**: `scripts/retired-agent-skills.txt` (`<skill> <source>`);
  currently `resolving-merge-conflicts mattpocock/skills`.
- **Superseded state**: changing a source's skill list (a skill added or retired)
  changes its state key; the old line is pruned at the end of the run (see
  "Skipping sources that have not changed").
- **Why not `skills update`**: it takes no `--copy` or `-a` and re-links the
  Claude copy as a symlink; see below.

## TL;DR

- The repository-owned curated-skill catalog uses `~/.claude/skills`, the
  shared `~/.agents/skills` for OpenCode and Codex, and
  `~/.gemini/antigravity-cli/skills` for Antigravity.
- The `skills` CLI is used with the Claude Code, OpenCode, and Codex adapters.
  OpenCode and Codex discover `~/.agents/skills`; the verified Claude Code copy supplies
  Antigravity because the Antigravity adapter has an incompatible destination.
- The installer verifies every `<target>/<name>/SKILL.md`, then generates an
  OpenCode-only command at `~/.config/opencode/commands/<name>.md`.
  Claude Code, Antigravity CLI, and OpenCode use `/teach <topic>`. Codex CLI: open `/skills`, then enter `$teach <topic>`.
- Only OpenCode receives generated command adapters.
- Codex has no generated command files. It discovers the shared skill catalog.
- Generated commands carry a dotfiles ownership marker. Refresh replaces or
  removes only marker-owned commands; a user-owned name conflict is preserved
  with a warning.
- Refresh with `dot upgrade` (which runs the updater) or directly with
  `scripts/update_ai_tools.sh` on Linux/macOS/WSL or
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

### Skipping sources that have not changed (2026-10-04)

`skills add` re-fetches every skill, and a cold `npx skills@latest` costs 30+ s
even when nothing moved upstream, so `dot upgrade` used to pay that on every
run. Each source is now skipped when **all** of these hold:

- `DOT_SKILLS_FORCE` is not `1`;
- every skill of the source is present for Claude (`~/.claude/skills`) and for
  OpenCode/Codex (`~/.agents/skills`);
- upstream `HEAD` (one `git ls-remote`) equals the commit recorded after the
  last successful install of that exact source + skill list + agent list
  (`$XDG_STATE_HOME/dotfiles/skills-sources`, default
  `~/.local/state/dotfiles/skills-sources`; `%USERPROFILE%\.local\state\...` on
  Windows).

A source key is `repo|skills|agents`, so changing the selection (as when `pr` and
`retro` joined the Matt batch) makes the old key stale: the batch reinstalls once
(its new skills are missing, and the new key has no entry), and at the end of the run
`skills_prune_state` / `Invoke-SkillsStatePrune` drops every line for a repo the run
checked unless the run produced that exact key. Lines for repos the run did not touch
are never removed, and a quiet run rewrites nothing. No manual state deletion is ever
needed.

Anything unknown (offline, no state, a failed add) installs as before; a failed
add is never recorded. `mp-code-review`, which is staged from a clone, is
skipped on the same rule against `mattpocock/skills`. Helpers:
`skills_up_to_date` / `skills_record_source` in `scripts/lib/agent-skills.sh`,
`Invoke-SkillsSource` in `scripts/lib/ps-skills.ps1`. To force a refetch:
`DOT_SKILLS_FORCE=1 dot upgrade`. `dot up` is unaffected: it never upgrades, and
the installer only runs when its rendered content changes.

**Why not `skills update`?** Measured on skills 1.7.0 in a throwaway HOME: with
nothing to do it is cheap (3.5 s, writes nothing), but it takes no `--copy` or
`-a` flags, and on a real update it re-linked the Claude copy as a symlink into
`~/.agents/skills`. These installs are deliberately copies, so it cannot replace
`add --copy`. The check is therefore done here, per source commit (coarser than
the CLI's per-skill folder hash, but it needs no tree hash and no API quota).

### Retiring a skill (2026-10-04)

`resolving-merge-conflicts` was added on 2026-09-02 (no Superpowers equivalent), then
removed from `mattpocock/skills` on 2026-09-24. The `skills` CLI does not fail on a
missing name, it just installs the rest (the log said "Selected 10 skills" for the 11
we asked for), so the dead entry went unnoticed and a stale local copy kept the
verify pass green. It is now out of the catalog and the install lists (10 Matt
Pocock skills, 18 curated in total).

To stop a skill lingering on machines that already have it, list it in
`scripts/retired-agent-skills.txt` as `<skill> <source>`. The installers and
`dot upgrade` remove it from `~/.claude/skills`, `~/.agents/skills`, the Antigravity copy,
the OpenCode command shim we generated, and the skills CLI lock, but only when the lock
records that exact source: a skill of the same name you wrote yourself is never
touched. Helpers: `skills_remove_retired` (`scripts/lib/agent-skills.sh`) and
`Invoke-RetiredSkillsCleanup` (`scripts/lib/ps-skills.ps1`).

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
They do not describe the current installation destinations, counts or refresh
workflow (the `skills update` suggestion in the first one is superseded by "Why
not `skills update`?" above); follow "Current state" and the TL;DR above for the
supported lifecycle.

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

(`resolving-merge-conflicts` was retired again on 2026-09-24, see "Retiring a
skill".) The original 9 curated skills all still exist, now as **flat** names:

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
  -a claude-code opencode codex -g -y --copy
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

## `frontend-design` (installed)

Anthropic's `frontend-design` skill lives in **`anthropics/skills`** (not
`vercel-labs/agent-skills` — the `skills` README example is wrong).
`anthropics/skills` also has `canvas-design`, `brand-guidelines`,
`artifacts-builder`, `webapp-testing`, `mcp-builder`.

No longer parked: `frontend-design` is in the curated catalog
(`scripts/curated-agent-skills.txt`) and installs for every agent in the same
sequence:

```sh
npx --yes skills@latest add anthropics/skills -s frontend-design \
  -a claude-code opencode codex -g -y --copy
```

## Curated set widened (2026-09-13): +3 skills

Three more single-skill installs joined the same sequence (all counts from
skills.sh at add time):

| Skill | Source | Installs | What it does |
| :-- | :-- | :-- | :-- |
| `find-skills` | `vercel-labs/skills` | 3.4M | lets an agent search and install skills from skills.sh mid-session |
| `agent-browser` | `vercel-labs/agent-browser` | 843.8K | browser automation: navigate, click, fill, scrape, screenshot |
| `skill-creator` | `CtrlCarlitos/skills` (fork of `anthropics/skills`, see below) | 380.0K upstream | Anthropic's skill-authoring lifecycle tool with benchmarks and eval viewer |

(`writing-great-skills` from `mattpocock/skills` was in this batch too, but was
removed 2026-09-14: mattpocock renamed it upstream to `writing-for-agents`
(commit 1fc6573), which the Matt Pocock batch above already installs — the old
name failed silently on every run.)

Each gets its own `skills add` (one skill per source repo, so no `-s` list to
keep in sync), same `-a claude-code opencode codex -g -y --copy` flags:

```sh
npx --yes --loglevel=error skills@latest add vercel-labs/skills -s find-skills -a claude-code opencode codex -g -y --copy
npx --yes --loglevel=error skills@latest add vercel-labs/agent-browser -s agent-browser -a claude-code opencode codex -g -y --copy
npx --yes --loglevel=error skills@latest add CtrlCarlitos/skills -s skill-creator -a claude-code opencode codex -g -y --copy
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

## Curated set widened (2026-09-24): +1 home-grown skill, `code-search`

Our own skill, from `CtrlCarlitos/skills` (MIT). It fixes a failure seen in
practice on 2026-09-24: graft's fenced AGENTS.md block tells the agent to
query the graph "for ANY task", but in this repo the graph covers one Lua
file (no parser for PowerShell, shell or chezmoi templates), so every session
burned two empty graph queries before falling back to grep, while graft's
prompt hook kept nagging "run graft ask".

| Skill | Source | What it does |
| :-- | :-- | :-- |
| `code-search` | `CtrlCarlitos/skills` | probe once per session which tools can see the code (graft graph built and covering the language, serena LSP for the language, rg, grep), classify the question (structural, textual, API surface, historical, non-code), route down the ladder graft > serena > rg > grep, read hits at the exact range, and stop re-asking a semantic tool after one empty result |

```sh
npx --yes --loglevel=error skills@latest add CtrlCarlitos/skills -s code-search -a claude-code opencode codex -g -y --copy
```

Graft itself was removed from the dotfiles on 2026-10-09 (no accuracy or cost
benefit in a benchmark; see [Graft (removed)](agent-context-tools.md#graft-removed)),
and its skill in `~/.claude/skills/graft` is retired with it. `code-search`
stays: its probe finds no graph and routes serena > rg > grep.

## skill-creator: our drop-in fork (2026-09-24)

`skill-creator` is installed from `CtrlCarlitos/skills`, a fork of
`anthropics/skills` `skills/skill-creator` (Apache-2.0, license kept). Same
name and description, so it replaces Anthropic's copy in place and triggers
identically. The fork exists because the upstream description optimizer
cannot run on Windows (anthropics/skills#1827): `select()` on a pipe fails
every query, the HTML report is written in the locale codec, the project root
is taken from the script's cwd, and a real invocation of the skill under test
does not count as a trigger.

How it is maintained (in the skills repo):

- `vendor/skill-creator/UPSTREAM` pins the upstream commit;
  `vendor/skill-creator/patches/000N-*.patch` is the patch queue.
- `scripts/sync-skill-creator.sh` (a script of the `CtrlCarlitos/skills` repo,
  not of this one) rebuilds `skills/skill-creator` from the pin plus the
  patches; `--check` verifies the committed tree equals that rebuild
  and runs in that repo's CI.
- To update from upstream: bump `commit=` in UPSTREAM, run the sync script, fix
  any patch that no longer applies, commit all three together.
- When upstream ships the fixes, delete the patches that no longer apply and,
  once none are left, switch these four call sites back to `anthropics/skills`
  and drop the fork.

## Curated set widened (2026-10-05): +2 Matt skills, `pr` and `retro` (#269)

Only `pr` and `retro` were taken from `mattpocock/skills`; they join the 10 already
installed as-is (12 + `mp-code-review`, 20 curated in total). Upstream layout, checked
at `mattpocock/skills@4588b32`: both live under `skills/engineering/`.

| Skill | What it is | Ships |
|---|---|---|
| `pr` | Writing guidance for a PR **body**: Summary (the smallest useful view: pseudocode, call/file/component tree, Mermaid, diff), Evidence (before/after), Merge Danger (one-way or two-way door, blast radius). Credits HumanLayer's `show-me`, which is not a dependency. | `SKILL.md`, `CREDITS.md`, `agents/openai.yaml` |
| `retro` | An on-demand retrospective on a coding session: proposes changes to the agent's *environment* (navigation pointers, automated checks, coding standards, AGENTS.md size, tool economy, information access), ranked by severity. Calls `writing-for-agents` first. | `SKILL.md`, `agents/openai.yaml` with `allow_implicit_invocation: false`; `SKILL.md` carries `disable-model-invocation: true` |

**Boundaries (what they are not).**

- `pr` only shapes the description. Implementation, verification, review, and the human
  decision to push, open or merge a PR stay with Superpowers and the repository's own
  rules; it does not replace `mp-code-review` or Superpowers review, and it authorizes no
  git or network write. Keep required repository fields (an issue reference such as
  `Refs: #N`); the template is adapted, never used to drop them. Evidence must be real:
  say when a before/after was not captured or a check was not run.
- `retro` is on demand, never automatic after a task or a PR. It reads the session you name
  (the current one by default), reports what the transcript does not show instead of
  inventing it, and presents ranked proposals only. Running it authorizes no edit to a
  global `AGENTS.md`, a guardrail, a skill, an installed tool, or an issue.
- Versus `handoff` (continuation context for the next session), `mp-code-review` / Superpowers
  review (evaluate a change), and Superpowers' session diagnosis (investigate one
  workflow that went wrong): `retro` looks at a finished session and proposes durable
  environment improvements.
- Terminology: `pr` uses the repository's `GLOSSARY.md` when there is one and does nothing
  special when there is not. Neither skill calls the `setup-matt-pocock-skills` wizard.

**Invoking them.**

| Agent | `pr` | `retro` |
|---|---|---|
| Claude Code | name the skill or describe the task ("write the PR body") | `/retro [session]` only (model invocation is disabled, so it is not in the model's skill list) |
| Codex | name the skill in the request | `$retro [session]` only (`allow_implicit_invocation: false`) |
| OpenCode | name the skill (it loads it with its `skill` tool); a generated `/pr` command also exists, not exercised | `/retro [session]` (generated command) |
| Antigravity | the skill is copied; invocation not verified (see below) | same |

A new agent session is needed after install; a running session keeps the skills it started
with. The OpenCode commands are the generated shims already described above: a command you
wrote yourself (a `pr.md` of your own) is left untouched and reported.

**Refreshing.** Nothing new: `dot upgrade` runs the existing lifecycle. The Matt batch's
state key now includes `pr` and `retro`, so the first run after this change reinstalls the
batch once and prunes the superseded key (see "Skipping sources that have not changed").
`skills add --copy` copies whole directories, and so do the Antigravity fan-out and the
Windows `Copy-Item -Recurse`, so `agents/openai.yaml` and `CREDITS.md` arrive intact.
`tests/curated_pr_retro_contract.sh` holds the four install lists identical, runs the Unix
verification pass over the upstream layout, and checks nested files, the retained
invocation metadata and command-shim ownership.

**Smoke tests (real agents, Windows 11, 2026-10-05; Claude Code 2.1.289, Codex 0.160.0,
OpenCode 1.18.34, agy 1.2.17).** Run read-only against commit `7a40e68` (`pr`, with `Refs: #269`
required) and against two past session transcripts (`retro`).

| Harness | `pr` | `retro` |
|---|---|---|
| Claude Code | pass: 3 sections, small diff view, evidence honest ("no test run ... not verified"), merge danger with door + blast radius, `Refs` line kept | pass: explicit `/retro`; on a startup-only transcript it reported there was nothing to retro rather than invent findings; on a 35-turn session it gave 5 ranked, line-referenced proposals |
| Codex | pass: same shape, shorter; read `~/.agents/skills/pr/SKILL.md` itself | pass: `$retro`; loaded `writing-for-agents`; 5 ranked proposals, each tied to something in the transcript, with unknowns named |
| OpenCode (plan agent) | pass: loaded the `pr` skill through its skill tool | pass: `/retro` command loaded `retro` and `writing-for-agents`; 5 ranked proposals with transcript line references. First attempt could not read a transcript outside the project (`external_directory` auto-rejected) and returned nothing, so give it a path inside the working directory |
| agy | pass (WSL, 2026-10-10, headless, `agy --dangerously-skip-permissions -p "..."` — the same flag the interactive alias already carries, passed explicitly since a non-interactive call never sources it): 3 sections, evidence grounded in the real commit (`tests/ps_template_define_before_use_contract.sh`, the actual before/after error and pass output), merge danger with door + blast radius, `Refs: #269` line kept | not run: same invocation form should work, not yet tried |

None of the runs changed a file, installed anything, or touched a steering file.
Recurring `retro` findings were genuinely present in the transcript (a flaky temp-directory
lookup by `mtime`, a pin test printing `PASS (0 checks)`, a repeated pin-bump recipe).

**Applicability.** Windows (native): installed and smoke-tested above for three of four
agents (agy untested on native Windows). WSL, Linux, macOS and devcontainers: the shell
library is executed by the contract tests on Linux CI (install lists, verification pass,
pruning); agy `pr` is now also real-agent smoke-tested on WSL (above). The Windows
installer and updater twins are held to the same lists by the contract and exercise the
same helper library (`ps-skills.ps1`) under `pwsh`; the full Windows install path was not
re-run end to end. Untested combinations: agy `retro` on any OS, agy `pr` outside WSL,
every agent on macOS, and any agent inside a devcontainer.

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
    `writing-for-agents`, already installed).
7. ✅ 2026-09-24: `design-taste-frontend` and `redesign-existing-projects`
    from `Leonxlnx/taste-skill` added to all four files as one two-name
    `skills add` (see "Curated set widened (2026-09-24)").
8. ✅ 2026-09-24: `code-search` from `CtrlCarlitos/skills` added to all four
    files (see "Curated set widened (2026-09-24): +1 home-grown skill");
    `tests/install_agent_skills_arguments.sh` expects 8 controlled `npx`
    calls; the catalog has 18 entries (the fallback `skipped=` count is the
    catalog length).

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
