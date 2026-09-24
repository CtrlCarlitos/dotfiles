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
     installed, it runs `guardrail update <pin>` instead; that is a no-op when
     the binary already reports the pin.
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

The dotfiles don't pass `--no-setup`. On a machine where no operator has
enrolled yet, the installer places and verifies the binary, then
`guardrail setup` fails its approval, so the apply fails. Enroll once, then
finish the setup:

```sh
guardrail operator enroll     # prints a localhost URL; open it and complete the passkey prompt
guardrail setup               # registers every detected host with one approval, then runs selftest
```

Restart the agents you wired. **For Codex, run `/hooks` inside Codex to review
and trust the generated hooks**; the runtime doesn't execute registered hooks
until you do. The next `chezmoi apply` runs the installer again. It finds the
pin already installed and the hosts already registered, so it doesn't ask for
approval.

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

## Verifying after apply (Unix)

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

## Caveats

- **CI seeds keep `guardrail = false`.** `guardrail setup` refuses to run
  without an interactive terminal (exit 2) and needs a passkey approval, and
  CI can't provide either. Full-install workflows therefore exercise guardrail
  on real machines only.
- **The contract test is scoped.** `tests/guardrail_lifecycle_contract.sh`
  checks the fetch-verify-run shape and forbids install logic (binary
  downloads, plane or update calls, PATH, Defender, `Unblock-File`) between each
  consumer's `# guardrail-section: begin` and `# guardrail-section: end` lines.
  Code outside those markers is not checked.
