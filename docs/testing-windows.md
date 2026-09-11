# Testing the dotfiles on Windows

This doc records the methodology actually used to install, verify, debug, and fix
this repo on native Windows in a prior session — not a hypothesis, a completed run.
Ten real bugs were found and fixed across three passes (commits `f7bcdf9`,
`b40d86a`, and `e3612db` on `main`) — the third pass specifically because the
*user* caught two bugs the first two passes missed, by simply opening a normal
terminal window. Use this as the reference for what a thorough test pass looks
like, and to know what's already been verified fixed vs. what's newer/less
battle-tested and worth another close look.

**The third pass is the most important lesson in this whole doc:** the first two
passes verified the Windows PowerShell 5.1 profile using
`-ExecutionPolicy Bypass`, and never opened a real PowerShell 7 session at all.
Both gaps hid a real bug each — a missing execution-policy configuration, and a
`starship`/`zoxide` shell-argument error — that a real user hit within minutes of
opening a normal terminal. "Verified" in this repo means opened in a genuinely
unmodified, ordinary session of *every* shell this repo configures, not run
through whatever flags happen to make your own test harness cooperate.

If you're testing macOS, Linux, or WSL instead, see `docs/testing-macos.md`,
`docs/testing-linux.md`, or `docs/testing-wsl.md`. **Do not port the specific bugs
below to those platforms by analogy** — they're Chocolatey-specific (wrong package
IDs, a removed CLI flag, a renamed Windows app). Different package manager,
different failure modes.

## Ground rules

1. **Confirm scope with the user before running a full install.** A full run
   installs Chocolatey, ~30 packages, several standalone `.exe`/`.msi` installers,
   and modifies `~/.ssh`, `~/.gitconfig`, and both PowerShell profiles. Offer a
   choice: core-only restore (git + chezmoi + `chezmoi apply`, no Chocolatey/package
   installs) vs. full install. Don't assume "full."
2. **Admin elevation cannot be automated from here.** `install.ps1` checks
   `IsInRole(Administrator)`; if not elevated, it prompts interactively
   (`Read-Host "...Restart as Admin? (Y/n)"`) and, on a "yes," calls
   `Start-Process -Verb RunAs`, which pops a **UAC consent dialog** — a GUI element
   no agent can click through. If the shell isn't already elevated, ask the user to
   relaunch/elevate the terminal themselves before you proceed with a full install;
   don't try to script around a UAC prompt.
3. **Non-interactive shells cannot answer prompts — including chezmoi's own.** Any
   `Read-Host` (the install script's admin question, its trailing "Press Enter to
   exit") or `chezmoi apply`'s interactive drift prompt
   (`<file> has changed since chezmoi last wrote it? diff/overwrite/all-overwrite/
   skip/quit`) will hang or error out in a non-interactive session. If you hit a
   chezmoi drift prompt, don't just retry — go find *why* the file drifted (see
   the `.gitconfig` lesson below) and resolve the underlying cause so the prompt
   doesn't recur, rather than trying to script an answer to it.
4. **PATH does not persist between separate PowerShell invocations.** Each new
   process only sees `Machine`+`User` PATH as of process start. After installing
   anything that adds to PATH (Chocolatey itself, individual packages), refresh it
   explicitly at the start of every subsequent command:
   ```powershell
   $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
   ```
   Forgetting this reliably produces false "command not found" errors that look
   like real bugs but aren't.
5. **Never redirect a native command's stderr with `2>&1` or `*>&1` in Windows
   PowerShell 5.1** unless you're prepared for false positives. It wraps each
   stderr line in a `NativeCommandError` and can make normal status output (e.g.
   git's `Cloning into '...'`) look like a failure. This produced exactly one false
   alarm in the original run (a `git clone` that had actually succeeded). Prefer
   capturing stdout/stderr separately, or just verify real state afterward instead
   of trusting the stream.
6. **`git commit -m` with a message containing embedded double quotes gets mangled**
   by PowerShell's native-argument quoting — parts of the message can get
   interpreted as separate arguments/pathspecs. Write the message to a file and use
   `git commit -F <file>` instead.
7. **Treat any pasted token as already compromised.** Prefer `gh auth login` / an
   existing `gh` session. If a repo gets cloned with a token embedded in the remote
   URL, replace it with SSH or a proper credential helper afterward — but see the
   drift lesson below before you do that.
8. **Watch for drift you introduce via `gh` or credential setup.** Running
   `gh auth setup-git` added a `[credential]` block to `~/.gitconfig` that
   chezmoi's template didn't know about, which is exactly what caused the drift
   prompt in point 3. This repo manages git identity/auth entirely through SSH host
   aliases (see `dot_gitconfig.tmpl`'s `[url ...] insteadOf` rules and
   `private_dot_ssh/config.tmpl`) — it doesn't need `gh`'s https credential helper
   at all for its own push/pull. If you add something like this, either don't
   (confirm SSH already works via `ssh -T git@github-<alias> -o BatchMode=yes`
   first — it likely does), or revert it afterward so `chezmoi status` stays
   clean.
9. **Never trust an exit code alone as proof something worked.** This is the
   single biggest lesson from this session — see "The exit-code lesson" below.
10. **`-ExecutionPolicy Bypass` in your own test invocations hides real bugs.**
    It's tempting to add it everywhere to avoid friction, but a real user's
    terminal won't have it. If nothing in this repo's install flow explicitly
    configures the execution policy, testing exclusively under `Bypass` will
    make a completely broken profile look fine. Test at least once using
    whatever policy the machine actually has (or would have fresh), not just
    a bypassed one — see `run_once_windows_set-executionpolicy.ps1.tmpl` for
    why this repo now configures it explicitly.
11. **This repo installs *two* PowerShell profiles — test both, independently.**
    `Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1` (5.1) and
    `Documents/PowerShell/Microsoft.PowerShell_profile.ps1` (7+) are separate
    files with separate tool-invocation conventions (see point 12) and fixing
    one tells you nothing about the other — this session shipped a "verified"
    fix for the 5.1 profile while the 7 profile had its own, different, still
    completely broken `starship`/`zoxide` calls the entire time.
12. **Different CLI tools disagree on what to call "the PowerShell language."**
    `direnv hook pwsh` is correct and `direnv hook powershell` is rejected.
    `starship init powershell` and `zoxide init powershell` are correct and
    `... init pwsh` is rejected by both — on *either* Windows PowerShell 5.1 or
    PowerShell 7. There's no consistent rule here; check each tool's actual
    accepted values (most print them in their own error message when you pass
    the wrong one) rather than assuming a shell name that worked for one tool
    works for another.
13. **Avoid `chezmoi apply -v` (or anything else that routes a diff through the
    configured pager) in non-interactive automation.** This repo sets
    `pager = "delta"`; `delta` invoked with no data and no attached terminal can
    sit waiting on stdin indefinitely with no error, no timeout, and no child
    process to point at the cause. It happened live in this session and looked
    identical to a generic hang until the process tree was inspected. Use plain
    `chezmoi apply` for automated/scripted runs; save `-v` for a real interactive
    session where you can actually watch and quit the pager.
14. **A cmdlet's own success/failure report is not "real state" either.**
    `Set-ExecutionPolicy` can emit a non-terminating, non-fatal notice about an
    overriding Process-scope policy that has nothing to do with whether the
    persistent value it just wrote actually took — treating that notice as a
    failure (e.g. via `-ErrorAction Stop`) produces a false negative. Separately,
    the `Microsoft.PowerShell.Security` module (which owns
    `Get-/Set-ExecutionPolicy`) reproducibly failed to auto-load specifically
    inside chezmoi's own run_once/run_onchange script invocation in this
    session, for reasons never fully root-caused — which silently no-op'd a
    cmdlet-based fix entirely. Where a builtin PowerShell module might not be
    reliably available in a scripted context, prefer a primitive with no
    module-autoload dependency (e.g. the registry provider directly) and verify
    by reading the actual resulting state back (a real registry value, a real
    file on disk), not by trusting the cmdlet that wrote it.

## The exit-code lesson (read this one carefully)

The original `run_onchange_install_packages.ps1.tmpl` package-install loop looked
like this:

```powershell
$installed = choco list --local-only --exact $pkg 2>$null | Select-String "^$pkg\s"
if (-not $installed) {
    Write-Host "  Installing $pkg..." -ForegroundColor Yellow
    choco install $pkg -y --no-progress | Out-Null
}
```

Two independent problems compounded here, and both were **completely silent**:

- `choco list --local-only` was removed in Chocolatey CLI 2.x (`choco list` is
  local-only by default now). Every call errored, `$installed` was always empty,
  so the loop always attempted to reinstall everything, every run — wasteful but
  not itself fatal.
- `choco install $pkg -y --no-progress | Out-Null` **discards all output and never
  checks `$LASTEXITCODE`.** A failed install looks identical to a successful one
  from the script's point of view.

Because of this, `git-delta` (not a real Chocolatey package ID — it's `delta`) had
been silently failing to install since the very first run, which only became
visible once `chezmoi.toml.tmpl`'s `pager = "delta"` broke `chezmoi apply -v`
outright. Two more failures (`gum` — not a real package under any name — and a
transient `GoogleChrome` checksum mismatch) were *also* being silently swallowed
the entire time, and only surfaced after exit-code checking was added:

```powershell
choco install $pkg -y --no-progress | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Warning: Failed to install $pkg (choco exit code $LASTEXITCODE)" -ForegroundColor Red
}
```

**The general lesson, not the specific fix:** any loop or batch operation that
suppresses output (`| Out-Null`, `2>$null`, `|| true`, etc.) without checking the
actual result code can hide an arbitrary number of failures indefinitely. If
you're testing this repo (on any platform) and something seems to work but a tool
is mysteriously missing afterward, suspect this pattern first and go verify real
state directly rather than trusting the log.

## What's already fixed (verify it's still true, don't re-fix blind)

Commits `f7bcdf9`, `b40d86a`, and `e3612db` on `main` fixed, in order:

1. `direnv hook powershell` in `Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1`
   — direnv has no `'powershell'` hook target at all (only `pwsh` 7.2+); Windows
   PowerShell 5.1 literally cannot use direnv's native hook. Fixed by wiring the
   file's existing (previously unused) `Invoke-DirenvHook` helper into a `prompt()`
   wrapper instead. **Verify:** open a fresh Windows PowerShell 5.1 session, confirm
   no `direnv: error unknown target shell` on load.
2. `"git-delta"` → `"delta"` in the modern-tools package list — wrong Chocolatey
   package ID. **Verify:** `choco list --exact delta` shows it installed, and
   `chezmoi apply -v` doesn't error on the pager.
3. `choco list --local-only` → `choco list` (flag removed in Chocolatey 2.x) +
   `$LASTEXITCODE` checking added — see "The exit-code lesson" above.
4. Antigravity's pinned download URL/version (`1.19.6-1772152296` →
   `2.0.1-4861014005645312`) — the old one 404'd. *(Historical: the entire
   pinned-exe approach is gone — the Antigravity desktop apps were removed
   from this repo on 2026-09-11 after a brief stint as Chocolatey packages;
   there is no Antigravity URL pin left to go stale. The lesson stands:
   hand-pinned vendor URLs rot, and the auto-updater's URL validation was
   built because of exactly this bug.)*
5. Antigravity's install-check path (`...\Programs\Antigravity\Antigravity.exe` →
   `...\Programs\Antigravity IDE\Antigravity IDE.exe`) — Google renamed the app
   ("Antigravity" → "Antigravity IDE", folder and exe both). *(Historical for
   the same reason — the custom block that checked these paths is deleted.
   The lesson stands: never hardcode vendor-controlled paths/names a rename
   can break; discover at runtime or let a package manager own them.)*
6. Antigravity's "already installed" success message printing unconditionally
   instead of only in the true already-installed branch (a real `if`/`else` logic
   bug, found by comparing against the correctly-written `ScreenRec` block right
   below it in the same file).
7. `gum` added as a from-source-GitHub-release install (`charmbracelet/gum`), since
   it's not published to Chocolatey under any name. **This is new, custom code
   (not a battle-tested Chocolatey package install) — worth a closer look than the
   others.** It fetches the *latest* release dynamically via GitHub's API rather
   than a pinned version, specifically to avoid repeating the Antigravity
   stale-pin problem — verify that still works and that the extracted `gum.exe`
   actually lands on PATH and runs.
8. `GoogleChrome` moved out of the Chocolatey package list entirely, replaced with
   a direct MSI download + silent `msiexec` install, because Chocolatey's
   community package's pinned checksum regularly lags Google's release cadence and
   fails installs during that window (confirmed happening live in this session).
   **Also new, custom code — verify the direct-download path still resolves and
   that Chrome's own background updater (Google Update) is what's expected to keep
   it current, not `choco upgrade all`.**
9. `starship init pwsh` / `zoxide init pwsh` → `... init powershell` in
   `Documents/PowerShell/Microsoft.PowerShell_profile.ps1` (the PS7 profile) —
   neither tool accepts `pwsh` as a shell identifier on Windows, only
   `powershell`; this was live and broken from the start, just never caught
   because the PS7 profile was never actually opened in the first two testing
   passes. **Verify:** open a fresh `pwsh` session, confirm zero errors on load
   (not just "loads" — read the output; both tools error to stderr but the
   session still technically starts).
10. `run_once_windows_set-executionpolicy.ps1.tmpl` (new file) — nothing in this
    repo's install flow ever configured PowerShell's execution policy, so on a
    machine where Chocolatey's install didn't happen to touch it as a side
    effect (or where Chocolatey/full install was skipped entirely, e.g. a
    core-only restore onto a machine that already has git+chezmoi), both
    profiles this repo installs would silently never auto-load — the exact
    error the user hit. **Verify:** check the actual registry value
    (`(Get-ItemProperty 'HKCU:\Software\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell' -Name ExecutionPolicy).ExecutionPolicy`
    should be `RemoteSigned`), not just that `chezmoi apply` printed success —
    see ground rule 14 for why the script itself avoids trusting
    `Set-ExecutionPolicy`'s own cmdlet-level success report.

## Known open issue — none left, and one resolved by removal

- **Antigravity's `--silent` install flag doesn't actually silence it** —
  RESOLVED twice over: first when the custom installer block was replaced by
  the community `antigravity-ide` Chocolatey package (which wraps the same
  InnoSetup installer with the real switches — `/VERYSILENT
  /SUPPRESSMSGBOXES /NORESTART /SP-` — plus an auto-launch watchdog), and
  then mooted entirely when the Antigravity desktop apps were removed from
  this repo (2026-09-11). Kept for the lesson: `--silent` was never an
  InnoSetup flag at all — when an installer "ignores" your silent flag,
  check whether the flag belongs to that installer's actual technology
  before blaming the installer.

## SSH agent — known behavior (not a bug)

`run_onchange_generate_identities.ps1.tmpl` sets the Windows **`ssh-agent`
service** to `Automatic` + `Running` and `ssh-add`s each declared account's
auth key and signing key (`id_<account>` + `id_<account>_sign`). The
PowerShell profiles do an idempotent top-up of the same list on shell start.

- **Keys persist across reboots.** The Windows `ssh-agent` service stores added
  keys DPAPI-encrypted under `HKCU\Software\OpenSSH\Agent\Keys` and reloads
  them automatically on start. There is no macOS-style `UseKeychain` on
  Windows and none is needed — the persistence is built into the service.
- **The dotfiles only ever ADD keys, never flush.** A key you loaded yourself
  (an undeclared account, a throwaway) is left alone.
- **To remove a key you must do it by hand:** `ssh-add -d ~/.ssh/<key>` (or
  `ssh-add -D` to clear all, then re-run the profile / generator to reload the
  declared set). De-declaring the account in `chezmoi.toml` or deleting the
  key file does **not** evict it from the running/persisted agent.
- **Verification:** `ssh-add -l` in PowerShell must list the `*_sign` keys,
  not just the auth keys — loading only the auth key is the classic miss.
- **WSL and Windows have separate agents.** WSL runs its own Linux `ssh-agent`
  (loaded via `~/.ssh/agent-identities.zsh` + the OMZ `ssh-agent` plugin);
  the Windows service is unrelated. Run `ssh-add -l` in each environment
  separately — they will not show the same keys unless you bridge them
  (npiperelay), which this repo does not do.

## Repo layout you'll be working with

- `install.ps1` — universal Windows installer (`iex "& {$(irm .../install.ps1)}"`).
  Installs Chocolatey, chezmoi, git, a fixed set of "modern tools," then runs
  `chezmoi init --apply`.
- `run_onchange_install_packages.ps1.tmpl` — templated PowerShell script; core/
  modern/fonts/desktop/AI-tools packages gated by `chezmoi.toml`
  `[data.packages]` toggles, plus the dedicated ScreenRec/Chrome/gum
  blocks described above. AI-tools also now includes Superpowers (for Claude
  Code, OpenCode, and Antigravity - not Codex, see its own comment there for
  why), Playwright Chromium, and `act`; Desktop Apps also now includes Handy,
  Termius, Geany, and Meld (see `docs/tool-parity.md` for the current full
  list and why each was added/swapped - it's kept up to date per-change,
  this doc isn't).
- `run_onchange_generate_identities.ps1.tmpl` — generates `~/.gitconfig-<alias>`
  files from the `accounts` list in `chezmoi.toml`, plus `~/.ssh/allowed_signers`,
  and (see "SSH agent — known behavior" above) configures the `ssh-agent`
  service and loads the declared keys, writing `~/.ssh/agent-identities.ps1`
  for the profiles to consume.
- `Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1` — Windows
  PowerShell 5.1 profile (direnv fix lives here; `starship`/`zoxide` already used
  `init powershell` correctly in this one).
- `Documents/PowerShell/Microsoft.PowerShell_profile.ps1` — PowerShell 7+ profile;
  uses `direnv hook pwsh` (correct target, requires PS 7.2+) and
  `starship`/`zoxide init powershell` (also correct — this file previously, and
  incorrectly, had all three calling `pwsh`).
- `run_once_windows_set-executionpolicy.ps1.tmpl` — runs once ever, sets
  `ExecutionPolicy=RemoteSigned` for `CurrentUser` directly via the registry (see
  ground rule 14 for why not via the `Set-ExecutionPolicy` cmdlet). Without this,
  neither PowerShell profile above can auto-load on a machine with the default
  policy.
- `private_dot_ssh/config.tmpl` → `~/.ssh/config` — generates `Host <provider>-<user>`
  aliases used by the git URL-rewrite system in `dot_gitconfig.tmpl`.

## Procedure

1. **Get repo access.** Private repo — use `gh auth status` if a session exists,
   otherwise ask the user how to authenticate. Never reuse a token pasted in chat;
   treat it as burned and get a fresh credential.
2. **Read `install.ps1` and `run_onchange_install_packages.ps1.tmpl`** in full
   before running anything — re-fetch current content, it will have changed since
   this doc was written (see "What's already fixed" above for the current
   baseline).
3. **Confirm install scope and elevation with the user** before running (core-only
   vs. full; confirm the shell is already elevated if doing a full install, per
   ground rule 2).
4. **Run the install**, capturing full output to a log file — don't rely on
   scrollback, and remember the PATH-refresh and `2>&1`-avoidance rules above.
5. **Verify real end state**, not just the exit code:
   - `chezmoi status` — should be empty (no drift).
   - `chezmoi doctor` — review warnings, not just errors.
   - For every package/app the config says should be installed, check it's
     actually there (`Get-Command`, `Test-Path` to the real binary, `choco list
     --exact <name>` — remembering the flag itself changed between Chocolatey
     versions, so verify current syntax rather than copying old commands blind).
   - Open a fresh Windows PowerShell 5.1 session *and* a fresh PowerShell 7
     session — **without** `-ExecutionPolicy Bypass`, matching what a real user
     actually gets — and confirm neither errors on profile load (ground rules 10
     and 11).
   - Check the actual `ExecutionPolicy` registry value, not just that a script
     claimed to set it (ground rule 14).
   - If you need to inspect a `chezmoi apply` diff, don't reach for `-v` in an
     automated/background run (ground rule 13) — read `chezmoi diff` output
     captured to a file instead, or run `-v` only in a session you're watching
     live.
6. **For every failure or discrepancy found:**
   - Reproduce it directly (re-run the specific failing command standalone) to get
     the actual error text.
   - Diagnose root cause — see "The exit-code lesson" above for the most common
     shape this takes in this repo specifically.
   - Categorize: genuine repo bug (fix it) vs. transient/upstream issue (report,
     don't touch, explain why).
   - Apply the smallest correct fix. Re-run to verify it resolves the original
     symptom end-to-end — don't consider it fixed until you've reproduced success.
7. **Check for drift you may have introduced** (ground rule 8) — run
   `chezmoi status` again after any manual side steps and resolve unexpected drift
   before concluding.
8. **Before committing:** stage only the files you intended to change, review the
   full diff, and write a commit message via `git commit -F <file>` (ground rule 6)
   explaining *why* (root cause), not just *what*.
9. **Before pushing: stop and confirm with the user.** Show them the diff and your
   findings first — don't push on your own initiative just because tests passed
   locally.
10. **Report back** in a structured summary:
    - What was verified working, with how you verified it.
    - Real bugs found, root cause, fix applied, and how the fix was verified.
    - Things that looked broken but weren't (false leads ruled out).
    - Known issues left unfixed, and why.
    - Any credentials, drift, or side effects you introduced and how you cleaned
      them up.
