# Testing the dotfiles on Linux (native, apt-based)

You are a coding agent tasked with verifying (and, where safe, fixing) that this
chezmoi-managed dotfiles repo installs and applies cleanly on **Linux** (Ubuntu/
Debian/Linux Mint — the only distro family `install.sh`'s prerequisite bootstrap and
the package script actually support via `apt`). This doc describes the methodology
used to do the same job on Windows in an earlier session, adapted for this platform.
Read it fully before running anything.

**Do not assume the Windows session's specific bugs apply here.** Windows used
Chocolatey; this uses `apt` (plus a handful of direct downloads and third-party
apt repos). Different package registries, different naming, different failure
modes. Port the *method*, not the *fixes*. Diagnose this platform fresh, from
first principles.

If you're testing inside **WSL** rather than a native Linux box or VM, use
`docs/testing-wsl.md` instead — it covers this same apt code path plus the
Windows-interop specific gotchas WSL adds.

## Ground rules

1. **Confirm scope with the user before running a full install.** A full run adds
   several third-party apt repositories (Docker, VS Code, ScreenRec, gum/charm.sh,
   eza), installs dozens of packages, and modifies `~/.ssh`,
   `~/.gitconfig`, and your shell profile. Ask whether to do a full install (all
   package toggles in `chezmoi.toml`) or a minimal core-only restore first, same as
   was done on Windows. Do not silently assume "full."
2. **Never blind-pipe a remote script into a shell.** `install.sh` and everything it
   calls download and execute further scripts and add GPG-signed apt repos from
   third parties (Docker, Microsoft, Charm, ScreenRec, Google). Fetch and read each
   script's content before running it, at least the first time. If a step is itself
   `curl | bash` inside a script you don't control, say so explicitly in your report
   rather than silently trusting it.
3. **Treat any pasted token as already compromised.** If the user gives you a GitHub
   PAT in chat, tell them to rotate it. Prefer `gh auth login` / an existing `gh`
   session over a pasted token. If you must clone with a token embedded in the
   remote URL, replace it with a credential helper or SSH afterward — a token
   sitting in plaintext in `.git/config` is a real finding, not a nitpick (this
   exact thing happened and was fixed in the Windows session).
4. **`sudo` needs to actually work non-interactively, or you need to know it
   doesn't.** `install_apt()` in the package script calls `sudo -v` up front and
   keeps credentials alive with a background loop, assuming an interactive TTY
   where the user can type a password once. If you're running as an agent without
   a real terminal attached, either confirm passwordless sudo is configured first,
   or flag to the user that this step needs to run interactively — don't let it
   silently hang or fail.

   **Never run `install.sh` itself with `sudo` in front of it, and don't test as
   literal root either** — a real user is a normal user with `sudo` available,
   not root. `install_apt()` elevates internally via its own `$SUDO` variable
   only for the specific steps that need it. This isn't just style: testing as
   root produces *different, misleading* failures that are artifacts of the test
   posture, not real bugs. Confirmed live this session, testing via an isolated
   Docker container (a reasonable fallback when a real machine/VM isn't
   available — see the isolated `docker run` pattern already used elsewhere in
   this repo's testing docs) run as the container's default root: Claude Code's
   installer explicitly detects and refuses to run under sudo/root
   (`Error: do not run this installer with sudo`), and a since-fixed bug in
   `install_node()` (`$SUDO -E bash -` expanding to a bogus bare `-E` command
   when `$SUDO` is empty) only ever triggered because the test was already root.
   If you reach for Docker as a stand-in, create a non-root user with
   passwordless sudo inside the container and test as that user — don't just
   run everything as the container's default root.
5. **Never trust an exit code alone as proof something worked.** Verify real state:
   `command -v <tool>`, `dpkg -s <package>` / `apt list --installed`,
   file-existence checks, `chezmoi status`, `chezmoi doctor`. The Windows session
   found multiple failures that were exit-code 0 or silently swallowed and only
   surfaced once real verification was added.
6. **This machine is real, not a sandbox.** Treat destructive or hard-to-reverse
   steps (overwriting `~/.ssh`, changing the login shell via `chsh`/`usermod`,
   force-pushing, `rm -rf` on config dirs) as things to confirm before doing.

## Repo layout you'll be working with

- `install.sh` — universal installer. Its prerequisite bootstrap
  (`install_package()`) only knows `apt` and only recognizes distros whose
  `/etc/os-release` `ID`/`ID_LIKE` matches `ubuntu|debian|linuxmint`. On anything
  else (Fedora, Arch, Alpine, etc.) it will print a warning and `exit 1`. Confirm
  what distro you're actually testing on before you start, and don't be surprised
  if a non-Debian-family distro fails at the very first step — that's the script's
  documented, intentional scope, not a bug to fix without discussing scope with the
  user first.
- `run_onchange_install_packages.sh.tmpl` — templated bash script; the
  `install_apt()` function is what runs here (selected via `detect_package_manager()`
  finding `apt`). Handles core tools, modern CLI tools (several via third-party apt
  repos or direct GitHub-release downloads), fonts, AI tools, and — only if
  `$DISPLAY` is set — desktop apps (`install_linux_desktop()`). AI-tools also now
  includes Superpowers (for Claude Code, OpenCode, and Antigravity - not Codex, see
  its own comment there for why), Playwright Chromium, and `act`; Desktop Apps also
  now includes Handy and Termius (FileZilla was removed) and Geany (Notepad++
  equivalent) - see `docs/tool-parity.md` for the current full list and why each
  was added/swapped, kept up to date per-change, this doc isn't.
- `run_onchange_generate_identities.sh.tmpl` — generates `~/.gitconfig-<alias>`
  files and directories from the `accounts` list in `chezmoi.toml`. Bash
  equivalent of the Windows `.ps1.tmpl` version; same purpose.
- `dot_zshrc` — the applied `~/.zshrc`. Hooks starship, zoxide, and direnv via
  `eval "$(<tool> init zsh)"` / `eval "$(direnv hook zsh)"`. `zsh` is a valid
  direnv hook target, so this is less likely to reproduce the exact Windows
  PowerShell 5.1 bug — but verify it hooks without error anyway; don't assume.
- `.chezmoiexternal.toml` — installs Oh My Zsh + plugins + tmux plugin manager via
  pinned-commit GitHub archive downloads. Worth confirming these archives still
  resolve (pinned commits can go stale if a fork/rename happens upstream).
- `private_dot_ssh/private_config.tmpl` → `~/.ssh/config` — generates `Host <provider>-<user>`
  aliases used by the git URL-rewrite system in `dot_gitconfig.tmpl`.

## Known watch-items for Linux specifically (verify, don't assume)

These are things reading the script raised as *plausible* failure points —
confirmed nowhere yet. Check each; report what you actually find, including if it
turns out fine.

- **`git-delta` is fetched directly from GitHub, not apt**, because it's genuinely
  not in the Debian/Ubuntu repos: the script queries
  `https://api.github.com/repos/dandavison/delta/releases/latest` for the latest
  tag and downloads a matching `.deb`. Verify that repo path (`dandavison/delta`)
  is still the correct, current upstream location — projects do occasionally move
  or get renamed/archived. If the API call or download 404s, that's the thing to
  root-cause, not a random retry.
- **`gum` comes from Charm's own apt repo** (`repo.charm.sh`), added and keyed at
  install time. If this fails, check whether it's a GPG key/repo-signing issue
  (common failure mode for third-party apt repos when a key rotates) versus the
  package simply not existing — different root causes, different fixes.
- **`eza` comes from a third-party apt repo** (`deb.gierens.de`) via a
  community-maintained key/repo — same category of risk as gum: verify the repo
  and key URLs are still valid before assuming eza itself is the problem.
- **Docker Desktop's install logic is the most complex block in this script** —
  it derives a repo URL from `/etc/os-release`'s `ID`/`ID_LIKE`/codename, with a
  special case for Linux Mint that substitutes the underlying Ubuntu codename.
  If Docker Desktop fails, check *which* stage failed: repo/key setup, `apt update`
  picking up the new repo, or the final `.deb` install and its dependency
  resolution — these are three different failure classes with three different
  fixes, don't lump them together.
- **Antigravity desktop app: removed from this repo (2026-09-11)** — it used
  to install via a Google-hosted apt repo (`us-central1-apt.pkg.dev`); VS Code
  + the `agy` CLI cover that workflow now. Historical lesson kept: that apt
  path self-tracked the latest version via normal `apt` semantics, so
  failures there were repo-key or `apt update` issues, never stale-version
  issues - a structurally different failure class from the pinned-URL
  macOS/Windows installs of the same app.
- **Batched `apt install` calls with `|| true`** appear in a few places (e.g. the
  utilities line: `apt install -y meld flameshot vlc p7zip-full obs-studio
  qbittorrent ghostscript`). A failure of any one package in a batch like
  this can be silently absorbed. If you suspect something in a batch failed, check
  each package's actual install state individually (`dpkg -s <name>`) rather than
  trusting the batch's exit code — this mirrors exactly the `choco` idempotency
  bug found on Windows (a batch operation whose failures were invisible until
  someone checked real state).
- **`install_linux_desktop()` only runs if `$DISPLAY` is set.** On a headless
  Linux box/VM/CI runner, expect it to be skipped entirely — that's intentional,
  not a bug. Don't "fix" this by forcing desktop installs on a headless system
  without checking with the user first.
- **`fd` (confirmed and fixed):** Ubuntu/Debian's apt package is `fd-find`, but it
  installs its binary as `fdfind`, not `fd` — every other modern-CLI tool in this
  list matched its apt package name to its actual binary name except this one.
  Confirmed live: this was the *only* modern tool missing from PATH after a real
  full install. Fixed with a symlink (`~/.local/bin/fd` -> `fdfind`), matching the
  existing `batcat` -> `bat` pattern already in the script for the exact same
  Debian-naming-convention reason. If this regresses, check the symlink target
  actually exists before assuming `fd-find` itself failed to install.
- **Ollama installer failures cascading into unrelated later installs (confirmed
  and fixed):** Ollama's official installer can exit non-zero for reasons
  unrelated to whether `ollama` itself landed (e.g. failing to auto-launch a GUI
  post-install with no desktop session). Under this script's `set -euo pipefail`,
  that single non-critical failure used to abort every remaining install in the
  whole run - confirmed live on macOS (desktop apps and the Antigravity install,
  both later in the script, never ran), and defensively fixed on Linux too even
  though it wasn't separately confirmed failing here (same installer script,
  same risk). Now wrapped in `|| warn ...` so it can't cascade. If you're
  testing and something *after* the AI-tools section is unexpectedly missing,
  check whether Ollama's install step
  logged a warning right before it - that used to be a silent full-script abort.

## Procedure

1. **Get repo access.** This is a private repo. Use `gh auth status` if a `gh`
   session already exists; otherwise ask the user how to authenticate (fresh PAT,
   SSH deploy key, or `gh auth login`). Do not proceed with a credential you
   weren't given explicitly for this purpose.
2. **Read `install.sh` and `run_onchange_install_packages.sh.tmpl`** in full before
   running anything (you now have summaries above, but re-fetch current content —
   the repo may have changed since this doc was written).
3. **Confirm install scope with the user** (full vs core-only, and whether
   `sudo` can run non-interactively) before running.
4. **Run the install**, capturing full output to a log file — don't rely on
   scrollback. Something like:
   ```sh
   sh install.sh 2>&1 | tee ~/dotfiles-install.log
   echo "EXIT=$?"
   ```
5. **Verify real end state**, not just the exit code:
   - `chezmoi status` — should be empty (no drift).
   - `chezmoi doctor` — review warnings, not just errors.
   - For every package/app the config says should be installed, check it's
     actually there: `command -v <tool>`, `dpkg -s <package>`, or the app's actual
     binary path.
   - Load a fresh shell (`zsh -l`) and confirm no errors print during startup —
     this is exactly how the Windows PowerShell-profile bug was caught; a script
     "succeeding" doesn't mean the file it wrote is actually clean on next load.
6. **For every failure or discrepancy found:**
   - Reproduce it directly (re-run the specific failing command outside the big
     script) to get the *actual* error text, not just "it failed."
   - Diagnose root cause. Is the package name wrong? Is a flag/argument the tool
     no longer accepts (tools change their CLIs between major versions — this is
     exactly what happened with Chocolatey's `--local-only` removal on Windows)?
     Is a third-party repo's signing key stale/rotated? Is it a stale pinned
     version/URL? Or is it a real upstream outage/packaging lag unrelated to this
     repo (like the Windows Chrome-checksum case)?
   - **Categorize before fixing:** a genuine bug in this repo's scripts gets fixed
     here; a transient/upstream issue gets reported as such and left alone, with a
     clear explanation of why it's not actionable in this repo.
   - Apply the smallest correct fix. Re-run to verify the fix actually resolves the
     original symptom end-to-end — don't consider it fixed until you've reproduced
     success, not just "the diff looks right."
7. **Check for drift you may have introduced.** Any command you run outside the
   script (auth setup, credential helpers, manual `git config` changes, etc.) can
   modify a file chezmoi thinks it owns. Run `chezmoi status` again after any such
   side step. If it shows unexpected drift, resolve it (usually: revert your change
   so the file matches the template again, since chezmoi owning the file cleanly is
   the point) before concluding.
8. **Before committing:** stage only the files you intended to change, review
   `git diff --stat` and the full diff, and write a commit message that explains
   *why* (root cause), not just *what*.
9. **Before pushing: stop and confirm with the user.** Show them the diff and your
   findings first. Pushing to their real GitHub repo is an outward-facing,
   consequential action — don't do it on your own initiative just because tests
   passed locally.
10. **Report back** in a structured summary:
    - What was verified working, with how you verified it (not just "it worked").
    - Real bugs found, root cause, fix applied, and how the fix was verified.
    - Things that looked broken but weren't (false leads ruled out) — this is
      valuable, don't omit it.
    - Known issues left unfixed, and why (transient/upstream, needs a design
      decision, out of scope, etc.).
    - Any credentials, drift, or side effects you introduced and how you cleaned
      them up.
