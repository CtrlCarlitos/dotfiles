# `dot devtmp` — a known folder for build and test output (Windows)

Windows Defender's `Antimalware Service Executable` can sit at 10-15% CPU during
Go development even when overall CPU and RAM look fine. `dot devtmp` puts build
and test output in one folder you choose, so Defender's cost there can be
bounded. It is Windows-only, opt-in, and never changes Defender itself.

## 1. Why

A Defender performance recording (`New-MpPerformanceRecording` then
`Get-MpPerformanceReport`) taken during a normal Go session showed the scan time
is dominated by freshly built, unsigned executables:

- Go test binaries in `%TEMP%\go-build*\...` (`*.test.exe`), one scan alone
  taking about 92 s;
- executables a test suite copies into fresh temp folders, rescanned about 1 s
  each;
- large tool binaries rescanned repeatedly.

Every `go test` produces new binaries with new hashes, so Defender rescans them
on every open.

Caveat: that recording is one session, and the numbers are scan time, not CPU.
Measure your own machine (section 5) before assuming a win.

## 2. Setup

Add the folder to `~/.config/chezmoi/chezmoi.toml`, then run `chezmoi init` so
the config template keeps it:

```toml
[data.devtmp]
  path = "C:/dev/tmp"
```

Then:

| Command | What it does |
|---|---|
| `dot devtmp` | Prints the plan. Changes nothing. |
| `dot devtmp apply` | Creates the folder and runs `go env -w GOTMPDIR=<path>` (persistent, no admin). |
| `dot devtmp run go test ./...` | Runs the command with `TMP` and `TEMP` pointed at the folder **for that process only**. |

`run` takes a **native executable** (`go`, `pwsh`, `cmd`, ...), not a PowerShell
script, cmdlet or function: their `-Named` parameters would be passed
positionally and silently mis-bound. To run a script use
`dot devtmp run pwsh -NoProfile -File <script> [args]`.

`run` exists because tests create temp directories through the standard
temp-directory call, which follows `TMP`/`TEMP`, not `GOTMPDIR`. Setting them
system-wide would move everything, so they are scoped to the one command.

### The Defender exclusion is yours to run

`dot devtmp` prints this line and **never runs it**. Copy it into an admin shell
yourself:

```powershell
Add-MpPreference -ExclusionPath 'C:\dev\tmp'
```

Defender settings are changed by you, from an admin shell. The dotfiles, and any
agent working in them, do not touch Defender.

## 3. The contract: build and test output only

Once the folder is excluded, **nothing in it is scanned**. Keep it to build and
test output only. Never put downloads, `pip`/`npm` caches or cloned repositories
there.

It is not Go-only:

- `TMP`/`TEMP` for a command covers any tool that uses the OS temp API;
- the exclusion does not care which tool wrote the file;
- `GOTMPDIR` is the one toolchain setting wired today, because Go is the only
  case measured. Others (for example `CARGO_TARGET_DIR` for Rust) are worth
  adding once someone has measured them.

## 4. What `dot devtmp` refuses

The configured path is rejected, with the reason, when it is:

- not an absolute drive path (relative, or UNC);
- a path with `*`, `?`, `%`, `<`, `>`, `|` or `"` (Defender expands wildcards and
  environment variables in an exclusion, so `C:\Users\*` would be a blanket one);
- a drive root;
- your user profile, or a parent of it;
- `%TEMP%`, or a parent of it;
- one of your `accounts[].dirs` (your source checkouts), or a parent of one.

These are the blanket exclusions you do not want: the whole drive, your whole
profile, the whole temp folder, or every repository you clone. `accounts.dirs`
exist for git identity only and are never used as an exclusion list.

Known limit: paths are compared literally. An **8.3** short-name spelling of
`%TEMP%` or your profile (for example `C:\Users\CARLIT~1`) is not recognised as
the same place, so write `path` in its long form.

## 5. Measuring it

1. From an admin shell, record during a normal `go test` run, before:
   `New-MpPerformanceRecording -RecordTo before.etl`, then
   `Get-MpPerformanceReport -Path before.etl -TopProcesses 10`.
2. Run `dot devtmp apply`, add the exclusion (section 2), and run the tests with
   `dot devtmp run go test ./...`.
3. Record again and compare the `TopProcesses` totals.

These Defender cmdlets need an admin shell, so run them yourself.

## 6. Option 2: Dev Drive (documentation only)

A Dev Drive is a ReFS volume (a VHDX, 50 GB or more, on a secondary SSD). For it
Defender uses performance (async) scanning, so no per-path exclusions are
needed.

- Move `GOCACHE`, `GOMODCACHE`, `GOTMPDIR` and ideally the repository checkouts
  onto it.
- Point `[data.devtmp] path` at a folder on it and the exclusion becomes
  unnecessary: you get the speed-up with no `Add-MpPreference`.
- Trade-offs: protection is reduced, not removed; and the VHDX must be mounted
  again after a reboot unless auto-mount is set.

The repo does not create or mount a Dev Drive.
