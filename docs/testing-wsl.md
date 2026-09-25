# Testing the dotfiles on WSL

You are a coding agent tasked with verifying (and, where safe, fixing) that this
chezmoi-managed dotfiles repo installs and applies cleanly under **WSL** (Windows
Subsystem for Linux, typically an Ubuntu distro). This doc describes the
methodology used to do the same job on native Windows in an earlier session,
adapted for this platform.

**WSL runs the same `apt`-based Linux code path as native Linux.** Everything in
`docs/testing-linux.md` about `install_apt()`, third-party apt repos, batched
installs, etc. applies here too — read that doc first, then come back to this one
for what's *specifically different* about WSL. Don't duplicate that diagnostic
work; this doc only covers the WSL-specific layer on top of it.

**Do not assume the Windows-native session's specific bugs apply here.** That
session found Chocolatey-specific issues (wrong package IDs, a removed CLI flag,
a renamed Windows app). WSL uses `apt`, like Linux — a different registry, different
failure modes. Port the *method*, not the *fixes*.

## What's actually different about WSL

1. **Two separate filesystems, two separate `~/.ssh`.** WSL has its own Linux home
   directory, entirely separate from `C:\Users\<you>` on the Windows side. SSH keys
   that already exist in Windows' `~/.ssh` are **not** automatically available
   inside WSL — they'd need to be explicitly copied in, or referenced via the
   `/mnt/c/Users/<you>/.ssh/` mount, neither of which happens by default. This means
   a private-repo clone over SSH will likely fail here even if it works fine on the
   Windows side of the same machine. Check what auth is actually available inside
   the WSL shell before assuming repo access works — don't assume it carries over
   from Windows.
2. **Environment detection matters and is worth verifying directly.**
   `isWsl`/`isHost` are **not** stored data (they used to be, and used to go stale
   after copying `chezmoi.toml` to a different machine — that whole class of bug is
   gone now). They're computed inline, fresh on every render, wherever they're
   actually needed — currently `run_onchange_install_packages.sh.tmpl` and
   `dot_gitconfig.tmpl` (the latter uses the detection to decide whether `code`
   should be the git editor - see its own comment block), via
   `.chezmoi.kernel.osrelease` containing `"microsoft"` (on Linux) for `isWsl`, and
   `isHost := not isDevcontainer and not isWsl`. This used to cascade into a real
   behavior difference via `install_antigravity()`'s host-only gate (that function
   is a removed no-op now); the live example of the same mechanism is
   `dev_desktop`'s host-only gate — i.e. desktop apps are expected to **not**
   install under WSL, by design. Since there's no
   stored value to inspect via `chezmoi data` anymore, verify by checking the actual
   *effect*: run `chezmoi execute-template '{{ .chezmoi.kernel.osrelease }}'` and
   confirm it contains `microsoft` on your WSL test instance, and confirm Antigravity
   was actually skipped (or not) matching that. A misdetection here would quietly
   change everything downstream, and would itself be a real, worth-reporting bug
   distinct from any individual package failure.
3. **Desktop apps are hard-gated host-only (`$isHost`), same as Antigravity —
   verify it's skipped for that reason, not by luck.** This was tightened this
   session after a real bug was found live on this exact WSL setup: the *only*
   guard used to be `install_linux_desktop()`'s runtime `if [[ -n "$DISPLAY" ]]`
    check, and WSLg (the default GUI stack on current Windows 11) sets `$DISPLAY`
    automatically — so with `dev_desktop = true` in `chezmoi.toml`, that
   runtime check alone let Chrome/VS Code/Docker Desktop actually attempt to
   install *inside* WSL, duplicating what's already on the Windows host (and, for
   Docker Desktop specifically, plausibly conflicting with the host's own
   WSL-integrated Docker Desktop). Fixed by gating the call site itself on
   `$isHost` (computed once near the top of `run_onchange_install_packages.sh.tmpl`
   and shared across the host-only install paths — see point 2's `$isWsl` detection),
   with `$DISPLAY` kept only as a secondary safety net for genuine headless Linux
   hosts. To verify: confirm `$DISPLAY` is actually set on your WSL instance (it
   likely is, under WSLg) *and* confirm desktop apps were still skipped anyway —
    if desktop apps only appear skipped because `$DISPLAY` happens to be unset on
    your particular setup, that's not proof this gate works; test with
    `dev_desktop = true` and a WSLg session (`$DISPLAY` set) specifically.
4. **Interop paths and line endings.** WSL can see and execute Windows binaries via
   `PATH` interop (e.g. `code.exe`), and `dot_gitconfig.tmpl` has logic
   (`lookPath "code"`) that changes `core.editor` based on whether `code` is
   findable. Also watch for CRLF-vs-LF issues if any file gets touched from both
   sides — the generated gitconfig sets `autocrlf = input` for exactly this reason,
   but that alone isn't a full guarantee: a real CRLF drift on this repo's own
   shell scripts was confirmed this session (found via `act`, of all things - see
   point 6 below), traced to the local working tree, not the committed history.
   Fixed by adding a real `.gitattributes` (forces LF for `*.sh`/`*.sh.tmpl`, CRLF
   for `*.ps1`/`*.ps1.tmpl`) - if you see unexpected line-ending diffs in
   `chezmoi status` or `git status`, run `git add --renormalize .` first, and if
   that doesn't clear it, root-cause it rather than dismissing it.
5. **`sudo` and non-interactive sessions.** Same caveat as native Linux:
   `install_apt()` calls `sudo -v` up front assuming an interactive TTY. Confirm
   passwordless sudo or interactive execution before running, same as you would
   natively — WSL doesn't change this requirement.

   **Never run `install.sh` itself with `sudo`, and don't test as literal root
   either** — a real WSL user is essentially never root; they're a normal user
   with `sudo` available, same as native Linux. `install_apt()` elevates
   internally via its own `$SUDO` variable only for the steps that need it.
   This matters beyond style: testing as root produces *different, misleading*
   failures that are artifacts of the test posture, not real WSL bugs — found
   live this session, testing via an isolated Docker container run as root
   (see `docs/testing-linux.md`'s Docker-fallback note): Claude Code's
   installer explicitly detects and refuses to run under sudo/root
   (`Error: do not run this installer with sudo`), and a since-fixed bug in
   `install_node()` (`$SUDO -E bash -` expanding to a bogus bare `-E` command
   when `$SUDO` is empty) only ever triggered because the test was already
   root. If you reach for a Docker container as a WSL stand-in per the
   ground rules below, create and test as a non-root user with passwordless
   sudo inside it — don't just run everything as the container's default root.
6. **`act` (local GitHub Actions runner) works here, with a caveat.** Installed
   under the `agent_toolkit` group on WSL like everywhere else (via the Linux/apt
   install
   script, since WSL runs that same code path) - it genuinely works, but only if
   Docker Desktop's WSL integration is enabled for this distro (Settings >
   Resources > WSL Integration on the Windows host; off by default per-distro).
   Confirmed installing the binary is harmless either way even if that's not
   enabled - it just won't have a Docker daemon to talk to until it is. Separately,
   and more fundamentally: `act` runs every job inside a real Docker container, and
   this repo's `isDevcontainer` check (point 2 above) treats *any* Docker container
   as one - so `$interactive` can never be `true` under `act`, on WSL or anywhere
    else, meaning it can validate script/template syntax but can never actually
    exercise `core`/`agent_toolkit`/etc content. Confirmed this
   limitation directly while testing a real fix this session - had to fall back to
   isolated `docker run` tests instead of `act` for anything package-install-related.
7. **`chezmoi doctor`'s `hardlink` check reports `error` here - that's a false
   alarm, not a real problem.** It tries to hardlink a test file from the source
   dir to `/tmp` to check support; on a WSL setup where `/tmp` is a separate
   `tmpfs` mount from `/` (confirmed live this session - `df -T` showed `/tmp`
   as `tmpfs`, the source dir's filesystem as `ext4`), that's a plain
   `invalid cross-device link`, which hardlinks fundamentally can't cross by
   design. Doesn't affect `chezmoi apply`/`status`/anything real - only this one
   diagnostic self-test. Don't "fix" it (e.g. by trying to remount `/tmp`); just
    don't mistake it for output of your own testing. Also confirmed live: this is
    independent of `dev_desktop` correctly force-`false`
   on WSL - not just via the apply-time `$isHost` gate (points 2-3 above), but
   *also* at `chezmoi init` time itself, since `.chezmoi.toml.tmpl` writes
   `false` whenever `$isHost` is false, regardless of what a
   hand-edited `chezmoi.toml` said before that `init` ran. Two independent
   layers landing on the same answer, not a contradiction if you see the
   toggle "reset" after `chezmoi init --apply`.
8. **Two real bugs were found and fixed live on WSL this session** - worth
   knowing about so you don't rediscover them from scratch: Playwright's
   `install-deps` can hang indefinitely under `sudo` here (now `timeout`-wrapped,
   see the comment at that call site in `run_onchange_install_packages.sh.tmpl`),
   and Ollama's installer silently fails outright without `zstd` present (now
   added to the `core` group, see the comment above the Ollama install block in
   the same file). If either regresses, the fix and the live evidence that
   motivated it are documented right at the call site, not just here.

## Ground rules (same as every platform)

1. **Confirm scope with the user before running a full install.** Ask whether to do
   a full install (all package toggles in `chezmoi.toml`) or a minimal core-only
   restore first. Do not silently assume "full."
2. **Never blind-pipe a remote script into a shell.** Read scripts before running
   them, at least the first time.
3. **Treat any pasted token as already compromised.** Prefer `gh auth login` /
   an existing `gh` session. Never leave a token embedded in a git remote URL —
   use a credential helper or SSH instead (this exact cleanup was needed and done
   in the Windows session).
4. **Never trust an exit code alone as proof something worked.** Verify real state:
   `command -v <tool>`, `dpkg -s <package>`, `chezmoi status`, `chezmoi doctor`,
   `chezmoi data` (for the environment-detection flags above).
5. **This machine is real, not a sandbox.** Confirm before destructive or
   hard-to-reverse steps.

## Procedure

1. **Get repo access from inside WSL specifically** — don't assume Windows-side
   credentials carry over (see point 1 above). Use `gh auth status` inside the WSL
   shell, or ask the user how to authenticate there.
2. **Read `install.sh` and `run_onchange_install_packages.sh.tmpl`** in full before
   running anything — re-fetch current content, the repo may have changed since
   this doc was written. Cross-reference `docs/testing-linux.md`'s watch-items;
   they all apply here since it's the same `install_apt()` code path.
3. **Confirm install scope with the user** before running.
4. **Run the install**, capturing full output to a log file:
   ```sh
   sh install.sh 2>&1 | tee ~/dotfiles-install.log
   echo "EXIT=$?"
   ```
5. **Verify real end state:**
   - `chezmoi status` — should be empty (no drift).
   - `chezmoi doctor` — review warnings, not just errors.
   - `chezmoi execute-template '{{ .chezmoi.kernel.osrelease }}'` — confirm it
     contains `microsoft`, matching real WSL detection (see point 2 above; these
     values aren't stored data anymore, so `chezmoi data` won't show them).
   - For every package/app the config says should be installed, check it's
     actually there.
   - Load a fresh shell (`zsh -l`) and confirm no errors print during startup.
6. **For every failure or discrepancy found:**
   - Reproduce it directly to get the actual error text.
   - Diagnose root cause, and specifically ask: *is this a WSL-layer issue (auth,
     environment detection, interop, filesystem boundary) or the same underlying
     apt/package issue that `docs/testing-linux.md` would also hit natively?*
     That distinction changes where the right fix belongs.
   - Categorize: genuine repo bug (fix it) vs. transient/upstream issue (report,
     don't touch) vs. environment/setup issue on this specific WSL instance
     (report to the user, likely not a repo fix at all).
   - Apply the smallest correct fix. Re-run to verify it resolves the original
     symptom end-to-end.
7. **Check for drift you may have introduced**, same as every platform — run
   `chezmoi status` again after any manual side steps (auth setup, credential
   helpers, manual config edits) and resolve any unexpected drift before
   concluding.
8. **Before committing:** stage only the files you intended to change, review the
   full diff, and write a commit message that explains *why* (root cause).
9. **Before pushing: stop and confirm with the user.** Show them the diff and your
   findings first — don't push on your own initiative.
10. **Report back** in a structured summary:
    - What was verified working, with how you verified it.
    - Real bugs found, root cause, fix applied, and how the fix was verified —
      note explicitly whether each finding is WSL-specific or shared with native
      Linux, so the user knows whether `docs/testing-linux.md`'s findings need to
      be cross-checked too (and vice versa).
    - Things that looked broken but weren't (false leads ruled out).
    - Known issues left unfixed, and why.
    - Any credentials, drift, or side effects you introduced and how you cleaned
      them up.
