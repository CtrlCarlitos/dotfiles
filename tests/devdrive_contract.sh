#!/usr/bin/env bash
set -euo pipefail

# `dot devdrive` contract (issue #227 follow-up): both PowerShell profiles
# carry the arm and the help row, the zsh dispatcher does not (Windows-only,
# invariant 10's exception), the docs page exists and is linked, the script
# never runs a Defender preference change (printed text only, the devtmp
# rule), never mounts a VHDX or enables Windows features (the partition
# route), and CI runs the .ps1 twin on both hosts (invariant 7).
# Behavior of the helpers and of Invoke-DevDrive: tests/devdrive.ps1.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

script="$repo_root/scripts/devdrive.ps1"
[ -f "$script" ] || fail "$script missing"

# --- wiring: both profiles, not zsh.
ps1_profile="$repo_root/Documents/PowerShell/Microsoft.PowerShell_profile.ps1"
ps1_profile5="$repo_root/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"
for f in "$ps1_profile" "$ps1_profile5"; do
    grep -Fq "'devdrive' { & (Join-Path \$repoScripts 'devdrive.ps1') @rest }" "$f" ||
        fail "$f: no dot devdrive arm"
    grep -Fq "'dot devdrive', 'Windows Dev Drive: plan/create/measure Defender cost'" "$f" ||
        fail "$f: dot help lacks the devdrive row"
done
if grep -Fq 'devdrive' "$repo_root/dot_aliases.zsh"; then
    fail 'dot_aliases.zsh: devdrive is Windows-only, no zsh arm'
fi

# --- the Defender rule, devtmp-style: preference changes are PRINTED text.
# Remove-MpPreference may appear only as a string assigned for printing.
require "$script" '$exclusionNote = '
forbid "$script" 'Add-MpPreference'
forbid "$script" 'Set-MpPreference'
if grep -nE '^[[:space:]]*Remove-MpPreference' "$script"; then
    fail "$script: Remove-MpPreference must be printed text, never a statement"
fi
if grep -nE '[&.|;(][[:space:]]*Remove-MpPreference' "$script"; then
    fail "$script: Remove-MpPreference must never be invoked (call operator, dot, pipe or subexpression)"
fi
forbid "$script" '-Verb RunAs'

# --- the partition route only: no VHDX mounting, no Windows features, no
# formatting of anything but the partition this script just created.
forbid "$script" 'New-VHD'
forbid "$script" 'Mount-VHD'
forbid "$script" 'Mount-DiskImage'
forbid "$script" 'Dismount-DiskImage'
forbid "$script" 'Enable-WindowsOptionalFeature'

# --- the flow exists: the shrink guard, the trust step, the measurement.
require "$script" 'Get-PartitionSupportedSize'
require "$script" 'devdrv trust'
require "$script" 'New-MpPerformanceRecording'
require "$script" 'Get-MpPerformanceReport'

# --- CI runs the behavioral twin on both PowerShell hosts (invariant 7:
# the bash runner does not enumerate tests/*.ps1).
ci="$repo_root/.github/workflows/ci.yml"
require "$ci" 'Test dot devdrive (pwsh)'
require "$ci" 'Test dot devdrive (5.1)'

# --- docs: the page exists, states the rules, and is linked.
doc="$repo_root/docs/devdrive.md"
[ -f "$doc" ] || fail "$doc missing"
require "$doc" 'build and test output only'
require "$doc" 'admin shell'
require "$doc" 'reschedules the scans, it does not remove them'
require "$doc" 'dot devdrive'
require "$repo_root/docs/README.md" '(devdrive.md)'
require "$repo_root/docs/devtmp.md" 'devdrive.md'

finish
