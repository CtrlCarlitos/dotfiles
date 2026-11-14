# Regression: a 5.1 child of Store-installed pwsh must load its own in-box
# modules. Execute only the startup guards, never the package installer.
# Called by Windows CI under pwsh so its Core module directory is available.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
foreach ($file in @('run_onchange_install_packages.ps1.tmpl', 'run_onchange_generate_identities.ps1.tmpl', 'run_onchange_sync_pwsh_profiles.ps1.tmpl', 'scripts/lib/ps-common.ps1')) {
    $text = [IO.File]::ReadAllText((Join-Path $repo $file))
    $guard = [regex]::Match($text, '(?ms)^\s*if \(\$PSVersionTable.PSVersion.Major -le 5\) \{.*?^\s*\}').Value
    if (-not $guard) { throw "Missing guard: $file" }
    $coreModules = (Join-Path $PSHOME 'Modules').Replace("'", "''")
    $hashFile = $PSCommandPath.Replace("'", "''")
    $code = @"
`$ErrorActionPreference = 'Stop'
`$storeModules = 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.9.0_x64__8wekyb3d8bbwe\Modules'
`$env:PSModulePath = `$storeModules + ';$coreModules;' + `$env:PSModulePath
$guard
if ((`$env:PSModulePath -split ';') -contains `$storeModules) {
    throw 'Store Core module directory survived the guard'
}
if ((Get-FileHash -LiteralPath '$hashFile').Hash.Length -ne 64) {
    throw 'Get-FileHash failed after startup guard'
}
foreach (`$name in @('Microsoft.PowerShell.Security', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Management')) {
    Import-Module `$name -ErrorAction Stop
    if (-not (Get-Module `$name).Path.StartsWith(`$PSHOME, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Wrong module: `$name"
    }
}
'PASS'
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $result = & powershell.exe -NoProfile -EncodedCommand $encoded 2>&1
    if ($LASTEXITCODE -ne 0 -or $result -notcontains 'PASS') { throw "$file failed: $result" }
    Write-Output "PASS: $file"
}
