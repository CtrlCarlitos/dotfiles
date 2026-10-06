#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# A Windows `dot upgrade` took 13m03s and nothing said which part. Each script now marks the start
# of its sections and ends with one line - `Timings (dot upgrade, 13m03s): choco 6m10s, ...` - the
# slowest sections first, appended to ~/.local/state/dotfiles/upgrade.log so one run can be compared
# with the next. Both twins are EXECUTED against a fake clock, and the marks are checked to be wired
# into all four scripts.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# --- shell twin ------------------------------------------------------------------------------------
cat >"$tmp/sh-harness.sh" <<'EOF'
set -u
. "$1/scripts/lib/timing.sh"
fake_now=1000
dot_timing_now() { echo "$fake_now"; }
mark() { fake_now=$((fake_now + $1)); dot_timing_mark "$2"; }
dot_timing_mark 'setup'                      # t=1000
mark 3 'quick'                               # setup took 3 s  (below the 5 s floor)
mark 125 'apt'                               # quick took 125 s
mark 45 'skills'                             # apt took 45 s
mark 600 'AI tools'                          # skills took 600 s
mark 7 'tail one'
mark 30 'tail two'
mark 31 'tail three'
fake_now=$((fake_now + 9))
dot_timing_summary 'dot upgrade'
echo "second:"
dot_timing_summary 'again'                   # nothing marked since: silent
echo "after-second-done"
EOF
home="$tmp/home"
mkdir -p "$home"
out="$(HOME="$home" XDG_STATE_HOME="" bash "$tmp/sh-harness.sh" "$repo_root" 2>&1)"
want='  Timings (dot upgrade, 14m10s): skills 10m00s, quick 2m05s, apt 45s, tail two 31s, tail one 30s, tail three 9s'
printf '%s\n' "$out" | grep -Fxq "$want" || fail "shell: unexpected summary (got: $(printf '%s' "$out" | head -3))"
# the section under the floor is not listed, the total always is
if printf '%s\n' "$out" | grep -Fq 'setup'; then fail "shell: a section under 5 s must not be listed"; else pass; fi
printf '%s\n' "$out" | grep -Fxq 'after-second-done' || fail "shell: a second summary with nothing marked must stay silent and not fail"
if printf '%s\n' "$out" | sed -n '/^second:/,$p' | grep -Fq 'Timings'; then fail "shell: a second summary must print nothing"; else pass; fi
log="$home/.local/state/dotfiles/upgrade.log"
grep -Eq '^=== [0-9T:-]+ Timings \(dot upgrade, 14m10s\): skills 10m00s' "$log" || fail "shell: the summary must be appended to upgrade.log (got: $(cat "$log" 2>/dev/null))"
# the floor is configurable
out2="$(HOME="$home" DOT_TIMING_MIN_SECONDS=1 bash -c '. "$1/scripts/lib/timing.sh"; fake_now=100; dot_timing_now() { echo $fake_now; }; dot_timing_mark a; fake_now=102; dot_timing_mark b; fake_now=104; dot_timing_summary t' _ "$repo_root")"
printf '%s\n' "$out2" | grep -Fxq '  Timings (t, 4s): a 2s, b 2s' || fail "shell: DOT_TIMING_MIN_SECONDS=1 must list 2 s sections (got: $out2)"
pass

# --- PowerShell twin --------------------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Log)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib
$script:clock = [DateTime]::new(2026, 10, 5, 12, 0, 0, [DateTimeKind]::Utc)
function Get-DotTimingNow { return $script:clock }
function Step([int]$Seconds, [string]$Name) { $script:clock = $script:clock.AddSeconds($Seconds); Add-DotTimingMark -Name $Name }
function Capture([scriptblock]$Run) { (& $Run *>&1 | Out-String).Trim() }

Add-DotTimingMark -Name 'setup'
Step 3 'quick'
Step 125 'apt'
Step 45 'skills'
Step 600 'AI tools'
Step 7 'tail one'
Step 30 'tail two'
Step 31 'tail three'
$script:clock = $script:clock.AddSeconds(9)
Write-Output ('first=' + (Capture { Write-DotTimingSummary -Title 'dot upgrade' -LogPath $Log }))
Write-Output ('second=[' + (Capture { Write-DotTimingSummary -Title 'again' -LogPath $Log }) + ']')
Write-Output ('log=' + ((Get-Content -Raw -LiteralPath $Log) -match '(?m)^=== \S+ Timings \(dot upgrade, 14m10s\): skills 10m00s'))
$env:DOT_TIMING_MIN_SECONDS = '1'
Add-DotTimingMark -Name 'a'
Step 2 'b'
$script:clock = $script:clock.AddSeconds(2)
Write-Output ('floor=' + (Capture { Write-DotTimingSummary -Title 't' -LogPath $Log }))
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" -Log "$(winpath "$tmp/ps.log")" 2>&1 | tr -d '\r' || true)"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400))"; }
    expect 'first=Timings (dot upgrade, 14m10s): skills 10m00s, quick 2m05s, apt 45s, tail two 31s, tail one 30s, tail three 9s'
    expect 'second=[]'
    expect 'log=True'
    expect 'floor=Timings (t, 4s): a 2s, b 2s'
    pass
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

# --- wiring: marks in all four scripts, and every script ends with a summary ---------------------------
count() { grep -cE "$2" "$repo_root/$1" || true; }
for f in scripts/dotupgrade.sh scripts/update_ai_tools.sh; do
    [ "$(count "$f" '^dot_timing_mark ')" -ge 4 ] || fail "$f: expected a mark at each section (found $(count "$f" '^dot_timing_mark '))"
    [ "$(count "$f" '^dot_timing_summary ')" = 1 ] || fail "$f: expected exactly one summary"
done
for f in scripts/dotupgrade.ps1 scripts/update_ai_tools.ps1; do
    [ "$(count "$f" '^Add-DotTimingMark ')" -ge 5 ] || fail "$f: expected a mark at each section (found $(count "$f" '^Add-DotTimingMark '))"
    [ "$(count "$f" '^Write-DotTimingSummary ')" = 1 ] || fail "$f: expected exactly one summary"
done
grep -Fq 'lib/timing.sh' "$repo_root/scripts/dotupgrade.sh" || fail "dotupgrade.sh must source lib/timing.sh"
grep -Fq 'lib/timing.sh' "$repo_root/scripts/update_ai_tools.sh" || fail "update_ai_tools.sh must source lib/timing.sh"
pass

finish
