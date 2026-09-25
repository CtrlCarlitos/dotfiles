# `dot repo` — repository baseline: audit and apply

Date: 2026-09-25. Status: handover. Design agreed with Carlitos in the
2026-09-24/25 session (option 1 of 3, below); nothing implemented yet.

This document is written for whoever builds it, human or agent. It carries the
audit that motivated it, the baseline to enforce, the exact GitHub API surface,
the CLI shape, the tests, and the traps found tonight. Read it start to finish
before writing code.

## 1. Why

On 2026-09-24 a `Co-Authored-By: Claude` trailer landed on `main` in two repos.
The machine-side cause is fixed (`~/.claude/settings.json` attribution off, plus
the shared `commit-msg` hook from #149). But GitHub re-added the trailer on its
own while squash-merging #147, because that PR's branch predated a history
rewrite and its commit range still contained the old commits. No hook on any
machine can stop a message GitHub composes server-side. Only a repository rule
can: `commit_message_pattern` on `main`.

That led to an audit of every repository's rules, which found that the four
"hardened" repos differ from each other in a dozen places, `skills` has no
protection at all, and the 13 private repos cannot be protected on the current
GitHub plan. The rules exist as intent in
`agent-guardrails/docs/operator-hardening.md` §4 and as a one-off plan in
`agent-guardrails/docs/superpowers/specs/2026-09-15-github-main-protection-design.md`,
but nothing applies them to a new repo or notices drift. `dot repo` is that
tool.

Three ways were weighed. (1) `dot repo` in this repo plus a thin skill in
`CtrlCarlitos/skills`: chosen. (2) A standalone `gh` extension in its own repo:
a fifth repo to protect and release, and the baseline drifts from the docs that
motivate it. (3) Settings-as-code applied by a scheduled workflow inside each
repo: needs an admin-scoped token stored in every repo, which
`operator-hardening.md` exists to forbid.

## 2. Audit, 2026-09-25 (18 non-archived repos)

Legend: ✓ on, ✗ off, · not applicable. "Private ×13" is one column because all
13 private repos share one profile. Numbers are counts.

| Control | dotfiles | agent-guardrails | agent-council | devcontainer-features | skills | Private ×13 |
|---|---|---|---|---|---|---|
| **Branch ruleset on main** | | | | | | |
| Active ruleset, no bypass actors | ✓ | ✓ | ✓ | ✓ | ✗ | plan-gated |
| Require pull request | ✓ | ✓ | ✓ | ✓ | ✗ | · |
| Merge methods allowed by ruleset | all | all | squash only | all | · | · |
| Dismiss stale reviews on push | ✗ | ✓ | ✓ | ✗ | · | · |
| Require conversation resolution | ✗ | ✓ | ✓ | ✗ | · | · |
| Extra approval for unattributed changes | ✓ | ✗ | ✓ | ✓ | · | · |
| Required status checks | 9 | 3 | 1 (`ci`) | 1 (`test`) | ✗ | · |
| Branch must be up to date (strict) | ✗ | ✗ | ✓ | ✗ | · | · |
| Signed commits | ✓ | ✓ | ✓ | ✓ | ✗ | · |
| Linear history | ✗ | ✓ | ✓ | ✗ | ✗ | · |
| Block force push and deletion | ✓ | ✓ | ✓ | ✓ | ✗ | · |
| Commit message rule (no agent trailer) | ✗ | ✗ | ✗ | ✗ | ✗ | · |
| **Tag ruleset `v*`** (no update/delete/force) | ✓ | ✓ | ✓ | ✓ | ✗ | plan-gated |
| **Repository settings** | | | | | | |
| Merge methods enabled on repo | all | squash | squash | squash | all | all |
| Delete branch on merge | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ (12 of 13) |
| Auto-merge | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |
| Wiki off | ✓ | ✓ | ✓ | ✓ | ✗ | mixed |
| Immutable releases | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ |
| **Actions** | | | | | | |
| Allowed actions: allowlist, not "all" | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| Extra allowlist patterns | 1 | 0 | 0 | 3 | · | · |
| SHA pinning required (server) | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| Default token read-only, cannot approve PRs | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (1 can approve) |
| Fork PR runs need approval from all external | ✓ | ✓ | ✓ | ✓ | first-timers only | · |
| Workflows with explicit `permissions:` | 2 of 3 | 2 of 2 | 1 of 1 | 0 of 4 | 0 of 1 | · |
| Actions pinned to SHA in workflow files | 3 of 3 | 3 of 3 | 2 of 2 | 5 of 5 | 0 of 1 | · |
| **Security features** | | | | | | |
| Secret scanning and push protection | ✓ | ✓ | ✓ | ✓ | ✓ | paid add-on |
| Non-provider secret patterns | ✗ | ✗ | ✗ | ✗ | ✗ | · |
| Dependabot alerts | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ (free, just off) |
| Dependabot security updates | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| `dependabot.yml` (version updates) | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| CodeQL default setup | ✓ | ✓ | ✓ | ✓ | ✗ | plan-gated |
| Private vulnerability reporting | ✗ | ✓ | ✓ | ✓ | ✗ | · |
| **Files** | | | | | | |
| SECURITY.md | ✗ | ✓ | ✓ | ✓ | ✗ | ✗ |
| CODEOWNERS | ✗ | ✓ | ✓ | ✗ | ✗ | ✗ |
| LICENSE | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |

Private repos: `GET /repos/{r}/rulesets`, `GET .../branches/main/protection` and
`GET .../code-scanning/default-setup` all answer HTTP 403 "Upgrade to GitHub Pro
or make this repository public". Dependabot alerts and security updates are
available on the free plan and are off on all 13.

The live `agent-guardrails` ruleset differs from its 2026-09-15 spec (spec: one
approval plus an admin bypass; live: zero approvals, no bypass). The live state
is the intended one; `operator-hardening.md` §4 was written after the spec and
says "without bypass actors". This document supersedes both for rule content.

## 3. The baseline

`agent-council` is the strictest repo today and is the base. Everything below
that council does not already have is marked **new**.

### 3.1 Profile `public` — branch ruleset on the default branch

One ruleset named `main-baseline`, `enforcement: active`, `bypass_actors: []`,
`conditions.ref_name.include: ["~DEFAULT_BRANCH"]`.

| Rule | Parameters | Why |
|---|---|---|
| `deletion` | | |
| `non_fast_forward` | | |
| `required_linear_history` | | squash-only below makes this hold by construction; keep it as the server's own check |
| `required_signatures` | | |
| `pull_request` | `required_approving_review_count: 0`, `dismiss_stale_reviews_on_push: true`, `require_code_owner_review: false`, `require_last_push_approval: false`, `required_review_thread_resolution: true`, `require_extra_approval_for_unattributed_changes: true`, `allowed_merge_methods: ["squash"]` | Approvals stay at 0: GitHub forbids approving your own PR, so 1 would hard-block a solo maintainer with no bypass. Squash-only keeps `(#N)` history and one commit per PR. |
| `required_status_checks` | `strict_required_status_checks_policy: true`, `do_not_enforce_on_create: true`, `required_status_checks: [{context: "ci", integration_id: 15368}]` | **Convention (new):** every repo has one aggregating job named `ci` that `needs:` all other jobs. The baseline then never has to know a repo's job names, and adding a job cannot silently escape the gate. `do_not_enforce_on_create` lets a brand-new repo push its first `main`. |
| `commit_message_pattern` **(new)** | `name: "no agent attribution"`, `negate: true`, `operator: "regex"`, `pattern: "(?i)^(co-authored-by:[^\\n]*(claude\|anthropic)\|claude-session:)"` | The server-side guard. Blocks the trailer whether typed, generated, or collected during a squash. Also blocks the `Claude-Session:` trailer web sessions add. Verify on a scratch repo that `^` matches at line starts in GitHub's evaluator; if not, drop the anchor and use `(?i)co-authored-by:[^\n]*(claude\|anthropic)`. |
| `code_scanning` **(new, public only)** | `code_scanning_tools: [{tool: "CodeQL", security_alerts_threshold: "high_or_higher", alerts_threshold: "errors"}]` | CodeQL default setup is already on in 4 repos; this makes its findings block the merge instead of only decorating it. |

Considered and left out, with reasons, so nobody re-litigates them blind:

- `author_email_pattern` / `committer_email_pattern` pinning to the owner's
  address: bots (Dependabot, the updater app) commit with their own
  `@users.noreply.github.com` addresses and GitHub's web-flow signs squash
  commits as `noreply@github.com`. A pattern wide enough to admit them admits
  anyone with a noreply address. Not worth it.
- `required_deployments`, merge queue, `update` rule on branches: no use here.
- `branch_name_pattern`: cosmetic.

### 3.2 Profile `public` — tag ruleset

Name `release-tags`, target `tag`, include `refs/tags/v*`, active, no bypass.
Rules: `deletion`, `non_fast_forward`, `update`, and **(new)**
`required_signatures` so a release tag must be a signed annotated tag.

### 3.3 Repository settings (`PATCH /repos/{r}`)

| Field | Value | Note |
|---|---|---|
| `allow_merge_commit` / `allow_rebase_merge` | `false` | |
| `allow_squash_merge` | `true` | |
| `squash_merge_commit_title` | `PR_TITLE` | |
| `squash_merge_commit_message` | `PR_BODY` **(new)** | Today every repo uses `COMMIT_MESSAGES`, which is what pasted #147's trailers into the squash. With `PR_BODY` the squash body is the PR description. GitHub may still append `Co-authored-by` for distinct commit *authors*; the ruleset rule above is the guarantee, this is the reduction in exposure. |
| `delete_branch_on_merge` | `true` | |
| `allow_update_branch` | `true` **(new)** | Required companion of `strict_required_status_checks_policy`: gives the "Update branch" button. |
| `allow_auto_merge` | `false` | Decision pending (§7). |
| `web_commit_signoff_required` | `true` **(new)** | Web-UI edits carry a sign-off. Harmless, and one more field a drive-by web commit must satisfy. |
| `has_wiki`, `has_projects`, `has_discussions` | `false` | Fewer unreviewed surfaces. Override per repo where used. |

### 3.4 Actions (`/repos/{r}/actions/permissions...`)

| Endpoint | Body |
|---|---|
| `PUT actions/permissions` | `{"enabled": true, "allowed_actions": "selected", "sha_pinning_required": true}` |
| `PUT actions/permissions/selected-actions` | `{"github_owned_allowed": true, "verified_allowed": false, "patterns_allowed": <per-repo list, default []>}` |
| `PUT actions/permissions/workflow` | `{"default_workflow_permissions": "read", "can_approve_pull_request_reviews": false}` |
| `PUT actions/permissions/fork-pr-contributor-approval` | `{"approval_policy": "all_external_contributors"}` |

Audit-only (cannot be set by API, reported as drift): every workflow file has a
top-level `permissions:` block; every `uses:` is a 40-hex SHA (the server flag
enforces this on new runs; the audit says which files still need editing).

### 3.5 Security features

| Endpoint | Body / effect |
|---|---|
| `PUT repos/{r}/vulnerability-alerts` | Dependabot alerts on (204). Works on free private repos. |
| `PUT repos/{r}/automated-security-fixes` | Dependabot security updates on. Works on free private repos. |
| `PATCH repos/{r}` with `security_and_analysis` | `secret_scanning`, `secret_scanning_push_protection`, `secret_scanning_non_provider_patterns` **(new)** all `enabled`. Public only; on private returns 422 without the paid add-on. |
| `PUT repos/{r}/private-vulnerability-reporting` | on. Public only. |
| `PATCH repos/{r}/code-scanning/default-setup` | `{"state": "configured", "query_suite": "default"}`. Public only on this plan. Needs at least one CodeQL-supported language in the repo; treat "no supported languages" as satisfied, not drift. |
| `PUT repos/{r}/immutable-releases` | on **(new default)** for any repo that has at least one release; audit-only note otherwise. |

### 3.6 Files, opened as one pull request per repo when missing

`SECURITY.md` (private reporting link, "latest release only", attestation
verify line where releases exist), `.github/CODEOWNERS` (`* @<owner>`, with the
tripwire framing from `agent-guardrails/.github/CODEOWNERS`),
`.github/dependabot.yml` (`github-actions` weekly always, plus one block per
detected ecosystem), `LICENSE` (audit-only: report missing, never choose one).

### 3.7 Profile `private`

Same repository settings, Actions policy, Dependabot alerts and security
updates, and files. Rulesets, CodeQL and secret scanning are attempted once;
a 403 with "Upgrade" in the body is reported as `plan-gated`, not as drift and
not as an error. If the account moves to GitHub Pro, the same `apply` run
picks them up with no change to the baseline file.

## 4. CLI

`dot repo` joins the `dot` family (`docs/superpowers/specs/2026-09-20-dot-cli-design.md`):
a case arm in `dot_aliases.zsh` and in both PowerShell profiles, delegating to
`scripts/dotrepo.sh`. Deviation to confirm: the other subcommands ship `.sh` and
`.ps1` twins. This one is `gh` + `jq` glue with no OS-specific behaviour, so the
recommendation is one bash implementation and a PowerShell arm that runs it
through Git Bash (present wherever `dot` runs on Windows). If the twin rule is
kept, the `.ps1` is a straight port; the API payloads in §3 are the contract.

```
dot repo audit  [owner/repo | --all] [--json]     # table (as in §2) or JSON; exit 1 on drift, 2 on error
dot repo apply   owner/repo [--dry-run] [--profile public|private]
                 [--checks ci] [--allow-pattern owner/action@*]... [--no-files]
dot repo diff    owner/repo                        # apply --dry-run with the JSON patches printed
```

- Profile defaults from repo visibility; `--profile` overrides.
- `apply` is idempotent: read, compare, write only what differs, re-read, verify.
  Rulesets are matched by name (`main-baseline`, `release-tags`) and updated
  with `PUT`, never duplicated.
- Every write goes through `gh api` with `X-GitHub-Api-Version: 2022-11-28`.
- Never adds a bypass actor. Never pauses a ruleset. Those stay manual (§6).
- The baseline itself lives in `.chezmoidata/repo-baseline.yaml`, read at
  runtime the way `scripts/update_ai_tools.sh` reads `.chezmoidata/agents.yaml`,
  so there is one source of truth and the CI catalog tests can check it.

### 4.1 Skill

A `repo-baseline` skill in `CtrlCarlitos/skills` whose description triggers on
creating a repository, hardening one, or asking why a merge was blocked. Body:
run `dot repo audit <repo>` after `gh repo create`; run `dot repo apply` when
asked; how to read `plan-gated`; the §6 traps. The skill does not embed the
rules, it points at this file and the baseline yaml.

## 5. Tests (contract tests on `tests/lib.sh`, run by `tests/run.sh`)

No live GitHub calls in CI. Fixtures are captured API responses.

1. `tests/repo_baseline_catalog_contract.sh`: the yaml parses; both profiles
   exist; every rule in §3 is present with the values above (grep-level, like
   the other catalog tests); the regex in `commit_message_pattern` matches the
   three trailer shapes seen tonight and does not match a human co-author line.
2. `tests/dotrepo_contract.sh`: with `gh` stubbed to serve fixtures from
   `tests/fixtures/repo-baseline/`, `audit` on the 2026-09-25 capture of
   `skills` reports every ✗ in §2's column; on a fixture matching the baseline
   reports clean and exits 0; `apply --dry-run` emits exactly the payloads in §3
   and performs no write; a 403 "Upgrade" fixture yields `plan-gated`.
3. `tests/dot_cli_contract.sh`: extend for the `repo` arm in all three
   dispatchers and the help text line.
4. Docs: a new `docs/repo-baseline.md` documents the command;
   `docs/tool-parity.md` gains the row.

## 6. Traps found tonight, in order of cost

1. **Squash merges resurrect trailers.** After any history rewrite of `main`,
   every open branch cut before it must be rebased onto the new `main` before
   it is squash-merged, or GitHub collects co-authors from the old commits in
   the PR range. #147 did exactly this. The `commit_message_pattern` rule turns
   this from a silent regression into a blocked merge.
2. **Pausing a ruleset is the only way to force-push `main`** on these repos
   (no bypass actors, by design). Procedure, run by the owner, never by a tool:
   `gh api -X PUT repos/<r>/rulesets/<id> -f enforcement=disabled`, then
   `git push --force-with-lease=main:<old sha> origin main`, then
   `-f enforcement=active`. Leave the window open for seconds, not minutes.
3. **`required_status_checks` needs exact job names** and `integration_id`
   15368 (GitHub Actions). Hence the `ci` aggregating-job convention.
4. **`--force-with-lease` is denied to agents** by the local guardrail
   (`P1.git-push-force`) and by `~/.claude/settings.json`. Rebased branches are
   pushed under a new name and the old PR closed (#148 → #149).
5. **`core.hooksPath` replaces `.git/hooks`.** Only hooks the shared directory
   chains to keep running, and `pre-commit install` refuses while it is set
   (`git config core.hooksPath .git/hooks` opts one repo out). See `docs/git.md`.
6. **Windows line endings.** Python's default text mode writes CRLF and breaks
   shell scripts; write files with heredocs or `newline="\n"`. Deployed
   dotfiles are LF on this Windows machine (`docs/git.md` claims otherwise;
   correct it when touching that page).
7. **Contributor graphs lag.** GitHub recomputes the contributors sidebar from
   the default branch in the background; expect hours. Closed PR pages keep the
   old commits and their trailers forever.

## 7. Open decisions for the owner

| Decision | Options | Recommendation |
|---|---|---|
| GitHub Pro (about 4 USD/month) | buy: rulesets and CodeQL on all 13 private repos; stay free: private repos get only §3.7 | Buy. It is the only way the private repos get any branch protection; `dot repo apply` needs no change either way. |
| `allow_auto_merge` | off (current, 4 of 5) or on (devcontainer-features) | Off. With zero required approvals, auto-merge lets a green Dependabot PR land unread. |
| Squash message source | keep `COMMIT_MESSAGES` or move to `PR_BODY` | `PR_BODY`, see §3.3. |
| `has_projects` | off everywhere, or keep where used | Off by default, per-repo override in the yaml. |
| Twin `.ps1` for `dotrepo` | full twin or Git Bash shim | Shim, see §4. |

## 8. Order of work

1. Baseline yaml + catalog test (RED first).
2. `scripts/dotrepo.sh` `audit` with fixture-driven test; run it live against
   `skills` and compare to §2 by eye.
3. `apply --dry-run`, then `apply` on `skills` (the empty column, lowest risk),
   then the other four public repos, then private.
4. Dispatcher arms, docs, tool-parity row, skill in `CtrlCarlitos/skills`.
5. Add the `ci` aggregating job to every repo whose workflow lacks one; only
   then switch each repo's required check to `ci`.

## Appendix A — the audit prototype used for §2

`gh` + `jq`, read-only, one JSON object per repo. It is the seed for
`dot repo audit --json`; the field names are a reasonable schema to keep.

```bash
#!/usr/bin/env bash
set -uo pipefail
owner="$1"; out="$2"; work="$(mktemp -d)"
api() { gh api "$@" 2>/dev/null; }
status() { gh api -i "$1" 2>/dev/null | head -1 | awk '{print $2}'; }
: > "$work/all.jsonl"
for repo in $(gh repo list "$owner" --limit 200 --json name,isArchived --jq '.[] | select(.isArchived|not) | .name'); do
  r="$owner/$repo"
  api "repos/$r" > "$work/base.json" || continue
  def="$(jq -r .default_branch "$work/base.json")"
  : > "$work/rs.jsonl"
  rs_http="$(status "repos/$r/rulesets")"
  [ "$rs_http" = "200" ] || printf '{"unavailable":"HTTP %s"}\n' "$rs_http" >> "$work/rs.jsonl"
  for id in $([ "$rs_http" = "200" ] && api "repos/$r/rulesets" --jq '.[].id'); do
    api "repos/$r/rulesets/$id" --jq '{name, target, enforcement, bypass: [.bypass_actors[]? | "\(.actor_type):\(.actor_id):\(.bypass_mode)"], refs: .conditions.ref_name.include, rules: [.rules[] | .type + (if .parameters then ("(" + (.parameters | tostring) + ")") else "" end)]}' >> "$work/rs.jsonl"
  done
  jq -s '.' "$work/rs.jsonl" > "$work/rs.json"
  jq -c --slurpfile rs "$work/rs.json" \
    --arg classic "$(status "repos/$r/branches/$def/protection")" \
    --arg vuln "$(status "repos/$r/vulnerability-alerts")" \
    --arg pvr "$(api "repos/$r/private-vulnerability-reporting" --jq .enabled)" \
    --arg asf "$(api "repos/$r/automated-security-fixes" --jq '"\(.enabled)/paused=\(.paused)"')" \
    --arg cs "$(api "repos/$r/code-scanning/default-setup" --jq '.state // "n/a"')" \
    --arg act "$(api "repos/$r/actions/permissions" --jq '"\(.enabled)/\(.allowed_actions // "all")/sha_pin=\(.sha_pinning_required // false)"')" \
    --arg wf "$(api "repos/$r/actions/permissions/workflow" --jq '"\(.default_workflow_permissions)/approve_prs=\(.can_approve_pull_request_reviews)"')" \
    --arg imm "$(api "repos/$r/immutable-releases" --jq .enabled)" \
    --arg fork "$(api "repos/$r/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy)" '
    {repo: .full_name, visibility: .visibility, default_branch: .default_branch,
     merge: {merge: .allow_merge_commit, squash: .allow_squash_merge, rebase: .allow_rebase_merge,
             delete_branch_on_merge: .delete_branch_on_merge, auto_merge: .allow_auto_merge, update_branch: .allow_update_branch,
             squash_title: .squash_merge_commit_title, squash_message: .squash_merge_commit_message, web_signoff: .web_commit_signoff_required},
     features: {issues: .has_issues, wiki: .has_wiki, projects: .has_projects, discussions: .has_discussions},
     security: {secret_scanning: (.security_and_analysis.secret_scanning.status // "n/a"),
                push_protection: (.security_and_analysis.secret_scanning_push_protection.status // "n/a"),
                non_provider_patterns: (.security_and_analysis.secret_scanning_non_provider_patterns.status // "n/a"),
                dependabot_security_updates: (.security_and_analysis.dependabot_security_updates.status // "n/a"),
                vulnerability_alerts_http: $vuln, private_vuln_reporting: $pvr, automated_security_fixes: $asf,
                code_scanning_default: $cs, immutable_releases: $imm},
     actions: {permissions: $act, workflow_token: $wf, fork_pr_approval: $fork},
     classic_protection_http: $classic, rulesets: $rs[0]}' "$work/base.json" >> "$work/all.jsonl"
done
jq -s '.' "$work/all.jsonl" > "$out"; rm -rf "$work"
```

Files checked with `gh api -i repos/<r>/contents/<path>` (200 = present):
`.github/dependabot.yml`, `SECURITY.md`, `.github/SECURITY.md`, `CODEOWNERS`,
`.github/CODEOWNERS`, `LICENSE`, `.github/workflows`, `.pre-commit-config.yaml`.

## Appendix B — GitHub API reference used

Rulesets: `GET/POST repos/{r}/rulesets`, `GET/PUT/DELETE repos/{r}/rulesets/{id}`,
`GET repos/{r}/rules/branches/{branch}` (effective rules). Rule types used:
`deletion`, `non_fast_forward`, `update`, `required_linear_history`,
`required_signatures`, `pull_request`, `required_status_checks`,
`commit_message_pattern`, `code_scanning`. Settings: `PATCH repos/{r}`.
Actions: `repos/{r}/actions/permissions`, `.../selected-actions`,
`.../workflow`, `.../fork-pr-contributor-approval`. Security:
`repos/{r}/vulnerability-alerts`, `.../automated-security-fixes`,
`.../private-vulnerability-reporting`, `.../code-scanning/default-setup`,
`.../immutable-releases`. All with header `X-GitHub-Api-Version: 2022-11-28`.
