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

# --- [5] Invoke-DevTmp. Every side effect is a seam; Add-MpPreference is a
# recording trap that must NEVER be hit (the dotfiles never run a Defender change).
$env:DEVTMP_NO_MAIN = '1'
. (Join-Path $RepoRoot 'scripts/devtmp.ps1')
$script:calls = New-Object System.Collections.Generic.List[string]
function Add-MpPreference { $script:calls.Add("Add-MpPreference $($args -join ' ')") }
function Set-MpPreference { [CmdletBinding(SupportsShouldProcess)] param() if ($PSCmdlet.ShouldProcess('defender')) { $script:calls.Add('Set-MpPreference') } }
function Get-GoTmpDir { 'C:\old\gotmp' }
function Set-GoTmpDir { [CmdletBinding(SupportsShouldProcess)] param([string]$Path) if ($PSCmdlet.ShouldProcess($Path)) { $script:calls.Add("Set-GoTmpDir $Path") } }
function New-DevTmpDirectory { [CmdletBinding(SupportsShouldProcess)] param([string]$Path) if ($PSCmdlet.ShouldProcess($Path)) { $script:calls.Add("New-DevTmpDirectory $Path") } }

$cfgBody = "[data]`n  [data.devtmp]`n    path = `"C:/dev/tmp`"`n[[data.accounts]]`n  dirs = [`"projects/personal`"]`n"
$cfg = Get-ScratchConfig $cfgBody
function Invoke-Dt([string[]]$Cmd, [string]$Config = $cfg) {
    $script:calls.Clear()
    $global:LASTEXITCODE = $null
    $out = & { Invoke-DevTmp -Arguments $Cmd -ConfigPath $Config -HomeDir 'C:\Users\u' -TempDir 'C:\Users\u\AppData\Local\Temp' } *>&1 | Out-String
    return $out
}

# plan (also the default): prints, changes nothing, exit 0.
foreach ($args_ in @(@(), @('plan'))) {
    $out = Invoke-Dt $args_
    if ($global:LASTEXITCODE -ne 0) { Fail "[5] plan exit code $global:LASTEXITCODE" }
    if ($script:calls.Count -ne 0) { Fail "[5] plan must change nothing, did: $($script:calls -join '; ')" }
    if ($out -notmatch [regex]::Escape("Add-MpPreference -ExclusionPath 'C:\dev\tmp'")) { Fail "[5] plan must print the exclusion command, got:`n$out" }
    if ($out -notmatch 'ADMIN') { Fail '[5] plan must say the exclusion is run from an admin shell' }
    if ($out -notmatch [regex]::Escape('C:\old\gotmp')) { Fail '[5] plan must show the current GOTMPDIR' }
}
Write-Host '  ok: plan prints the plan and the admin command, changes nothing'

# apply: creates the folder and sets GOTMPDIR, still only PRINTS the exclusion.
$out = Invoke-Dt @('apply')
if ($global:LASTEXITCODE -ne 0) { Fail "[5] apply exit code $global:LASTEXITCODE" }
if (($script:calls -join '; ') -ne 'New-DevTmpDirectory C:\dev\tmp; Set-GoTmpDir C:\dev\tmp') { Fail "[5] apply calls: $($script:calls -join '; ')" }
if ($script:calls -match 'MpPreference') { Fail '[5] apply must NEVER run a Defender change' }
if ($out -notmatch [regex]::Escape("Add-MpPreference -ExclusionPath 'C:\dev\tmp'")) { Fail '[5] apply must still print the exclusion command' }
Write-Host '  ok: apply sets up the folder and GOTMPDIR; the exclusion is only printed'

# Review Focus 3: nothing configured -> one helpful line, exit 1, no side effects.
foreach ($bad in @((Join-Path $Tmp 'missing.toml'), (Get-ScratchConfig "[data.packages]`ncore = true`n"), (Get-ScratchConfig "[data.devtmp]`npath = `"`"`n"))) {
    foreach ($sub in 'plan', 'apply') {
        $out = Invoke-Dt @($sub) $bad
        if ($global:LASTEXITCODE -ne 1) { Fail "[5] unconfigured $sub must exit 1, got $global:LASTEXITCODE" }
        if ($out -notmatch 'data\.devtmp') { Fail "[5] unconfigured $sub must name [data.devtmp], got:`n$out" }
        if ($script:calls.Count -ne 0) { Fail "[5] unconfigured $sub must change nothing" }
    }
}
Write-Host '  ok: unset or unreadable config is a one-line message and exit 1'

# Unsafe configured path: refused with the rule, nothing changed, nothing printed to paste.
foreach ($unsafe in 'C:\', 'C:\Users\u', 'C:\Users\u\AppData\Local\Temp', 'C:\Users\u\projects') {
    $c = Get-ScratchConfig "[data.devtmp]`npath = '$unsafe'`n[[data.accounts]]`ndirs = [`"projects/personal`"]`n"
    foreach ($sub in 'plan', 'apply', 'run') {
        $out = Invoke-Dt @($sub, 'whatever') $c
        if ($global:LASTEXITCODE -ne 1) { Fail "[5] unsafe '$unsafe' $sub must exit 1, got $global:LASTEXITCODE" }
        if ($script:calls.Count -ne 0) { Fail "[5] unsafe '$unsafe' $sub must change nothing" }
        if ($out -match 'Add-MpPreference') { Fail "[5] unsafe '$unsafe' $sub must not print an exclusion command" }
    }
}
Write-Host '  ok: unsafe configured paths are refused by plan, apply and run'

# Review Focus 4: a quote in the path stays one literal in the printed command.
$q = Get-ScratchConfig "[data.devtmp]`npath = `"D:/it's/tmp`"`n"
$out = Invoke-Dt @('plan') $q
if ($out -notmatch [regex]::Escape("Add-MpPreference -ExclusionPath 'D:\it''s\tmp'")) { Fail "[5] quote in path must be doubled, got:`n$out" }
Write-Host '  ok: single quotes in the path are doubled in the printed command'

# usage: unknown subcommand -> usage + exit 2, nothing changed.
$out = Invoke-Dt @('frobnicate')
if ($global:LASTEXITCODE -ne 2) { Fail "[5] unknown subcommand must exit 2, got $global:LASTEXITCODE" }
if ($out -notmatch 'usage') { Fail '[5] unknown subcommand must print usage' }
if ($script:calls.Count -ne 0) { Fail '[5] unknown subcommand must change nothing' }
$out = Invoke-Dt @('run')
if ($global:LASTEXITCODE -ne 2) { Fail "[5] run with no command must exit 2, got $global:LASTEXITCODE" }
Write-Host '  ok: unknown subcommand and bare run print usage and exit 2'

# run: child sees TMP/TEMP; the parent does not keep them (Review Focus 5).
$pwshExe = (Get-Process -Id $PID).Path
$env:TMP = 'KEEP-TMP'
$env:TEMP = 'KEEP-TEMP'
$probe = '[Console]::Out.Write([Environment]::GetEnvironmentVariable(''TMP'') + ''|'' + [Environment]::GetEnvironmentVariable(''TEMP''))'
$out = (Invoke-Dt @('run', $pwshExe, '-NoProfile', '-Command', $probe)).Trim()
if ($out -notmatch [regex]::Escape('C:\dev\tmp|C:\dev\tmp')) { Fail "[5] child must see TMP/TEMP = the folder, got '$out'" }
if ($global:LASTEXITCODE -ne 0) { Fail "[5] run success exit code $global:LASTEXITCODE" }
if ($env:TMP -ne 'KEEP-TMP' -or $env:TEMP -ne 'KEEP-TEMP') { Fail "[5] run leaked TMP/TEMP into the parent: TMP=$env:TMP TEMP=$env:TEMP" }
if (($script:calls -join '; ') -ne 'New-DevTmpDirectory C:\dev\tmp') { Fail "[5] run must only ensure the folder: $($script:calls -join '; ')" }

$null = Invoke-Dt @('run', $pwshExe, '-NoProfile', '-Command', 'exit 3')
if ($global:LASTEXITCODE -ne 3) { Fail "[5] run must surface the child's exit code 3, got $global:LASTEXITCODE" }
if ($env:TMP -ne 'KEEP-TMP' -or $env:TEMP -ne 'KEEP-TEMP') { Fail '[5] run leaked TMP/TEMP after a failing child' }

$null = Invoke-Dt @('run', 'devtmp-no-such-command-xyz')
if ($global:LASTEXITCODE -eq 0) { Fail '[5] run of a missing command must not exit 0' }
if ($env:TMP -ne 'KEEP-TMP' -or $env:TEMP -ne 'KEEP-TEMP') { Fail '[5] run leaked TMP/TEMP after a missing command' }
Write-Host '  ok: run scopes TMP/TEMP to the child, restores them, and keeps the exit code'

Remove-Item Env:\DEVTMP_NO_MAIN -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'PASS: devtmp helpers and Invoke-DevTmp' -ForegroundColor Green
