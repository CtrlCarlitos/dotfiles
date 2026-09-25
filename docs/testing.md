# Testing the dotfiles, per platform

The playbook a coding agent (or a human) follows to verify — and, where safe,
fix — that this repo installs and applies cleanly on a given platform. Four
older per-platform guides (2026-09-11) said the same things four times; this
page is the shared core plus one delta section per platform.

Platforms: **Linux** (native, apt) · **macOS** (Homebrew) · **WSL** (the apt
path plus Windows interop) · **Windows** (Chocolatey + winget). The package
steps are rendered from the catalog in `.chezmoidata/packages.yaml` by
`run_onchange_install_packages.{sh,ps1}.tmpl` — the installer gates every
group on the matching `[data.packages]` toggle, so "what ran?" is answered by
`chezmoi data`, not by reading a literal install line here.

## Ground rules (every platform)

1. **Confirm scope with the user before running a full install.** A full run
   installs dozens of packages, adds third-party repos/casks, and modifies
   `~/.ssh`, `~/.gitconfig`, and your shell profile. Offer core-only vs full;
   never silently assume "full."
2. **Never blind-pipe a remote script into a shell.** Read `install.sh` /
   `install.ps1` and what they call before running them, at least the first
   time. Say so in your report if a step you don't control is itself
   `curl | bash`.
3. **Treat any pasted token as already compromised.** Prefer `gh auth login`.
   A token embedded in a git remote URL is a real finding — replace it with a
   credential helper or SSH.
4. **Never run the installer with `sudo` in front of it, and don't test as
   root.** The scripts elevate internally, per step. Testing as root produces
   different, misleading failures (Claude Code's installer refuses sudo
   outright; historically, an empty-`$SUDO` bug only fired under root).
5. **Never trust an exit code alone as proof something worked.** Verify real
   state: `command -v <tool>`, the package manager's own list, `chezmoi
   status`, `chezmoi doctor`, and `dot doctor` (the repo's own health check —
   it catches the config-encoding/pin drift classes `chezmoi doctor`
   can't see).
6. **This machine is real, not a sandbox.** Confirm before destructive or
   hard-to-reverse steps (overwriting `~/.ssh`, `chsh`, force-pushes,
   `rm -rf` on config dirs).
7. **Check for drift you introduce.** Auth setup, credential helpers, and
   manual `git config` edits can modify files chezmoi owns. Re-run
   `chezmoi status` after any side step and resolve drift before concluding.
8. **Before pushing: stop and confirm with the user.** Show the diff and
   findings first.

## Procedure (every platform)

1. **Get repo access** (`gh auth status`, or ask; never reuse a chat-pasted
   PAT).
2. **Read `install.*` and `run_onchange_install_packages.*.tmpl`** for the
   platform in full before running anything.
3. **Confirm install scope** with the user.
4. **Run the install**, capturing full output to a log
   (`sh install.sh 2>&1 | tee ~/dotfiles-install.log`).
5. **Verify real end state**: `chezmoi status` empty; `chezmoi doctor` and
   `dot doctor` reviewed; every configured package actually present; a fresh
   shell loads with zero errors (the shell-load check has caught real profile
   bugs that a "successful" install hid).
6. **For every failure**: reproduce it standalone → root-cause → categorize
   (repo bug: fix here; upstream/transient: report, don't touch) → smallest
   correct fix → re-run to prove the symptom is gone.
7. **Before committing**: stage only intended files; commit message explains
   why, not just what.

## Linux (native, apt-based)

Scope: Ubuntu/Debian/Mint only — the prerequisite bootstrap recognizes
`ubuntu|debian|linuxmint` via `/etc/os-release` and exits on anything else
(intentional; discuss scope before "fixing" it).

Watch-items:

- **Third-party apt repos** (Docker, VS Code, Charm's gum, eza) — failures
  there are usually GPG key/repo-signing rot, not the package missing.
- **`git-delta`** comes from a GitHub-release `.deb`, not apt — if it 404s,
   check the upstream repo path before retrying blindly.
- **Docker Desktop's install block** derives a repo URL from
  `ID`/`ID_LIKE`/codename (Mint gets Ubuntu's codename). Split repo/key setup,
  `apt update`, and the final `.deb` install when diagnosing.
- **Batched installs with `|| true`** absorb per-package failures — check each
  package's real state individually instead of trusting the batch's exit code.
- **`install_linux_desktop()` needs `$DISPLAY`** and the desktop group is
  host-only (`$isHost`): headless boxes skip it by design.
- **`fd`:** Debian/Ubuntu's package is `fd-find` with a `fdfind` binary; the
  installer symlinks `~/.local/bin/fd` (same pattern as `batcat` → `bat`). If
  `fd` is missing after a run, check that symlink first.

## macOS (Homebrew)

- **Fresh Macs need Xcode CLT first** (`xcode-select --install`): the
  installer's prerequisite helper is apt-only and exits without a fallback on
  macOS. Whether to add a brew-based bootstrap is a decision to raise, not to
  make unilaterally.
- **Homebrew refuses root** at any step — running the script under sudo fails
  hard and correctly at the first `brew` call.
- **Batched `brew install … || true`** hides per-package failures the same way
  apt's batching does; verify with `brew list --formula|--cask`.
- **Apple Silicon vs Intel** paths (`/opt/homebrew` vs `/usr/local`) are
  handled via `brew shellenv` — verify on the arch you're actually testing.
- `gum` and `git-delta` are real formulae — don't "fix" them by analogy with
  Windows findings.

## WSL

WSL runs the same apt code path as native Linux (see that section), plus:

- **Two filesystems, two `~/.ssh`.** Windows-side keys are not available
  inside WSL; check what auth the WSL shell actually has before assuming repo
  access carries over. (The relay story — WSL borrowing the Windows agent —
  is [SSH Agents](ssh-agents.md); it is forwarding, not copying.)
- **Environment detection is computed live, not stored.** `isWsl`/`isHost`
  render fresh on every apply from `.chezmoi.kernel.osrelease` containing
  `microsoft`. Verify with
  `chezmoi execute-template '{{ .chezmoi.kernel.osrelease }}'` — a
  misdetection quietly changes everything downstream.
- **Desktop apps are double-gated** (host-only at the call site, `$DISPLAY`
  as a secondary net). WSLg sets `$DISPLAY` automatically, so "it didn't
  install" proves nothing unless you tested with `dev_desktop = true` and a
  WSLg session.
- **Interop and line endings.** `dot_gitconfig.tmpl` picks `core.editor`
  based on `code` findability; `.gitattributes` pins `*.sh` to LF and
  `*.ps1` to CRLF — on CRLF drift, `git add --renormalize .` first, then
  root-cause.
- **`act` caveat:** this repo's container detection treats any Docker
  container as a devcontainer, so under `act` nothing package-related ever
  runs interactively; use isolated `docker run` tests with a non-root sudo
  user for package behavior.
- **`chezmoi doctor`'s `hardlink` error is a false alarm** when `/tmp` is a
  separate tmpfs (cross-device link — by design). Don't "fix" it.
- **Two fixed-and-documented WSL bugs** worth knowing: Playwright's
  `install-deps` is timeout-wrapped (it hung under sudo), and Ollama's
  installer needs `zstd` from the `core` group. The evidence lives at the
  call sites in the installer template.

## Windows (Chocolatey + winget)

The exit-code lesson is the biggest one in this playbook:

- A suppressed-output batch (`| Out-Null`, `2>$null`, `|| true`) without a
  `$LASTEXITCODE` check hides failures indefinitely — the original choco loop
  silently skipped `delta`, `gum`, and a Chrome checksum failure for the
  script's entire life. Every `choco install` now runs through
  `Invoke-WithTimeout` (600 s cap, live output). If a tool is mysteriously
  missing, verify real state directly instead of trusting the log.
- **Admin elevation cannot be automated from a script** — `Start-Process
  -Verb RunAs` pops a UAC dialog no agent can click. Ask the user to elevate.
- **Test both PowerShell profiles independently** (5.1 under
  `Documents/WindowsPowerShell/`, 7+ under `Documents/PowerShell/`) — a fix
  in one says nothing about the other, and the two tools disagree on shell
  names (`direnv hook pwsh` vs `starship init powershell`; check each tool's
  accepted values).
- **`-ExecutionPolicy Bypass` in your test harness hides real bugs** — the
  repo sets `RemoteSigned` via the registry
  (`run_once_windows_set-executionpolicy.ps1.tmpl`); verify the registry
  value, not a cmdlet's success report.
- **PowerShell 5.1 quirks:** `2>&1` on native commands wraps stderr in
  `NativeCommandError` (false alarms); embedded double quotes in `git commit
  -m` get mangled (use `git commit -F`); PATH changes don't propagate between
  invocations (refresh `Machine`+`User` explicitly); avoid pager-routed
  `chezmoi apply -v` in automation (`delta` waits on stdin forever).
- **Chocolatey-specific history** (wrong package IDs, a removed
  `--local-only` flag, vendor renames) is Chocolatey-specific — port the
  method to other platforms, not the fixes.

## What CI already covers

Before scheduling a long manual pass, check what's already enforced:
`bash tests/run.sh` locally, the `ci.yml` workflow on every PR, and the
manual `full-install-test.yml` for full-install runs. `dot doctor` (also run
by `run_after_dotfiles-doctor.*` on every apply) is the canonical
post-install check.
