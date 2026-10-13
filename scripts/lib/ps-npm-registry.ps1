# scripts/lib/ps-npm-registry.ps1 - is a global npm package current? Answered without starting npm.
#
# "Is X the latest?" cost a node start for the installed version (`npm -v`, `npm ls -g`) and another for
# the latest (`npm view`), per package. Each is 0.6-2.7 s alone, yet inside a real `dot up` the one
# registry question took 41 s and 48 s (2026-10-12, twice) - not the fetch (a 10-second fetch limit did
# not cut it) and not npm itself (the same commands, elevated, at the prompt: 0.64 s and 2.7 s). The
# installed version is a file (<prefix>\node_modules\<package>\package.json) and the latest version is one
# HTTPS request to the registry's /latest document, which has a hard time limit of its own.
#
# Inlined into the installer with {{ include }} (it never loads ps-common.ps1) and dot-sourced by
# scripts/lib/ps-common.ps1. Every function answers '' when it cannot say - an unusual registry or prefix
# setup, a failed request, DOT_NPM_DIRECT=0 (the tests set it so they stay on their npm stubs) - and the
# caller then asks npm exactly as before. Nothing here may depend on anything else in ps-common.ps1.

function Test-NpmDirectEnabled {
    return ($env:DOT_NPM_DIRECT -ne '0')
}

# The lines of the user's ~\.npmrc (none when it is absent or unreadable).
function Get-NpmUserConfigLine {
    $profileDir = $env:USERPROFILE
    if (-not $profileDir) { $profileDir = $HOME }
    try {
        $path = Join-Path $profileDir '.npmrc'
        if (Test-Path -LiteralPath $path) { return @([System.IO.File]::ReadAllLines($path)) }
    }
    catch { Write-Verbose "npmrc unreadable: $($_.Exception.Message)" }
    return @()
}

# The registry to ask for <Package>: the public one, or '' when this machine points npm elsewhere
# (a registry in the environment or ~\.npmrc, or one for the package's scope) - npm itself must answer then.
function Get-NpmRegistryTarget {
    param([Parameter(Mandatory)][string]$Package)
    $url = $env:npm_config_registry
    if (-not $url) { $url = $env:NPM_CONFIG_REGISTRY }
    $scope = ''
    if ($Package -match '^(@[^/]+)/') { $scope = $Matches[1] }
    foreach ($line in (Get-NpmUserConfigLine)) {
        if ($scope -and $line -match ('^\s*' + [regex]::Escape($scope) + ':registry\s*=')) { return '' }
        if (-not $url -and $line -match '^\s*registry\s*=\s*(\S+)\s*$') { $url = $Matches[1] }
    }
    if (-not $url -or $url -match '^https://registry\.npmjs\.org/?$') { return 'https://registry.npmjs.org' }
    return ''
}

# Folders that may hold the global node_modules, in the order npm's own shim prefers them: a prefix named
# in the environment or ~\.npmrc, %APPDATA%\npm, then the folder of npm.cmd (Node's own install).
function Get-NpmGlobalRoot {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($env:npm_config_prefix, $env:NPM_CONFIG_PREFIX)) { if ($value) { $roots.Add($value) } }
    foreach ($line in (Get-NpmUserConfigLine)) {
        if ($line -match '^\s*prefix\s*=\s*(.+?)\s*$') {
            $roots.Add([System.Environment]::ExpandEnvironmentVariables(($Matches[1] -replace '\$\{(\w+)\}', '%$1%')))
        }
    }
    if ($env:APPDATA) { $roots.Add((Join-Path $env:APPDATA 'npm')) }
    $shim = @(Get-Command 'npm.cmd' -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($shim) { $roots.Add((Split-Path -Parent $shim.Source)) }
    return @($roots | Select-Object -Unique)
}

# The version of a global package, read from its package.json; '' when it is not found there.
function Get-NpmInstalledVersion {
    param([Parameter(Mandatory)][string]$Package, [string[]]$Root)
    if (-not (Test-NpmDirectEnabled)) { return '' }
    if (-not $PSBoundParameters.ContainsKey('Root')) { $Root = Get-NpmGlobalRoot }
    foreach ($base in @($Root)) {
        $folder = Join-Path $base 'node_modules'
        foreach ($part in ($Package -split '/')) { $folder = Join-Path $folder $part }
        $file = Join-Path $folder 'package.json'
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $json = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
            if ($json.PSObject.Properties['version'] -and $json.version) { return [string]$json.version }
        }
        catch { Write-Verbose "unreadable package.json: $file" }
    }
    return ''
}

# One GET with a time limit; the parsed answer, or $null. A function of its own so a test can answer for it.
function Invoke-NpmRegistryRequest {
    param([Parameter(Mandatory)][string]$Uri, [int]$TimeoutSeconds = 10)
    # Windows PowerShell 5.1 redraws a progress bar per received chunk, which slows even a small download.
    $ProgressPreference = 'SilentlyContinue'
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        return (Invoke-RestMethod -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop)
    }
    catch { return $null }
}

# The registry's latest version of a package ('latest' dist-tag, what `npm view <p> version` prints);
# '' when it cannot say.
function Get-NpmLatestVersion {
    param([Parameter(Mandatory)][string]$Package, [int]$TimeoutSeconds = 10)
    if (-not (Test-NpmDirectEnabled)) { return '' }
    $registry = Get-NpmRegistryTarget -Package $Package
    if (-not $registry) { return '' }
    $answer = Invoke-NpmRegistryRequest -Uri ("$registry/" + ($Package -replace '/', '%2F') + '/latest') -TimeoutSeconds $TimeoutSeconds
    if ($answer -and $answer.PSObject.Properties['version'] -and $answer.version) { return [string]$answer.version }
    return ''
}
