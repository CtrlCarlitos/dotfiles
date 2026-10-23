# Lab VM validation

The single maintained prompt for an agent validating these dotfiles inside a
disposable Hyper-V lab VM. You reach it after the one-line installer, `dot up`
or `dot upgrade` has run (or is about to be rerun). The agent works out which
machine it is on from the guest's real hostname and continues that machine's
history in its own GitHub issue. A checkpoint restore wipes the session, the
checkout and the logs, so the issue is the memory that survives it.

This workflow runs only when the operator invokes it explicitly. Reading
`AGENTS.md` or this file as part of other work does not start it.

## Invocation

Type it by hand. The Windows Home guest has no reliable paste.

> Follow docs/vm.md.

Run this after the one-line installer, `dot up` or `dot upgrade`, or to
continue a machine's existing branch. The agent follows
[the prompt](#the-prompt) below for the current machine only.

Two other short phrases come from issue #433, which introduced this file:

| Phrase | Purpose |
| --- | --- |
| `Follow docs/vm.md.` | Normal VM validation (this file). It never repeats the one-time rollout. |
| `Resume VM via #433.` | The same prompt, read from #433's **Canonical VM validation prompt**, for a checkout that does not have this file yet. No implementation or rebases. |
| `Implement #433.` | The one-time implementation and rollout recorded in #433. This file is not involved. |

Each VM's history lives in its own hostname-specific issue, titled
`VM install test log: <HOSTNAME> (Hyper-V)` (#430 and #431 are examples). There
is deliberately no list of machines here: the agent discovers the issue from
the hostname, for current and future VMs alike.

## What each entry point actually runs

Check these facts against the revision on the VM. The prompt asks for that
check, and this table only records what `main` did when it was written.

| Entry point | What selects the code that runs |
| --- | --- |
| One-line installer | Two separate inputs: the bootstrap script, chosen by the URL it is downloaded from, and the chezmoi source it clones. `main`'s `install.sh` / `install.ps1` have no branch selector. A `DOTFILES_BRANCH` override was proposed in #432 (with variants on other VM branches). Where an installer has it, it selects the source *branch*, it does not pin a commit, and it has no effect on a script that was downloaded from `main`. Run `rg -n DOTFILES_BRANCH install.sh install.ps1` in the tested revision. Local-checkout mode can bypass the selector. An existing clone that fails to switch or update may warn and carry on with the old source. |
| `dot up` | The dispatcher (`dot_aliases.zsh`, the PowerShell profiles) runs `chezmoi update --apply=false`, then `chezmoi init`, then one `chezmoi apply`. The pull follows the source checkout's current branch and upstream. `DOTFILES_BRANCH` is not read. Record the source `HEAD` before and after. |
| `dot upgrade` | Runs the upgrade scripts already in the source checkout. It neither pulls nor applies dotfiles, and it does not read `DOTFILES_BRANCH`. |

The `dot` function loaded in the current shell may predate the applied
profile. Open a new shell (or check which dispatcher is loaded) before
concluding which code ran. Run `dot up` and `dot upgrade` with every agent
session closed ([Quickstart](quickstart.md#3-the-commands-you-will-actually-use)).
When the next step needs that, the agent saves its handoff and hands you the
command. It does not get around the live-session gates.

Logs ([Install logs](logging.md)) cover different phases. `install-<time>.log`
belongs to the one-liner, and on Unix it starts only after the package menu.
`dot-up-<time>.log` belongs to the package installer. No log covers a whole
`dot upgrade` session, so do not assume one file holds every phase.

## Authority this workflow grants

Invoking it authorizes read-only investigation, focused repository fixes,
relevant local verification, commits and pushes to the VM's task branch,
creating or updating its PR, and updates to the VM's tracking issue. That
satisfies the confirmation the [testing guide](testing.md#ground-rules-every-platform)
asks for before those steps. It does not cover:

- merging, force-pushing or deleting branches;
- restoring or resetting the VM;
- widening the package selection;
- other destructive or hard-to-reverse steps;
- changing an established requirement.

Each of those still needs its own decision.

## The prompt

You are running inside a Hyper-V lab VM used to validate this repository's
dotfiles. I have just run, or resumed testing after, the one-line installer,
`dot up`, or `dot upgrade`. Investigate the actual run, implement justified
fixes, publish the work for review, and guide the next validation step.

The VM can be restored to a clean checkpoint. Assume your session and
everything created after that checkpoint can disappear. The hostname-specific
GitHub issue is our durable memory; pushed branches and PRs preserve the code.

### 1. Identify this VM and recover its own history

Start read-only.

- Detect the actual guest hostname and report it, along with OS/version, user,
  shell/runtime, repository remote, source/worktree paths, branch, full commit
  SHA, and working-tree state. Use the OS-appropriate hostname command; do not
  infer the machine from a previous conversation or issue example.
- Read `AGENTS.md`, `docs/invariants.md`, `docs/testing.md`, and relevant
  command headers/contracts.
- Verify access to the intended GitHub repository/account. SSH Git access does
  not by itself prove issue/API access.
- Search both open and closed issues in this repository for this exact
  hostname. Prefer the established title
  `VM install test log: <HOSTNAME> (Hyper-V)`, and verify the issue's declared
  machine. Compare hostnames case-insensitively while preserving the observed
  spelling; use aliases or FQDN variants only when verified.
- A mention in another VM's issue, a shared documentation issue, or a related
  PR is not proof that it owns this machine's history. Read candidate bodies
  and relevant comments before selecting.
- Reuse the matching issue, read its current status, latest handoff, earlier
  unresolved findings, and linked PRs. Preserve history. Do not create one
  issue per run.
- Create a machine issue only after a successful search establishes that none
  exists. If context says one already exists but search finds none, also
  inspect recent issue listings and verify access before creating a duplicate.
  Authentication/search failure is a blocker, not an empty result. If multiple
  genuine machine issues remain ambiguous, show the candidates and ask rather
  than guessing or creating a duplicate.

### 2. Establish which operation ran and preserve evidence

Determine whether this was a one-line install, `dot up`, `dot upgrade`, or an
explicitly recorded diagnostic rerun. Identify its command, arguments, relevant
environment variables, start/end times, and result where recoverable. Mark
unknown details as unknown.

Correlate logs to this operation before rerunning anything. Preserve relevant
installer, chezmoi, package-manager, upgrade, and system evidence before
cleaning or modifying state. Record inspected sources, missing logs,
interrupted processes, pending reboots, and steps not reached.

Compare the requested configuration with actual installed/configured state.
Keep the existing package selections as the scope; do not silently enable
every group or reset the configuration.

For each finding, report impact, evidence, likely cause, confidence,
recommended fix, and how to verify it. Check real behavior and tool
availability, not just a successful exit message. Redact credentials and
sensitive configuration from anything published.

### 3. Verify the code that actually executes

Inspect the implementation in the revision available on this VM.

- For a fresh installer test, verify both the bootstrap script's source and
  the resulting chezmoi source. Use `DOTFILES_BRANCH` only where that
  installer supports it, and select the bootstrap URL deliberately. Do not
  assume setting the variable changes a script downloaded from `main`.
- For `dot up`, establish the actual chezmoi source branch/upstream and record
  the commit before and after its pull.
- For `dot upgrade`, establish the source scripts and loaded dispatcher it will
  use. Do not assume it fetches repository changes or honors the installer
  variable.
- Resolve the actual source directory. Editing a separate worktree does not
  automatically make chezmoi or an installed `dot` function use it.
- Record requested and observed revisions separately. A branch name, a pinned
  bootstrap URL, or a successful command alone does not prove the intended
  source commit ran. A mismatch blocks a claim that the candidate was
  validated.
- Verify affected shell/profile behavior in a fresh shell when necessary.

### 4. Fix, verify, and publish within the authorized scope

When I invoke this workflow, I authorize read-only investigation, focused
repository fixes, relevant local verification, commits to a task branch,
pushes to that branch, creation/update of a PR, and updates to this VM's
tracking issue. Complete those actions without repeatedly asking whether to
commit, push, or open the PR.

Follow the repository workflow, preserve unrelated work, reuse a dedicated
branch/worktree when appropriate, and leave the PR open for my review. Before
implementing a shared defect, check relevant open PRs and other VM reports so
an existing fix can be reused or cross-linked; do not overwrite another
agent's work. Do not merge or restore the VM automatically.

Fix root causes in the repository and document any temporary machine-only
workaround. Add meaningful regression coverage for behavior changes where
appropriate; run relevant existing checks and report pass, fail, and skip
counts honestly.

If failures also reproduce on unmodified baseline code under comparable
conditions, report that observation with the revisions and failure identities.
It does not by itself prove the failures are environment-only, that CI will
pass, or that the entire suite passes.

A change to an established requirement is a separate decision from routine
publishing. Explain the conflict and preserve the requirement unless a newer
user instruction supersedes it. Continue unaffected fixes while resolving that
decision. For example, removing a confirmation required by #336 must not be
silently bundled into a crash repair.

Distinguish validation on this already-modified VM from clean-checkpoint
validation. Continue useful diagnosis on the current VM when it will reveal
further failures; do not request a reset merely because a PR exists.

Respect live-session rules. If the next install/apply/upgrade may update the
running harness, or requires closing sessions or rebooting, save the handoff
first and give me the exact command to run outside the session. Do not bypass
session protections to keep yourself running.

### 5. Maintain a durable run record

Keep a concise current status in the machine issue body and append numbered
run records without deleting prior evidence (format:
[Run record](#run-record)). Resume the same run when only the agent session
restarted; create a new run/attempt record when another relevant command
executes.

Each record must contain:

- Hostname, OS/runtime, date/time with timezone, and baseline/checkpoint
  identity when known.
- Operation, exact command/arguments, configuration scope, and sanitized
  relevant environment.
- Requested branch/ref, observed source commits before/after where available,
  bootstrap revision when applicable, and dirty/local modifications that
  affected the run.
- Log locations inspected and durable links or excerpts supporting the
  findings.
- Fixes, pushed branch/commit, PR link, checks performed, counts/results, and
  pending validation.
- Current VM state, pending reboot or manual prerequisite, next action, exact
  commands, and expected success criteria.

Record checkpoint contents once when known. If SSH/config inclusion is
unknown, say so and provide a conditional check/preparation step for the next
run. Do not repeatedly block unrelated work on that question. Record GitHub
authentication and other prerequisites needed after restoration without
storing secrets.

### 6. Finish the handoff before a reset or session-ending command

Before declaring readiness:

1. Verify the required commits are pushed and available remotely.
2. Create/update the PR and the hostname-specific issue; read back the saved
   handoff and confirm its links and revisions.
3. Preserve enough redacted evidence outside the VM to continue diagnosis.
   Excerpts are sufficient only when they retain what is needed. Preserve
   larger sanitized logs when an unresolved failure needs them; a path inside
   the VM is not a durable copy.
4. Account for valuable local-only work. Never recommend a reset while
   necessary changes or evidence exist only here.
5. Specify the actual next command, intended source revision, preparation, and
   measurable checks. For branch installs, cover bootstrap and source
   selection. For updates/upgrades, explain how the intended checkout and
   runtime will be used.
6. Confirm that any required recovery material can be supplied after rollback;
   do not publish private keys or secret configuration.

Use the status appropriate to the next action:

- **CONTINUE ON CURRENT VM** — further diagnosis or targeted validation is
  useful.
- **READY FOR COMMAND RERUN** — I need to close the agent, run the specified
  command or reboot, then start a new session.
- **READY FOR CHECKPOINT RESTORE** — I should restore the named VM/checkpoint
  and follow the recorded clean-run procedure.

Name the hostname, tracking issue, PR, tested revision, and next steps. I
perform Hyper-V restoration from the host. If a required write or durable save
failed, explain the blocker and do not declare the VM ready for restoration.

### Start now

Report the detected hostname, resolved tracking issue, operation being
investigated, and current branch/commit. Then proceed with evidence review and
the authorized work. Ask only for a genuine blocker or material decision that
cannot be resolved from the environment, repository, and issue history.

## Run record

The machine issue body holds the current status, and each run is a numbered
comment appended below it. Leave out what does not apply, and write `unknown`
rather than guessing.

```markdown
**Status:** CONTINUE ON CURRENT VM | READY FOR COMMAND RERUN | READY FOR CHECKPOINT RESTORE
**Branch / PR:** <branch> / #<pr> · **Tested revision:** <full sha>
**Next:** <exact command> - expect <success criteria>

---

## Run <n> (attempt <m>) - <YYYY-MM-DD HH:MM TZ>

- **Machine:** <HOSTNAME> · <OS/version> · <shell/runtime> · checkpoint: <name or unknown>
- **Operation:** one-line install | dot up | dot upgrade | diagnostic rerun
- **Command:** `<exact command and arguments>` · scope: <package selection>
- **Environment:** <sanitized relevant variables, e.g. DOTFILES_BRANCH>
- **Revisions:** requested <ref> · bootstrap <url/sha> · source before <sha> / after <sha> · local changes: <none | list>
- **Logs inspected:** <paths> - durable copies: <links / excerpts>
- **Findings:** <impact · evidence · cause · confidence · fix · verification>, one per finding
- **Fixes:** <branch>@<sha>, PR #<n>; checks: <command> -> <pass>/<fail>/<skip>
- **Pending validation:** <what remains, and on clean checkpoint or this VM>
- **VM state:** <dirty/clean, pending reboot, manual prerequisites, auth needed after restore>
- **Next:** <status> - `<exact command>` - expect <criteria>
```
