#Requires -Version 5.1
<#
Behavioral test for the `dot upgrade` desktop-shortcut cleanup helpers in
scripts/lib/ps-common.ps1: the config switch ([data.upgrade] desktop_shortcuts)
and the snapshot-then-delete-new logic. Runs on any pwsh: the real Desktop is
never touched, the helpers are pointed at scratch directories.
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
function New-Config([string]$Body) {
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
    $got = [bool](Test-DesktopShortcutsDisabled -ConfigPath (New-Config $c.Body))
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
Write-Host 'PASS: desktop_shortcuts.ps1'
exit 0
