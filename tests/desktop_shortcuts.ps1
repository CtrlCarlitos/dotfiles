#Requires -Version 5.1
<#
Behavioral test for the `dot upgrade` desktop-shortcut cleanup helpers in
scripts/lib/ps-common.ps1: the config switch ([data.upgrade] desktop_shortcuts),
the snapshot-then-delete-new logic, and Get-DesktopShortcutBaseline's
persisted-across-runs snapshot. Runs on any pwsh: the real Desktop is never
touched, the helpers are pointed at scratch directories (and $env:USERPROFILE
at a scratch state root for the baseline persistence case).
#>
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'scripts/lib/ps-common.ps1')

function Fail([string]$m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("desktop-sc-" + [IO.Path]::GetRandomFileName())
$user = Join-Path $Tmp 'Desktop'
$public = Join-Path $Tmp 'Public'
New-Item -ItemType Directory -Force -Path $user, $public | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- [1] Config switch: only an explicit `false` under [data.upgrade] counts.
function Get-ScratchConfig([string]$Body) {
    $p = Join-Path $Tmp ([IO.Path]::GetRandomFileName() + '.toml')
    [IO.File]::WriteAllText($p, $Body, $Utf8NoBom)
    return $p
}
$cases = @(
    @{ Name = 'false under [data.upgrade]';        Body = "[data]`n  [data.upgrade]`n    desktop_shortcuts = false`n"; Want = $true },
    @{ Name = 'false with trailing comment';        Body = "[data.upgrade]`ndesktop_shortcuts = false # no icons`n"; Want = $true },
    @{ Name = 'true';                               Body = "[data.upgrade]`ndesktop_shortcuts = true`n"; Want = $false },
    @{ Name = 'absent table';                       Body = "[data.packages]`ncore = true`n"; Want = $false },
    @{ Name = 'commented-out example';              Body = "# [data.upgrade]`n#   desktop_shortcuts = false`n"; Want = $false },
    @{ Name = 'false in a different table';         Body = "[data.packages]`ndesktop_shortcuts = false`n[data.upgrade]`nother = 1`n"; Want = $false }
)
foreach ($c in $cases) {
    $got = [bool](Test-DesktopShortcutsDisabled -ConfigPath (Get-ScratchConfig $c.Body))
    if ($got -ne $c.Want) { Fail "[1] $($c.Name): expected $($c.Want), got $got" }
}
if (Test-DesktopShortcutsDisabled -ConfigPath (Join-Path $Tmp 'missing.toml')) { Fail '[1] a missing config must mean "leave shortcuts alone"' }
Write-Host '  ok: desktop_shortcuts = false is honored only when explicit'

# --- [2] Snapshot + cleanup: only NEW shortcuts go; old ones and non-shortcuts stay.
Set-Content -LiteralPath (Join-Path $user 'Mine.lnk') -Value 'keep' -Encoding ascii
Set-Content -LiteralPath (Join-Path $public 'OldPublic.lnk') -Value 'keep' -Encoding ascii
$dirs = @($user, $public)
$before = @(Get-DesktopShortcut -Directory $dirs)
if ($before.Count -ne 2) { Fail "[2] snapshot expected 2 shortcuts, got $($before.Count)" }

Set-Content -LiteralPath (Join-Path $user 'NewApp.lnk') -Value 'new' -Encoding ascii
Set-Content -LiteralPath (Join-Path $public 'NewTool.url') -Value 'new' -Encoding ascii
Set-Content -LiteralPath (Join-Path $user 'notes.txt') -Value 'not a shortcut' -Encoding ascii

$removed = @(Remove-NewDesktopShortcut -Before $before -Directory $dirs)
if ($removed.Count -ne 2) { Fail "[2] expected 2 removals, got $($removed.Count): $($removed -join ', ')" }
foreach ($gone in @('NewApp.lnk')) { if (Test-Path -LiteralPath (Join-Path $user $gone)) { Fail "[2] $gone was not removed" } }
if (Test-Path -LiteralPath (Join-Path $public 'NewTool.url')) { Fail '[2] NewTool.url was not removed' }
foreach ($kept in @((Join-Path $user 'Mine.lnk'), (Join-Path $public 'OldPublic.lnk'), (Join-Path $user 'notes.txt'))) {
    if (-not (Test-Path -LiteralPath $kept)) { Fail "[2] pre-existing file was removed: $kept" }
}
Write-Host '  ok: only shortcuts created since the snapshot are removed'

# --- [3] Nothing new, nothing removed.
$none = @(Remove-NewDesktopShortcut -Before @(Get-DesktopShortcut -Directory $dirs) -Directory $dirs)
if ($none.Count -ne 0) { Fail "[3] removed shortcuts when nothing was new: $($none -join ', ')" }
Write-Host '  ok: a no-op upgrade removes nothing'

Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue

# --- [4] Get-DesktopShortcutBaseline persists the FIRST snapshot across calls/runs, unlike a
# fresh Get-DesktopShortcut call: a shortcut dropped before the feature's first-ever run (the
# original one-time bootstrap, a crashed run, or a manual install between two monitored runs)
# must still be "new" relative to it, not baked in as pre-existing forever. Confirmed live,
# 2026-10-10: Geany, VLC, Antigravity and Termius, all dropped by this repo's own original
# bootstrap, survived every `dot up`/`dot upgrade` sweep since, because each run's own
# before/after window never witnessed them appear.
$Tmp4 = Join-Path ([IO.Path]::GetTempPath()) ("desktop-sc-baseline-" + [IO.Path]::GetRandomFileName())
$user4 = Join-Path $Tmp4 'Desktop'
$public4 = Join-Path $Tmp4 'Public'
New-Item -ItemType Directory -Force -Path $user4, $public4 | Out-Null
$dirs4 = @($user4, $public4)
$prevUserProfile = $env:USERPROFILE
$env:USERPROFILE = $Tmp4

# A shortcut from "before this machine ever ran the feature" - the historical case itself.
Set-Content -LiteralPath (Join-Path $user4 'FromOldBootstrap.lnk') -Value 'old' -Encoding ascii

$baseline = @(Get-DesktopShortcutBaseline -Directory $dirs4)
if ($baseline.Count -ne 1) { Fail "[4] first call expected to capture the 1 pre-existing shortcut as baseline, got $($baseline.Count)" }
$statePath = Join-Path $Tmp4 '.local\state\dotfiles\desktop-shortcuts-baseline.txt'
if (-not (Test-Path -LiteralPath $statePath)) { Fail '[4] the baseline was not persisted to state' }

# A shortcut appearing AFTER the baseline was captured (simulating a later install) is still new.
Set-Content -LiteralPath (Join-Path $public4 'NewSinceBaseline.lnk') -Value 'new' -Encoding ascii
$removed4 = @(Remove-NewDesktopShortcut -Before (Get-DesktopShortcutBaseline -Directory $dirs4) -Directory $dirs4)
if ($removed4.Count -ne 1 -or $removed4[0] -notmatch 'NewSinceBaseline\.lnk$') {
    Fail "[4] expected only NewSinceBaseline.lnk removed, got: $($removed4 -join ', ')"
}
if (-not (Test-Path -LiteralPath (Join-Path $user4 'FromOldBootstrap.lnk'))) {
    Fail '[4] the historical pre-baseline shortcut must still be kept, not swept'
}

# A SECOND call, with the live Desktop now looking exactly like it did before the baseline was
# ever captured (FromOldBootstrap.lnk still there, NewSinceBaseline.lnk gone): a fresh
# Get-DesktopShortcut call here would wrongly re-adopt this as the new baseline. The persisted
# one must come back unchanged.
$baseline2 = @(Get-DesktopShortcutBaseline -Directory $dirs4)
if (@(Compare-Object $baseline $baseline2).Count -ne 0) { Fail '[4] a second call must return the SAME persisted baseline, not re-snapshot' }

$env:USERPROFILE = $prevUserProfile
Remove-Item -Recurse -Force $Tmp4 -ErrorAction SilentlyContinue
Write-Host '  ok: the baseline is captured once and persists across calls/runs'

# --- [5] Zero shortcuts anywhere: Windows PowerShell 5.1 collapses an if/else statement's
# output to $null, not an empty array, when the executed branch emits exactly one object and
# that object is itself a zero-length array - confirmed live, 2026-10-09, after a Desktop and
# Public Desktop both had every shortcut swept down to none: Get-DesktopShortcutBaseline's
# $current = if (...) {@(Get-DesktopShortcut ...)} else {...} came back $null and
# WriteAllLines($path, $null) threw "Value cannot be null". pwsh does not have this quirk, so a
# test suite run only under pwsh would never catch it. Both functions must come back an empty
# array, never $null, when nothing is there to find.
$Tmp5 = Join-Path ([IO.Path]::GetTempPath()) ("desktop-sc-empty-" + [IO.Path]::GetRandomFileName())
$user5 = Join-Path $Tmp5 'Desktop'
$public5 = Join-Path $Tmp5 'Public'
New-Item -ItemType Directory -Force -Path $user5, $public5 | Out-Null
$dirs5 = @($user5, $public5)
$prevUserProfile5 = $env:USERPROFILE
$env:USERPROFILE = $Tmp5

$baseline5 = @(Get-DesktopShortcutBaseline -Directory $dirs5)
if ($null -eq $baseline5) { Fail '[5] Get-DesktopShortcutBaseline must return an empty array, not $null, when nothing is on the Desktop' }
if ($baseline5.Count -ne 0) { Fail "[5] expected an empty baseline, got $($baseline5.Count)" }

$removed5 = @(Remove-NewDesktopShortcut -Before $baseline5 -Directory $dirs5)
if ($null -eq $removed5) { Fail '[5] Remove-NewDesktopShortcut must return an empty array, not $null, when nothing is new' }
if ($removed5.Count -ne 0) { Fail "[5] expected nothing removed, got $($removed5.Count)" }

$env:USERPROFILE = $prevUserProfile5
Remove-Item -Recurse -Force $Tmp5 -ErrorAction SilentlyContinue
Write-Host '  ok: zero shortcuts anywhere comes back as an empty array, not $null'

Write-Host 'PASS: desktop_shortcuts.ps1'
exit 0
