# Install logs

Every installer run can keep a full log you can follow live from another terminal, and the console
can be told to stop hiding output. Both are two settings in `~/.config/chezmoi/chezmoi.toml`:

```toml
[data.logging]
  log     = true    # default: every run writes a live log (newest 20 kept)
  verbose = false   # true: the console also shows what it normally hides
```

For one run, without editing the file, set `DOT_LOG=0` or `DOT_LOG=1`, and `DOT_VERBOSE=1`, in the
environment. The environment wins, then the config, then the defaults above. Both are read when the
installer runs, not rendered into it, so changing them never makes `dot up` re-run the package install.

## Where the logs are

`~/.local/state/dotfiles/logs/` (on Windows `%USERPROFILE%\.local\state\dotfiles\logs\`), one file
per run, named after the script and its start time:

| File | Written by |
| --- | --- |
| `install-<time>.log` | `install.ps1` / `install.sh` (the one-liner) |
| `dot-up-<time>.log` | the package installer (`dot up`, and the apply the one-liner starts) |

The git identity script prints a few lines and keeps no log of its own; on Unix and WSL the
one-liner's `install-<time>.log` holds them, as it holds the whole apply.

Each installer prints `Live log: <path>` as it starts. Follow one while it runs:

```powershell
Get-Content -Wait (Get-ChildItem $HOME\.local\state\dotfiles\logs\*.log | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
```

```sh
tail -f "$(ls -1t ~/.local/state/dotfiles/logs/*.log | head -n 1)"
```

The package managers' boilerplate lines that `dot up` hides stay in `~/.local/state/dotfiles/install.log`
(Windows), as before.

## What a log holds

- **Unix and WSL** (`install.sh`, the `.sh` installers): everything the run prints, stdout and stderr,
  tee'd as it happens. `install.sh` starts its log after the package menu (gum's screen needs the
  terminal itself).
- **Windows**: a PowerShell transcript - every line PowerShell writes (the installer's own lines,
  questions and their answers, the package-manager lines the console shows). A native tool that
  writes straight to the console is not in it; `install.ps1` pipes its winget and Chocolatey
  installs through `Out-Host` so they are.
  Windows PowerShell 5.1's transcript also records a native tool's stderr that the script captured
  or discarded (`2>&1` into a variable, `*> $null`), as a `NativeCommandError` block the console
  never showed. `dot-up-*.log` has two of these: `wsl.exe --status` / `--version` on a box without
  WSL yet, and the mobile_dev JDK probe's whole `java -XshowSettings:properties` dump. They are
  not failures; the console and the parsed result are unaffected (verified on 5.1, 2026-10-24).

## verbose

`verbose = true` (or `DOT_VERBOSE=1`) turns on, for that run, the switches that each hide one kind of
output: the package-manager noise filter (Windows), apt's output (`DOT_APT_VERBOSE`), guardrail's
routine status lines (`DOT_GUARDRAIL_VERBOSE`) and the skills CLI (`DOT_SKILLS_VERBOSE`). Each of
those still works on its own.

Contract: `tests/install_logging_contract.sh` runs the bash and PowerShell helpers and `install.sh`'s
own copy, and checks that no installer template reads these settings at render time.
