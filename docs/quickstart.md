# Quickstart

Ten minutes from a fresh machine to a working environment. Everything here is
the short version — the deep tables live in the [reference docs](#where-to-go-next)
and are worth reading later, not now.

---

## 1. Install

**Linux / macOS / WSL / Devcontainer**

```sh
sh -c "$(curl -fsLS https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.sh)"
```

**Windows — PowerShell, as Administrator**

```powershell
iex "& {$(irm https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1)}"
```

You confirm once, then a menu appears. Pick what you want, press Enter, and the
packages install and the dotfiles apply.

**One caveat per platform, and only one:**

| Platform | The thing that catches people |
|---|---|
| **Windows** | Must be an **elevated** PowerShell. Package managers cannot install machine-wide otherwise. |
| **WSL** | Turn on Docker Desktop's WSL integration *before* installing if you want Docker — Settings → Resources → WSL Integration → toggle your distro on, then restart the terminal. |
| **macOS** | If Homebrew is not installed yet, the installer gets it first. Expect a password prompt. |
| **Devcontainer** | Nothing to do. It detects the container (via `DEVCONTAINER`/`REMOTE_CONTAINERS` or `/.dockerenv`) and installs **no packages at all** — config only. |

Not sure what to select? Take **standard**. You can change any of it later
(step 3), and nothing here is one-way.

---

## 2. What you just got

Five things, not a matrix:

- **A shell that tells you where you are** — zsh (or PowerShell on Windows) with
  the starship prompt: git branch, dirty state, language versions, exit codes.
- **Modern CLI tools** — `bat` for `cat`, `eza` for `ls`, `rg` for `grep`,
  `fzf` for fuzzy-finding. The old names still work.
- **Git identity per folder** — different name, email and signing key for work
  and personal repos, chosen by which directory you are in. No more committing
  from the wrong account.
- **AI coding agents** — whichever you picked: `claude`, `codex`, `opencode`,
  `agy`. Same keys and the same colours in every terminal.
- **Guardrails** — if you enabled `guardrail`, destructive commands and secret
  access are blocked deterministically rather than left to an agent's judgement.

---

## 3. The commands you will actually use

```sh
dot up          # sync: pull the repo, apply changes. Never upgrades packages.
dot upgrade     # upgrade ALL tooling (apt/brew + AI CLIs). The only thing that does.
dot doctor      # health check: config parses, keys present, versions match the pins
devprofile      # which git identity is active in this folder?  (alias: dp)
```

`dot up` and `dot upgrade` are deliberately separate. Syncing your dotfiles
should never quietly upgrade your compiler.

`dot` with no arguments lists the family — it also has `backup` and `restore`.

---

## 4. Your first ten minutes

Do these in order. Each one either works or tells you something useful.

**1. Open a new terminal.** It has to be new — the shell configuration is read at
startup. You should see the starship prompt with icons.

> **Boxes or question marks instead of icons?** The font. Set your terminal to
> **MesloLGS Nerd Font Mono**. Windows Terminal and Ghostty are configured for
> you; other terminals need it set by hand once.

**2. Check the dotfiles agree with themselves:**

```sh
dot doctor
```

Expect `no errors`. Anything else prints the specific check that failed and what
to do about it.

**3. Confirm your git identity switches by folder:**

```sh
cd ~/some/work/project && git config user.email
cd ~/some/personal/project && git config user.email
```

Two different addresses means it is working. If you have not set up identities
yet, `devprofile init` walks through it — see [devprofile](devprofile.md).

**4. Run an agent** in any project directory:

```sh
claude          # or: codex, opencode, agy
```

In Windows Terminal or Ghostty, `Ctrl+Alt+C` / `X` / `O` / `A` launch them in the
focused pane; add `Shift` to open one in a new split.

**5. Learn the one chord worth knowing now:** `Ctrl+U` clears the input box in all
four agent CLIs. `Esc` stops a running response. Full table in
[Terminal Experience](terminal.md).

---

## 5. When something looks wrong

| Symptom | First thing to try |
|---|---|
| Prompt has boxes instead of icons | Set the terminal font to a Nerd Font (above) |
| A command is "not found" right after installing | Open a new terminal; `PATH` is set at startup |
| Git commits from the wrong account | `devprofile` — it prints which identity the folder resolves to and why |
| Anything else | `dot doctor` first; it names the failing check |

---

## Where to go next

Read these when you need them, not now:

- [Package Groups](package-groups.md) — the 16 groups, what each installs, how to change your selection
- [Terminal Experience](terminal.md) — keys, colours, clipboard, SSH host tabs
- [devprofile](devprofile.md) — multi-account git identities, SSH keys, commit signing
- [SSH Agents](ssh-agents.md) — where private keys live and how containers borrow them
- [Backup & Restore](backup-restore.md) — encrypted portable backups
- [Invariants](invariants.md) — read this before changing templates, ignores or tests
