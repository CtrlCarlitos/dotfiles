#Requires -Version 5.1
<#
Behavioral test for `dot devtmp` (#227): the pure helpers in
scripts/lib/ps-common.ps1 and Invoke-DevTmp in scripts/devtmp.ps1. Runs on any
pwsh and on Windows PowerShell 5.1. Windows paths are only ever handled as
STRINGS here, so the verdict is the same on the Linux CI runner; nothing
touches the real config, Defender, Go, or disk.
#>
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'scripts/lib/ps-common.ps1')

function Fail([string]$m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("devtmp-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Get-ScratchConfig([string]$Body) {
    $p = Join-Path $Tmp ([IO.Path]::GetRandomFileName() + '.toml')
    [IO.File]::WriteAllText($p, $Body, $Utf8NoBom)
    return $p
}

# --- [1] Get-DevTmpPath: only `path` under a live [data.devtmp] counts.
$cases = @(
    @{ Name = 'forward slashes';       Body = "[data]`n  [data.devtmp]`n    path = `"C:/dev/tmp`"`n"; Want = 'C:/dev/tmp' },
    @{ Name = 'escaped backslashes';   Body = "[data.devtmp]`npath = `"C:\\dev\\tmp`"`n";            Want = 'C:\dev\tmp' },
    @{ Name = 'literal string';        Body = "[data.devtmp]`npath = 'C:\dev\tmp'`n";                Want = 'C:\dev\tmp' },
    @{ Name = 'trailing comment';      Body = "[data.devtmp]`npath = `"C:/dev/tmp`" # build`n";      Want = 'C:/dev/tmp' },
    @{ Name = 'commented-out example'; Body = "# [data.devtmp]`n#   path = `"C:/dev/tmp`"`n";        Want = $null },
    @{ Name = 'path in other table';   Body = "[data.packages]`npath = `"C:/x`"`n[data.devtmp]`nother = 1`n"; Want = $null },
    @{ Name = 'empty path';            Body = "[data.devtmp]`npath = `"`"`n";                        Want = $null },
    @{ Name = 'absent table';          Body = "[data.packages]`ncore = true`n";                      Want = $null }
)
foreach ($c in $cases) {
    $got = Get-DevTmpPath -ConfigPath (Get-ScratchConfig $c.Body)
    if ($got -ne $c.Want) { Fail "[1] $($c.Name): expected '$($c.Want)', got '$got'" }
}
if ($null -ne (Get-DevTmpPath -ConfigPath (Join-Path $Tmp 'missing.toml'))) { Fail '[1] a missing config must yield $null' }
Write-Host '  ok: Get-DevTmpPath reads only a live [data.devtmp] path'

# --- [2] Get-AccountDir: every dirs entry of every [[data.accounts]] block.
$acct = @"
[data]
[[data.accounts]]
  name = "A"
  dirs = ["projects/personal", ".local/share/chezmoi"]
[[data.accounts]]
  name = "B"
  dirs = []
[[data.accounts]]
  name = "C"
  dirs = ["projects/work"]
[data.packages]
  dirs = ["not/an/account"]
"@
$dirs = @(Get-AccountDir -ConfigPath (Get-ScratchConfig $acct))
if (($dirs -join '|') -ne 'projects/personal|.local/share/chezmoi|projects/work') { Fail "[2] account dirs: got '$($dirs -join '|')'" }
if (@(Get-AccountDir -ConfigPath (Join-Path $Tmp 'missing.toml')).Count -ne 0) { Fail '[2] a missing config must yield no dirs' }
Write-Host '  ok: Get-AccountDir reads dirs from accounts blocks only'

# --- [3] ConvertTo-DevTmpNormalPath (Review Focus 1).
$norm = @(
    @{ In = 'C:/Dev//tmp/';           Want = 'C:\Dev\tmp' },
    @{ In = 'c:\dev\TMP';             Want = 'C:\dev\TMP' },
    @{ In = 'C:\Users\u\..';          Want = 'C:\Users' },
    @{ In = 'C:\Users\u\..\..';       Want = 'C:\' },
    @{ In = 'C:\a\.\b';               Want = 'C:\a\b' },
    @{ In = 'C:\';                    Want = 'C:\' },
    @{ In = 'C:\..\..';               Want = 'C:\' },
    @{ In = 'relative\path';          Want = $null },
    @{ In = 'C:rel';                  Want = $null },
    @{ In = '\\server\share\x';       Want = $null },
    @{ In = '';                       Want = $null }
)
foreach ($c in $norm) {
    $got = ConvertTo-DevTmpNormalPath -Path $c.In
    if ($got -ne $c.Want) { Fail "[3] normalise '$($c.In)': expected '$($c.Want)', got '$got'" }
}
Write-Host '  ok: ConvertTo-DevTmpNormalPath normalises before any rule sees the path'

# --- [4] Test-DevTmpPathSafe: the refusal rules.
$home_ = 'C:\Users\u'
$temp_ = 'C:\Users\u\AppData\Local\Temp'
$acctDirs = @('projects/personal', '.local/share/chezmoi')
function Check([string]$Name, [string]$Path, [bool]$WantSafe, [string]$WantReason) {
    $r = Test-DevTmpPathSafe -Path $Path -HomeDir $home_ -TempDir $temp_ -AccountDir $acctDirs
    if ($r.Safe -ne $WantSafe) { Fail "[4] $Name ('$Path'): Safe expected $WantSafe, got $($r.Safe) ($($r.Reason))" }
    if (-not $WantSafe -and $r.Reason -notlike "*$WantReason*") { Fail "[4] ${Name}: reason '$($r.Reason)' lacks '$WantReason'" }
}
Check 'good path'            'C:/dev/tmp'                              $true  ''
Check 'good path, backslash' 'D:\build'                                $true  ''
Check 'relative'             'dev\tmp'                                 $false 'absolute drive path'
Check 'UNC'                  '\\srv\share'                             $false 'absolute drive path'
Check 'drive root'           'C:\'                                     $false 'drive root'
Check 'drive root via ..'    'C:\dev\..'                               $false 'drive root'
Check 'temp itself'          'C:\Users\u\AppData\Local\Temp'           $false 'contains %TEMP%'
Check 'temp, other case'     'c:/users/U/appdata/local/temp/'          $false 'contains %TEMP%'
Check 'temp ancestor'        'C:\Users\u\AppData'                      $false 'contains %TEMP%'
Check 'home itself'          'C:\Users\u'                              $false 'contains your user profile'
Check 'home ancestor'        'C:\Users'                                $false 'contains your user profile'
Check '.. up to ancestor'    'C:\Users\u\x\..\..'                      $false 'contains your user profile'
Check 'account dir itself'   'C:\Users\u\projects\personal'            $false 'account directory'
Check 'account dir ancestor' 'C:\Users\u\projects'                     $false 'account directory'
Check 'chezmoi source'       'C:\Users\u\.local\share\chezmoi'         $false 'account directory'
# Review Focus 2: a sibling that only shares a string prefix is NOT an ancestor.
Check 'prefix sibling'       'C:\Users\u-dev\tmp'                      $true  ''
Check 'inside home, not acct' 'C:\Users\u\devtmp'                      $true  ''
Check 'inside an account dir' 'C:\Users\u\projects\personal\.tmp'      $true  ''
$r = Test-DevTmpPathSafe -Path 'C:/dev//tmp/' -HomeDir $home_ -TempDir $temp_
if ($r.Path -ne 'C:\dev\tmp') { Fail "[4] result must carry the normalised path, got '$($r.Path)'" }
Write-Host '  ok: Test-DevTmpPathSafe refuses blanket paths and accepts look-alikes'

Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'PASS: devtmp helpers' -ForegroundColor Green
