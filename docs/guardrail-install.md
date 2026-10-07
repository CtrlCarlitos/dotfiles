# guardrail install strategy

_Added 2026-09-04 with Plan 3b of the agent-guardrails project; reworked
2026-09-17 for the v0.19.x plane-lifecycle contract; reworked 2026-09-23 when
installation moved into agent-guardrails
([ADR-0029](https://github.com/CtrlCarlitos/agent-guardrails/blob/main/docs/adr/0029-installer-lives-in-this-repo.md));
refreshed 2026-10-05 for the in-place update path (no pre-rename, rollback copy),
exit-code 3 handling and the allow-baseline recipe._

## TL;DR

- Installing guardrail is agent-guardrails' job. Every release ships
  `install.sh` (Linux, macOS, WSL) and `install.ps1` (Windows) next to the
  binaries, listed in the same `SHA256SUMS`. The dotfiles are a caller.
- The dotfiles own exactly two facts:
  - **The pin** — `guardrail.version` in `.chezmoidata.yaml`, the single
    source of truth. Always an exact tag, never "latest".
  - **The desired state** — `packages.guardrail` in your chezmoi config
    (prompted, default true; non-interactive default false).
- Each consumer does one fetch-verify-run, in both twins:
  1. Download the pinned tag's installer and `SHA256SUMS` from
     `https://github.com/CtrlCarlitos/agent-guardrails/releases/download/<pin>/`
     (Windows sets TLS 1.2 first).
  2. Check the installer's SHA-256 against its `SHA256SUMS` line. A mismatch,
     a failed download or (Unix) no SHA-256 tool warns and skips — an
     unverified installer is never run.
  3. Run the downloaded file, never piped into a shell:
     - Unix: `sh install.sh --version <pin> --state enabled|disabled`
     - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Version <pin> -State enabled|disabled`
- The installer's output streams through untouched: `guardrail setup` prints a
  WebAuthn approval URL and waits for your passkey.

| Consumer | Installer exits 3 (operator action pending) | Installer exits any other non-zero |
|---|---|---|
| `run_onchange_install_packages.sh.tmpl` | warning with the remedy; the apply carries on | the script fails, so `chezmoi apply` fails and the next apply runs it again |
| `run_onchange_install_packages.ps1.tmpl` | warning with the remedy; the apply carries on | the script throws, with the same effect |
| `scripts/update_ai_tools.sh` / `.ps1` | a warning | a warning; the updater carries on with the remaining tools |

Exit 3 means only "operator action pending" (not enrolled, no interactive terminal,
approval daemon not running, request denied or expired): the binary is installed and
current and what is registered keeps enforcing. Control flow uses exit codes, never the
installer's wording. The installer templates tee its output into
`~/.local/state/guardrail/apply.log` (Windows:
`%USERPROFILE%\.local\state\guardrail\apply.log`). After every other section has run they
call `guardrail next`; pending steps are printed verbatim, followed by
`ACTION NEEDED: run 'guardrail setup' in an interactive terminal ...`, so the remedy is the
last thing the run prints.

**What the console shows.** The installer ends every run with a ~45-line doctor dump (policy, recipes,
audit log, four planes registered, probe summaries, MCP coverage...), identical on a healthy machine. The
installers and both `update_ai_tools.*` scripts keep the **full** output in `apply.log` (the updaters did not
log it before) and print a filtered copy: only lines of a known routine shape are dropped, and the run says
how many (`(38 routine guardrail status line(s) hidden; ...)`). Warnings, problems, the verdict, the hook
latency, `selftest:` and any line the filter has never seen stay, in particular an approval prompt or URL,
which the installer blocks on. `DOT_GUARDRAIL_VERBOSE=1 dot up` (or `dot upgrade`) prints everything.
The shell filter is `guardrail_console_filter` in `scripts/lib/agent-skills.sh`, the PowerShell one
`Select-GuardrailConsoleLine` in `scripts/lib/ps-skills.ps1`; `tests/guardrail_console_filter_contract.sh`
runs both on real output and requires them to keep the same lines.

## The flag

| `packages.guardrail` | What the dotfiles do |
|---|---|
| `true` | Run the installer with `--state enabled` (`-State enabled`). |
| `false`, binary present | Run the installer with `--state disabled` (`-State disabled`). |
| `false`, no binary | Print `guardrail disabled in config - nothing to do`. Nothing is downloaded. |

The binary is `~/.local/bin/guardrail` on Unix and
`%USERPROFILE%\.local\bin\guardrail.exe` on Windows. Disabling never removes it;
the dotfiles have no uninstall path.

The manual updaters (`scripts/update_ai_tools.sh` and `.ps1`) read the same flag
from `~/.config/chezmoi/chezmoi.toml` `[data.packages] guardrail` (missing
means false) and the pin through `chezmoi execute-template`.

## What the installer does

This list is a summary. The agent-guardrails
[README](https://github.com/CtrlCarlitos/agent-guardrails#install) and
[OPERATIONS.md](https://github.com/CtrlCarlitos/agent-guardrails/blob/main/docs/OPERATIONS.md#install-update-disable-uninstall)
are the reference.

- **`--state enabled`:**
  1. Downloads the binary for your OS and architecture with `SHA256SUMS` and
     verifies it. If a guardrail at or above `v0.19.2-dev` is already
     installed, it runs `guardrail update <pin>` instead (see
     [Updating in place](#updating-in-place)). That command changes nothing when
     the installed binary already reports the pin.
  2. Places the binary and checks that `guardrail version` reports the pin.
  3. On Windows: runs `Unblock-File` and adds the user PATH entry for a fresh
     binary. Every run makes sure a Defender exclusion exists for that exact
     `guardrail.exe`; without an elevated shell it prints the `Add-MpPreference`
     command for you to run (see [The Defender exclusion](#the-defender-exclusion)).
  4. Runs `guardrail setup`. This registers every agent host it detects with one
     passkey approval, runs `doctor --coverage antigravity` when `agy` is on
     PATH, then `selftest`, and exits with setup's code. Hosts already registered with this binary's handlers print
     `already enabled` and don't ask for approval.
- **`--state disabled`:** downloads nothing. It runs
  `guardrail setup --state disabled`, which unregisters every host with one
  approval and keeps the binary.

On Unix, `~/.local/bin` must be on your PATH; the dotfiles' `.zshrc`
already adds it.

## First install on a machine with no enrolled operator

Since `v0.23.2-dev` (agent-guardrails #326, ADR-0030) a first install arms
the machine on its own. With no operator authenticator enrolled there is
nothing to approve against, so `guardrail setup` registers the hooks and the
permissions floor without an approval and without a terminal, runs the
coverage gate and `selftest`, writes one `operator-action` audit record with
`transport: bootstrap`, and ends with the one-time instruction to enroll.
`chezmoi apply` therefore completes unattended on a fresh machine; `doctor`
reports `planes armed by bootstrap` until you enroll:

```sh
guardrail operator enroll     # prints a localhost URL; open it and complete the passkey prompt
```

The approval-less path can only tighten. `setup --state disabled`, `plane
disable`, `recover`, grants and waivers still need a passkey: without one they
stop before submitting, print `run 'guardrail operator enroll' ...`, and exit
**3** (distinct from 1, denied or failed, and 2, usage or no terminal). The
installers pass that code through and the dotfiles treat it as a warning, not a
failure (see the table above): with `packages.guardrail = false` on a machine with
no enrolled operator the apply finishes, the planes stay registered, and the
end-of-apply `guardrail next` block says to enroll and finish. Nothing is
unregistered without a passkey, which is the intended fail-closed direction.

Restart the agents you wired. **For Codex, run `/hooks` inside Codex to review
and trust the generated hooks**; the runtime doesn't execute registered hooks
until you do.

### Pins older than v0.23.2-dev

`v0.23.1-dev` had no bootstrap. On a machine with no enrolled operator its
`guardrail setup` failed its approval with a misleading `approval daemon
unavailable`, so the apply failed on every run until `guardrail operator
enroll` then `guardrail setup` were run once from a real terminal (an agent's
shell gets exit 2). Bump the pin instead of working around that.

## Bumping the version

1. Tag a new `agent-guardrails` release (CI publishes the binaries, the
   installers and `SHA256SUMS`). `v0.23.1-dev` is the first release that ships
   the installer; pins older than that have no `install.sh` to download.
2. Update one line: `guardrail.version` in `.chezmoidata.yaml`. The installer
   templates render the key at apply time and the manual updaters read it at
   runtime via `chezmoi execute-template`. `tests/update_guardrail_versions.sh`
   checks that no consumer hardcodes a tag.
3. Commit and merge, then on each machine run `dot up` (an elevated shell on
   Windows). It pulls, re-inits and applies once; the pin renders into the
   `run_onchange` installer, so the changed pin re-fires it in that same run,
   and it runs the new tag's installer. The installer updates the binary and
   runs `guardrail setup` to reconcile the registered handlers. `dot upgrade`
   reaches the same installer through `scripts/update_ai_tools.*`, but only
   ever to the pinned tag: a no-op when the machine is already there.
   Nothing in the dotfiles moves a machine to a tag other than the pin.

Windows and WSL are separate installs: the
Windows `dot up` installs `%USERPROFILE%\.local\bin\guardrail.exe`, and the `dot up`
you run inside each WSL distro installs that distro's own `~/.local/bin/guardrail`.
Neither touches the other, so after a bump run `dot up` in both and check
`guardrail version` in each.

## Updating in place

The Windows installer used to rename `guardrail.exe` aside before every run, which made
the upstream installer take its fresh-download path: the same release downloaded again
each time, no rollback copy, and guardrail's evidence window reset. It no longer does
that (`tests/guardrail_installer_no_rename_contract.sh`). An installed binary is left
where it is and the pinned installer runs `guardrail update <pin>`, the sanctioned
replacement path:

- at the pinned tag it changes nothing (`guardrail already at <tag>; nothing to do`);
- otherwise it downloads, verifies the checksum, and swaps the binary. A running
  `guardrail.exe` is renamed aside by the update itself (Windows can rename an
  executable in use but not overwrite it), so no one has to close agents first;
- it keeps the replaced binary beside the new one (`guardrail.previous`, or
  `guardrail.previous.exe` on Windows) with a record of its release and SHA-256 in
  guardrail's state directory, and runs `doctor` and `selftest` on the new binary;
- if either fails the binary is already replaced; the update exits 1 and names the way
  back: `guardrail rollback` (operator only; a session cannot run it).

Afterwards the doctor may print `claude settings: guardrail hook registered but NEVER
OBSERVED FIRING`. That line is transient: it means no real session has been mediated by
this binary yet, and it clears itself once one is. To check right away, from a terminal
after a real session: `guardrail selftest --evidence claude` (exit 1 until two pre-hook
records from one real session exist).

## The Defender exclusion

On Windows the exclusion for the exact `guardrail.exe` path (never a directory or a process
name) belongs to agent-guardrails' `install.ps1`: every run makes sure it exists, and
uninstalling removes it. The dotfiles carry no Defender code for guardrail (the lifecycle
contract forbids it). From a non-elevated shell the installer prints the
`Add-MpPreference -ExclusionPath "<path>"` command for you to run; `dot up` and `dot
upgrade` are elevated on Windows, so this normally happens silently. This is separate from
[`dot devtmp`](devtmp.md), where the exclusion for the build folder is yours and is only
ever printed.

## Housekeeping in `~/.local/bin`

| File | Whose | What happens to it |
|---|---|---|
| `guardrail`, `guardrail.exe` | the install | kept |
| `guardrail.previous`, `guardrail.previous.exe` | upstream's rollback copy | kept; it is what `guardrail rollback` restores |
| `guardrail.exe.old` | upstream's single set-aside slot (a running image renamed aside) | managed by upstream; delete it by hand after a reboot if it lingers |
| `guardrail.exe.old-<stamp>` | the retired pre-rename scheme of this installer | the Windows installer deletes them after each run |
| `*.before-*` and any other copy you made | you | never touched |

On WSL (and macOS/Linux) the installer sweeps nothing; the same files apply minus the
`.exe`. `dot backup` never captures the binary, the rollback record or set-aside copies
(see [backup-restore.md](backup-restore.md)).

## Hook latency

Every Claude, Codex and OpenCode tool call runs the guardrail hook, so its cost is paid per
call. v0.23.35-dev (pin bump #258) stopped spawning `git rev-parse --show-toplevel` twice
per call and finds the repo root in-process; on Windows, where one git spawn costs about
60 ms, that was most of a ~107 ms hook. `guardrail doctor` prints per-plane p50/p95 over the
latest 200 real calls, so you can read your own numbers. If the hook still feels slow on
Windows, the usual cause is Defender scanning the binary: check the exclusion above.

## The Claude allow list: `allow-baseline`

Guardrail never edits your `~/.claude/settings.json`. `guardrail allow-baseline` prints a
vetted list of `permissions.allow` rules with the reason for each, `--check` compares it with
your file and flags rules broader than the baseline (the doctor carries a summary line), and
`--json` prints the list as `{"permissions":{"allow":[...]}}`. It has no apply mode. The
broad `Bash(graft:*)`, `Bash(npx graft:*)` and `Bash(graft-dev:*)` also cover `graft init`,
`graft upgrade` and `graft build --deep`, so the baseline allows graft by read-only
subcommand instead (this repo's own `.claude/settings.json` does the same).

To merge the baseline and drop those three rules, back up the file first, then:

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak
guardrail allow-baseline --json > baseline.json
jq -b --slurpfile b baseline.json '.permissions.allow = ((((.permissions.allow // []) - ["Bash(graft:*)","Bash(npx graft:*)","Bash(graft-dev:*)"]) + $b[0].permissions.allow) | unique)' ~/.claude/settings.json > merged.json
# read merged.json, then replace settings.json with it
```

Your other rules are kept; the result is sorted and de-duplicated. On Windows PowerShell
put the filter in a `.jq` file (`jq -b --slurpfile b baseline.json -f merge.jq ...`) and write
the output without a BOM (PowerShell 5.1 `>` writes UTF-16); Git Bash avoids both problems.
`guardrail allow-baseline --check` should then report nothing broader.

## Verifying after apply

```bash
guardrail version        # guardrail <pin>
guardrail plane status   # each installed plane: registered
guardrail doctor         # clean, no warnings
guardrail next           # nothing printed = no operator step owed
```

Run them in each environment you installed (Windows PowerShell, and each WSL distro).

## Removing guardrail

The dotfiles never uninstall. To remove guardrail, set
`packages.guardrail = false` so the next apply doesn't reinstall it. Then run
the pinned release's installer by hand with `--uninstall` (`-Uninstall`), or
add `--purge` (`-Purge`) to delete guardrail's state too. The agent-guardrails
OPERATIONS.md lists what each one removes.

## Config the dotfiles ship

The repo root carries a `guardrail.toml` — guardrail's own config overlay:

```toml
[slots]
  web_hosts = ["starship.rs"]
```

Location semantics matter here: guardrail reads this overlay from the
**source repo** (the chezmoi source dir), not from `$HOME`. A
`guardrail.toml` copy in `$HOME` is dead weight — `guardrail doctor` run
there reports `overlay: none` — which is why the file is on
`.chezmoiignore`'s never-deploy list, pinned by
`tests/home_scope_contract.sh`. The shipped entry (`starship.rs`, a docs
site your prompt config references) is the only trusted web host; edit the
file in the repo to change it — never a `$HOME` copy, which nothing reads.

## Caveats

- **CI seeds keep `guardrail = false`.** `guardrail setup` refuses to run
  without an interactive terminal (exit 2) and needs a passkey approval, and
  CI can't provide either. Full-install workflows therefore exercise guardrail
  on real machines only.
- **The contract test checks a fixed list.** `tests/guardrail_lifecycle_contract.sh`
  requires the fetch-verify-run shape between each consumer's
  `# guardrail-section: begin` and `# guardrail-section: end` lines, and fails
  a section that holds only comments. It forbids a fixed list of install-era
  literals (binary asset names, plane and update calls, `doctor --coverage`,
  Defender, `Unblock-File`) anywhere in the four consumers. Piping into a
  shell, `iex` and PATH edits are forbidden between the markers only, because
  other tools in the same files use them. Install logic that uses none of
  those literals still passes.
