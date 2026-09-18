# guardrail install strategy

_Added 2026-09-04 with Plan 3b of the agent-guardrails project; reworked
2026-09-17 for the v0.19.x plane-lifecycle + self-update contract._

## TL;DR

- One opt-in desired-state flag: `packages.guardrail` (default prompted true,
  non-interactive default false). It is not an install/skip switch anymore:
  - `true` → ensure the binary at `GUARDRAIL_VERSION`, then run
    `guardrail plane enable --all` (Unix) / download + `gen-config --merge`
    per plane (Windows).
  - `false` → never download. On Unix, if a binary already exists from a
    previous opt-in, run `guardrail plane disable --all`. The binary is never
    auto-removed in either state (no uninstall behavior by design).
- First install bootstraps from the **pinned** `CtrlCarlitos/agent-guardrails`
  release (`guardrail.version` in `.chezmoidata.yaml` — the single source of
  truth; it moves often) — no "latest", per DESIGN.md Q16.
- **Checksum-verified** against the release `SHA256SUMS` before install; never
  installs an unverified binary.
- Every later bump on Unix goes through `guardrail update <exact-version>`:
  the binary re-verifies SHA256SUMS itself, verifies the replacement runs, and
  swaps itself atomically. A same-version call is a verified no-op. Bootstrap
  (curl+SHA256SUMS) exists for machines with no binary at all **and** for
  binaries older than the self-update floor `v0.19.2-dev` (they exit 2 with
  "unknown subcommand" on `update`, so the installer curl-bootstraps over
  them instead).
- Plane wiring is guardrail-owned since v0.19.2: `guardrail plane enable
  --all` regenerates each plane's floor idempotently (marker-based merges,
  ADR-0004) and reports planes it can't detect (`codex: unsupported`,
  `<plane>: not detected`). The dotfiles installers no longer call
  `gen-config` on Unix.
- Installs to `~/.local/bin/guardrail` (Linux/mac/WSL) /
  `%USERPROFILE%\.local\bin\guardrail.exe` (Windows, `Unblock-File`d, User PATH
  persisted).
- **Windows is the exception** (v0.19.x): `plane` commands exit 2 on Windows
  (broker approval pending a native transport) and `guardrail update` cannot
  rename a running exe — so the Windows installer/updater keep the pinned
  curl+checksum download and `gen-config --merge` for all three planes, and
  never invoke plane/update.
- Plane commands print a WebAuthn approval URL and block until the operator
  responds. Installer output streams through untouched — never silence it —
  and any non-zero exit (denied / expired / timeout / non-terminal stdin)
  fails the `run_onchange` script so chezmoi surfaces the failure instead of
  silently "succeeding".
- Idempotent steady state: `update` at the pin is a no-op and an
  already-enabled plane reports `already enabled` without prompting.
- The installer never opens a browser or enrolls an operator. It reminds an
  unenrolled operator to run `guardrail operator enroll`, then manually open
  the printed localhost URL to complete the passkey ceremony.
- The pin is explicitly reviewed (currently `v0.21.0-dev`); the version
  updater never follows GitHub's `latest` release endpoint for guardrail.

## Manual updater

`scripts/update_ai_tools.sh` reads the same desired-state flag from
`~/.config/chezmoi/chezmoi.toml` `[data.packages] guardrail` (default false —
opt-in, matching the installer) and drives the identical Unix lifecycle. The
`.ps1` twin skips every guardrail step when the flag is false and keeps the
curl+`gen-config` path when true.

## Bumping the version

1. Tag a new `agent-guardrails` release (CI publishes the binaries + SHA256SUMS).
2. Update one line: `guardrail.version` in `.chezmoidata.yaml` — the single
   source of truth. The installer templates render the key at apply time and
   the manual updaters read it at runtime via `chezmoi execute-template`
   (`tests/update_guardrail_versions.sh` enforces that no consumer hardcodes
   a tag).
3. Commit → `chezmoi update` re-fires the `run_onchange` script → Unix
   machines self-update via `guardrail update <pin>`; Windows machines
   re-download the pinned release.

## Verifying after apply (Unix)

```bash
guardrail version        # guardrail <pin>
guardrail plane status   # each installed plane: registered
guardrail doctor         # clean, no warnings
```

## Not done / open

- A dedicated `guardrail` uninstall path.
- Windows plane lifecycle once the broker approval ships a native transport.

## Caveats

- **Anonymous downloads 404** while the agent-guardrails repo is private — the
  installer warn-skips until the repo goes public (or downloads move to
  authenticated `gh` fetches).
- **CI seeds run `guardrail = false`** — `plane enable --all` needs an
  interactive WebAuthn approval CI cannot complete (exit 2 on non-terminal
  stdin fails the run by contract), so full-install workflows exercise
  guardrail on real machines only.
- **OpenCode disable is broad** (accepted breaking edge, v0.19.x):
  `plane disable --all` removes the whole `permission` and plugin keys from
  `opencode.json` — a user's own permission rules go with them. Revisit
  before public users (agent-guardrails ADR).
- **opencode.json must stay BOM-less** (Windows path) — PS 5.1's
  `Set-Content -Encoding utf8` writes a UTF-8 BOM and guardrail's Go JSON
  merge rejects it (`invalid character 'ï'`); the installer writes it via
  `WriteAllLines`/`UTF8Encoding($false)` for exactly this reason. All
  gen-config call sites print the tool's output when a merge fails, so a
  regression here shows its cause instead of warning blind.
