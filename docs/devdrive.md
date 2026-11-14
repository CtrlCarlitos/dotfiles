# `dot devdrive` — create and measure a Windows Dev Drive

The systematic half of the Defender story (issue #227); [`dot devtmp`](devtmp.md)
is the quick win. A Dev Drive is a ReFS volume for which Defender uses
performance (asynchronous) scanning — no per-path exclusions needed. `dot
devdrive` can create one (partition route), and measure what Defender's scans
cost on your machine. Windows only; reached from both PowerShell profiles.

| Command | What it does |
|---|---|
| `dot devdrive` (or `dot devdrive plan`) | Status of every volume (trusted Dev Drive / ReFS-maybe / plain) and what `create` would do. No admin. |
| `dot devdrive create [-SizeGB N] [-Letter X] [-FromDrive C]` | **Admin.** Shrinks the source partition online by N GB (default 100), creates one partition in the freed space, formats it as a Dev Drive, trusts it. `-WhatIf` shows the plan; every step is behind `ShouldProcess`. |
| `dot devdrive measure [-Seconds N]` | **Admin.** Generates a Go bench module, records a Defender trace while it loops through `dot devtmp run`, writes `devdrive-report.txt`. Needs `[data.devtmp]` configured first. |

## Safety

- The shrink is the same operation as Disk Management's "Shrink Volume":
  online, metadata-only, **touches no file**. `Format-Volume` wipes only the
  brand-new partition. If unmovable files limit the shrink, `create` refuses
  with the reclaimable number instead of guessing.
- The partition route only: no VHDX is mounted and no Windows feature is
  enabled (`tests/devdrive_contract.sh` forbids both).
- **Defender preferences are never changed here.** If `measure` finds path
  exclusions it prints the matching `Remove-MpPreference` line for you to run
  (or not) from an admin shell — the same rule `dot devtmp` follows.
  Recordings and reports are diagnostics, not protection changes.
- Revert: delete the partition (Disk Management) and extend the source back —
  again metadata-only.

## What belongs on it

The same contract as `devtmp` - build and test output only: `GOCACHE`,
`GOTMPDIR` (through `[data.devtmp] path = "V:/dev/tmp"` + `dot devtmp apply`),
and optionally your repository checkouts. `GOMODCACHE` is downloaded code -
fine on a Dev Drive (it is still scanned, asynchronously), but never inside an
*excluded* folder.

## The measured trade-off

Performance mode **reschedules the scans, it does not remove them.** Measured
on cm01 (2026-11-14, the same `go test` workload as [devtmp.md section 5](devtmp.md#5-measuring-it)):
scan totals on a trusted Dev Drive matched the unexcluded `%TEMP%` baseline
almost exactly (`go.exe` 1,956 s vs 1,991 s per ~2-minute window), while wall
clock sat between the two setups — 2.5 s per pass versus 3.3 s plain and 0.9 s
with an excluded folder. A native partition measured slightly faster than a
VHDX on the same disk.

In short: **an excluded folder is the faster setup, a Dev Drive the safer
one.** An exclusion on top of a Dev Drive buys nothing and reduces protection,
which is why `dot devtmp` stops printing the exclusion command on a trusted
Dev Drive.
