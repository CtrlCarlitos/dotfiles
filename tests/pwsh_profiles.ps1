#Requires -Version 5.1
<#
Tests for the managed PowerShell profiles (Documents/PowerShell = pwsh 7,
Documents/WindowsPowerShell = 5.1 twin):

  1. Both parse with zero errors ([Parser]::ParseFile).
  2. The devprofile wrapper splats @args: `devprofile use work` must reach
     devprofile.ps1's [string]$Command as 'use' - passing $args as one
     object[] failed the binding on EVERY call.
  3. `reload` is gone (dot-sourcing inside a function defines nothing that
     survives the return).
  4. The "PATH Additions" block runs in both profiles (%APPDATA%\npm and
     ~\.local\bin prepended) - the 5.1 twin shipped without it for years.
  5. The 5.1 twin no longer claims `cd -` works natively (pwsh 7-only).

Dot-sourcing runs in a child pwsh against a fixture USERPROFILE/APPDATA,
so tool init blocks (starship/zoxide/choco) no-op or import harmlessly.
#>
$ErrorActionPreference = 'Stop'

$isWin = ($env:OS -eq 'Windows_NT')
if (-not $isWin) {
    Write-Host 'SKIP: pwsh_profiles.ps1 is Windows-only (profile paths under Documents)'
    exit 0
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Profile7 = Join-Path $RepoRoot 'Documents/PowerShell/Microsoft.PowerShell_profile.ps1'
$Profile51 = Join-Path $RepoRoot 'Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Fail([string]$m) {
    Write-Host "FAIL: $m" -ForegroundColor Red
    exit 1
}

foreach ($f in @($Profile7, $Profile51)) {
    if (-not (Test-Path -LiteralPath $f)) { Fail "missing profile: $f" }
}

# --- [1] Text contract -------------------------------------------------------

foreach ($f in @($Profile7, $Profile51)) {
    $name = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($f))
    $text = [IO.File]::ReadAllText($f)
    if ($text -match 'function\s+reload') { Fail "[$name] reload must stay removed (it is a no-op inside a function scope)" }
    if (-not $text.Contains('& $ScriptPath @args')) { Fail "[$name] devprofile wrapper must splat @args" }
    if ($text.Contains('& "$ScriptPath" $args')) { Fail "[$name] devprofile wrapper still passes `$args as one array" }
    if (-not $text.Contains('PATH Additions')) { Fail "[$name] missing the PATH Additions block" }
    if (-not $text.Contains('$UserNodeModules = Join-Path $env:APPDATA "npm"')) { Fail "[$name] missing %APPDATA%\npm PATH addition" }
    if (-not $text.Contains('$LocalBin = Join-Path $env:USERPROFILE ".local\bin"')) { Fail "[$name] missing ~\.local\bin PATH addition" }
}
if (([IO.File]::ReadAllText($Profile51)) -match 'works natively in pwsh 7') {
    Fail '[5.1] still claims `cd -` works natively in pwsh 7 (false under 5.1)'
}
Write-Host '  ok: text contract (splat, no reload, PATH block, no pwsh-7-only claims)'

# --- [2] Both profiles parse with zero errors --------------------------------

foreach ($f in @($Profile7, $Profile51)) {
    $name = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($f))
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        $msgs = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
        Fail "[$name] parse errors: $msgs"
    }
}
Write-Host '  ok: both profiles parse (0 errors)'

# --- [3] Behavior: dot-source each profile in a child pwsh -------------------

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("pwsh-profiles-" + [IO.Path]::GetRandomFileName())
$homeDir = Join-Path $Tmp 'home'
$localBin = Join-Path $homeDir '.local\bin'
$appData = Join-Path $Tmp 'appdata'
New-Item -ItemType Directory -Force -Path $localBin, (Join-Path $appData 'npm') | Out-Null

# Stub devprofile.ps1 with the real script's binding contract: a single
# [string]$Command at position 0 is what the object[]-array bug tripped over.
$stubDevprofile = Join-Path $localBin 'devprofile.ps1'
$stubCode = @'
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Arg1,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)
Add-Content -LiteralPath $env:DEVPROFILE_STUB_LOG -Value "Command=$Command Arg1=$Arg1 Rest=$($Rest -join ',')"
'@
[IO.File]::WriteAllText($stubDevprofile, $stubCode, $Utf8NoBom)

# Child driver: dot-source the profile, exercise the wrappers, report flags.
$driver = Join-Path $Tmp 'driver.ps1'
$driverCode = @'
param(
    [Parameter(Mandatory = $true)][string]$ProfilePath,
    [Parameter(Mandatory = $true)][string]$FlagsPath
)
$ErrorActionPreference = 'Stop'
. $ProfilePath
devprofile use work
dp list
$reload = Get-Command reload -ErrorAction SilentlyContinue
$npm = Join-Path $env:APPDATA 'npm'
$localBin = Join-Path $env:USERPROFILE '.local\bin'
$expectedPrefix = $localBin + ';' + $npm + ';'
[IO.File]::WriteAllLines($FlagsPath, @(
    "RELOAD=$([bool]$reload)",
    "PATH_PREFIXED=$($env:Path.StartsWith($expectedPrefix))"
))
'@
[IO.File]::WriteAllText($driver, $driverCode, $Utf8NoBom)

foreach ($profilePath in @($Profile7, $Profile51)) {
    $name = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($profilePath))
    $stubLog = Join-Path $Tmp "devprofile-$name.log"
    $flags = Join-Path $Tmp "flags-$name.txt"
    $env:HOME = $homeDir
    $env:USERPROFILE = $homeDir
    $env:APPDATA = $appData
    $env:DEVPROFILE_STUB_LOG = $stubLog
    $out = & pwsh -NoProfile -File $driver -ProfilePath $profilePath -FlagsPath $flags 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "[$name] profile dot-source/driver failed: $out" }
    if (-not (Test-Path -LiteralPath $stubLog)) { Fail "[$name] stub devprofile was never called: $out" }
    $calls = [IO.File]::ReadAllLines($stubLog)
    if ($calls.Count -ne 2) { Fail "[$name] expected 2 stub calls, got $($calls.Count): $($calls -join ' | ')" }
    if ($calls[0] -ne 'Command=use Arg1=work Rest=') { Fail "[$name] 'devprofile use work' bound wrong: $($calls[0])" }
    if ($calls[1] -ne 'Command=list Arg1= Rest=') { Fail "[$name] 'dp list' bound wrong: $($calls[1])" }
    $flagLines = [IO.File]::ReadAllLines($flags)
    $reloadFlag = ($flagLines | Where-Object { $_ -like 'RELOAD=*' })
    $pathFlag = ($flagLines | Where-Object { $_ -like 'PATH_PREFIXED=*' })
    if ($reloadFlag -ne 'RELOAD=False') { Fail "[$name] reload must not be defined after dot-sourcing: $reloadFlag" }
    if ($pathFlag -ne 'PATH_PREFIXED=True') { Fail "[$name] PATH additions did not run: $flagLines" }
}
Write-Host '  ok: devprofile binds per-argument in both profiles; reload gone; PATH block runs'

Remove-Item Env:DEVPROFILE_STUB_LOG -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
Write-Host 'PASS: pwsh_profiles.ps1 (parse, splat binding, no reload, PATH additions)'
exit 0
