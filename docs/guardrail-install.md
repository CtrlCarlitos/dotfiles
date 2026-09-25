# guardrail install strategy

_Added 2026-09-04 with Plan 3b of the agent-guardrails project; reworked
2026-09-17 for the v0.19.x plane-lifecycle contract; reworked 2026-09-23 when
installation moved into agent-guardrails
([ADR-0029](https://github.com/CtrlCarlitos/agent-guardrails/blob/main/docs/adr/0029-installer-lives-in-this-repo.md))._

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

| Consumer | Installer exits non-zero |
|---|---|
| `run_onchange_install_packages.sh.tmpl` | the script fails, so `chezmoi apply` fails and the next apply runs it again |
| `run_onchange_install_packages.ps1.tmpl` | the script throws, with the same effect |
| `scripts/update_ai_tools.sh` / `.ps1` | a warning; the updater carries on with the remaining tools |

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
     installed, it runs `guardrail update <pin>` instead. It skips the update
     when the installed binary already reports the pin.
  2. Places the binary and checks that `guardrail version` reports the pin.
  3. On Windows: runs `Unblock-File` and adds the user PATH entry for a fresh
     binary. Every run makes sure a Defender exclusion exists for that exact
     `guardrail.exe`; without an elevated shell it prints the `Add-MpPreference`
     command for you to run.
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
installers pass that code through, so on this machine `packages.guardrail =
false` fails the apply until an operator is enrolled, which is the intended
fail-closed direction.

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
3. Commit, then `chezmoi update`. The changed pin re-fires the `run_onchange`
   script, which runs the new tag's installer. The installer updates the binary
   and runs `guardrail setup` to reconcile the registered handlers.

## Verifying after apply

```bash
guardrail version        # guardrail <pin>
guardrail plane status   # each installed plane: registered
guardrail doctor         # clean, no warnings
```

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
