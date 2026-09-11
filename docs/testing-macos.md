# Testing the dotfiles on macOS

You are a coding agent tasked with verifying (and, where safe, fixing) that this
chezmoi-managed dotfiles repo installs and applies cleanly on **macOS**. This doc
describes the methodology used to do the same job on Windows in an earlier session,
adapted for this platform. Read it fully before running anything.

**Do not assume the Windows session's specific bugs apply here.** Windows used
Chocolatey; macOS uses Homebrew. Different package registries, different naming,
different failure modes. Port the *method*, not the *fixes*. Diagnose this platform
fresh, from first principles.

## Ground rules

1. **Confirm scope with the user before running a full install.** A full run installs
   dozens of packages via Homebrew, plus several apps via direct `.dmg`/`.pkg`
   downloads (ScreenRec), and modifies `~/.ssh`, `~/.gitconfig`, and your
   shell profile. Ask whether to do a full install (all package toggles in
   `chezmoi.toml`) or a minimal core-only restore first, same as was done on Windows.
   Do not silently assume "full."
2. **Never blind-pipe a remote script into a shell.** `install.sh` and everything it
   calls download and execute further scripts (Homebrew's installer, Ollama's
   installer, Claude Code's installer, etc.). Fetch and read each script's content
   before running it, at least the first time. If you can't read a step before it
   runs (e.g. it's `curl | bash` inside another script you don't control), say so
   explicitly in your report rather than silently trusting it.
   **Never run `install.sh` with `sudo` in front of it on macOS, and don't test as
   root either** — unlike the Linux/WSL scripts, `install_brew()` doesn't use a
   `$SUDO` variable anywhere; it never needs root for anything. Homebrew itself
   refuses to run as root at all (`Running Homebrew as root is extremely
   dangerous and no longer supported`), so running the whole script under sudo
   fails hard and immediately at the first `brew install` (or even earlier, at
   Homebrew's own bootstrap install if it's not already present) - that's
   Homebrew behaving correctly, not a bug to work around. If you somehow got
   further before hitting that, Claude Code's own installer also explicitly
   detects and refuses sudo/root (`Error: do not run this installer with sudo`)
   - confirmed live this session on Linux; same installer script, same check,
   though not yet independently confirmed triggering here on macOS.
3. **Treat any pasted token as already compromised.** If the user gives you a GitHub
   PAT in chat, tell them to rotate it. Prefer `gh auth login` / an existing `gh`
   session over a pasted token. If you must clone with a token embedded in the
   remote URL, replace it with a credential helper or SSH afterward — a token sitting
   in plaintext in `.git/config` is a real finding, not a nitpick (this exact thing
   happened and was fixed in the Windows session).
4. **Never trust an exit code alone as proof something worked.** Verify real state:
   `command -v <tool>`, `brew list --formula <name>` / `brew list --cask <name>`,
   `Test-Path`-equivalent file existence checks, `chezmoi status`, `chezmoi doctor`.
   The Windows session found multiple failures that were exit-code 0 or silently
   swallowed and only surfaced once real verification was added.
5. **This machine is real, not a sandbox.** Treat destructive or hard-to-reverse
   steps (overwriting `~/.ssh`, force-pushing, `rm -rf` on config dirs) as things to
   confirm before doing, per the same posture used on Windows.

## Repo layout you'll be working with

- `install.sh` — universal installer. On macOS it installs `chezmoi` via
  `get.chezmoi.io`, then runs `chezmoi init --apply`. Note it does **not** have a
  macOS-specific prerequisite-install path — its `install_package()` helper only
  knows how to use `apt` (ubuntu/debian/linuxmint). If `git`, `curl`, `gpg`, `wget`,
  or `7z` are missing on a fresh Mac (no Xcode Command Line Tools), this step has no
  fallback and will `exit 1` with "Automatic installation not supported." **Check
  this first** — it's a plausible real gap, not confirmed. If you hit it, the
  practical fix during testing is `xcode-select --install` before you start; whether
  to patch the script to detect Homebrew/macOS is a decision to raise with the user,
  not to do unilaterally.
- `run_onchange_install_packages.sh.tmpl` — templated bash script; the
  `install_brew()` function is what runs on macOS (detected via
  `detect_package_manager()` finding `brew`). Handles core tools, modern CLI tools,
  fonts (cask), AI tools, and desktop apps (casks) — each gated by the matching
  `chezmoi.toml` `[data.packages]` toggle, mirroring the Windows script's structure.
  AI-tools also now includes Superpowers (for Claude Code, OpenCode, and
  Antigravity - not Codex, see its own comment there for why), Playwright Chromium, and
  `act`; Desktop Apps also now includes Handy, Termius, Geany, and Meld (FileZilla
  was removed - see `docs/tool-parity.md` for the current full list and why each
  was added/swapped, kept up to date per-change, this doc isn't).
- `run_onchange_generate_identities.sh.tmpl` — generates `~/.gitconfig-<alias>` files
  and directories from the `accounts` list in `chezmoi.toml`. Bash equivalent of the
  Windows `.ps1.tmpl` version; same purpose.
- `dot_zshrc` — the applied `~/.zshrc`. Hooks starship, zoxide, and direnv via
  `eval "$(<tool> init zsh)"` / `eval "$(direnv hook zsh)"`. Unlike the Windows
  PowerShell 5.1 case, `zsh` **is** a valid direnv hook target, so this one is less
  likely to reproduce that exact bug — but verify it actually hooks without error
  anyway; don't assume.
- `.chezmoiexternal.toml` — installs Oh My Zsh + plugins + tmux plugin manager via
  pinned-commit GitHub archive downloads. Same on every platform; worth confirming
  these archives still resolve (pinned commits can go stale if a fork/rename
  happens upstream, same class of issue as the Antigravity URL below).
- `private_dot_ssh/config.tmpl` → `~/.ssh/config` — generates `Host <provider>-<user>`
  aliases used by the git URL-rewrite system in `dot_gitconfig.tmpl`.

## Known watch-items for macOS specifically (verify, don't assume)

These are things reading the script raised as *plausible* failure points — confirmed
nowhere yet. Check each; report what you actually find, including if it turns out
fine.

- **Antigravity desktop app: removed from this repo (2026-09-11)** — VS Code +
  the `agy` CLI cover that workflow; the install code, the
  `ANTIGRAVITY_VERSION` dmg pin, and the auto-update leg are all gone. The
  history below is kept for the lessons, which outlived the app:
  `run_onchange_install_packages.sh.tmpl`'s macOS `.dmg` URL pointed at the
  wrong filename after Google renamed the app "Antigravity" → "Antigravity
  IDE" (`Antigravity.dmg`, 404 → `Antigravity%20IDE.dmg`, confirmed live via a
  direct HTTP check), and the mount/copy step assumed the pre-rename
  volume/bundle names and failed the same way
  (`cp: /Volumes/Antigravity/Antigravity.app: No such file or directory`)
  until fixed to discover the mounted volume and `.app` bundle at runtime.
  The same class of stale-name bug hit Windows first (see
  `docs/testing-windows.md`). Lesson: never hardcode names a vendor can
  rename; discover them at runtime or let a package manager own them.
  Also worth noting: this repo's `scripts/update-versions.sh` (the weekly
  auto-updater) had been silently failing to update that version at all, for a
  completely unrelated reason (a `curl` gzip-decoding bug) — every one of its 10
  merged PRs since inception only ever touched `.chezmoi-version`. That's fixed
  now too. (With the Antigravity leg removed, the auto-updater manages
  `.chezmoi-version` only.)
- **Prerequisite bootstrap gap for fresh Macs** — see "Repo layout" above.
- **`gum` and `git-delta` are real Homebrew formulae** (`brew install gum` and
  `brew install git-delta` both work) — unlike the Windows Chocolatey case, do
  **not** assume these need fixing. This is exactly the kind of thing that looks
  like it should be broken by analogy to the Windows findings but almost certainly
  isn't. Verify, don't fix blind.
- **`brew install` failures in a batched list** (`brew install bat eza fd git-delta
  zoxide starship direnv lazygit gum || true`) — the trailing `|| true` means a
  failure of *any* package in that list is silently swallowed and you get no
  indication which one(s) failed or why. If you're diagnosing a missing tool, check
  each package's actual install state individually
  (`brew list --formula <name>` / `brew list --cask <name>`) rather than trusting
  this line's exit code — this mirrors exactly the `choco` idempotency-check bug
  found on Windows (a batch operation whose failures were invisible until someone
  checked real state).
- **Homebrew Apple Silicon vs Intel paths** — the script handles both
  (`/opt/homebrew` vs `/usr/local` implicitly via `brew shellenv`), but confirm on
  whichever architecture you're actually testing on; don't assume the other arch
  also works without a separate check.

## Procedure

1. **Get repo access.** This is a private repo. Use `gh auth status` if a `gh`
   session already exists; otherwise ask the user how to authenticate (fresh PAT,
   SSH deploy key, or `gh auth login`). Do not proceed with a credential you weren't
   given explicitly for this purpose.
2. **Read `install.sh` and `run_onchange_install_packages.sh.tmpl`** in full before
   running anything (you now have summaries above, but re-fetch current content —
   the repo may have changed since this doc was written).
3. **Confirm install scope with the user** (full vs core-only) before running.
4. **Run the install**, capturing full output to a log file — don't rely on
   scrollback. Something like:
   ```sh
   sh install.sh 2>&1 | tee ~/dotfiles-install.log
   echo "EXIT=$?"
   ```
5. **Verify real end state**, not just the exit code:
   - `chezmoi status` — should be empty (no drift).
   - `chezmoi doctor` — review warnings, not just errors.
   - For every package/app the config says should be installed, check it's actually
     there: `command -v <tool>`, `brew list --formula|--cask <name>`, or the app's
     actual binary/bundle path.
   - Load a fresh shell (`zsh -l`) and confirm no errors print during startup —
     this is exactly how the Windows PowerShell-profile bug was caught; a script
     "succeeding" doesn't mean the file it wrote is actually clean on next load.
6. **For every failure or discrepancy found:**
   - Reproduce it directly (re-run the specific failing command outside the big
     script) to get the *actual* error text, not just "it failed."
   - Diagnose root cause. Is the package name wrong? Is a flag/argument the tool
     no longer accepts (tools change their CLIs between major versions — this is
     exactly what happened with Chocolatey's `--local-only` removal on Windows)?
     Is it a stale pinned version/URL? Is it a real upstream outage or packaging
     lag unrelated to this repo (like the Windows Chrome-checksum case)?
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
