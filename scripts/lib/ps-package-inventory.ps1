# scripts/lib/ps-package-inventory.ps1 - ask winget and choco ONE time what is installed.
#
# Every `winget list --id <id> --exact` costs about 2.3 s and every per-package `choco list` query about
# 1.7 s, whatever the answer (measured 2026-10-12: a full `winget list` is 2.5 s, `choco list` 1.8 s).
# The Windows installer already takes both inventories at the top (the package sweeps use them); the
# desktop-app section (Chrome, Win-CodexBar, Docker Desktop, Meld) then asked again per app, and a
# `dot up` with nothing to install spent about 14 s of its "desktop apps" time on those lookups.
#
# Inlined into the installer with {{ include }} (it never loads ps-common.ps1). The installer stores
# the two inventories with Register-DotPackageInventory once they exist; before that, or when a listing
# failed, every function here falls back to the old per-package query, so nothing gets less exact.
#   - winget: a HIT in the inventory is trusted. A miss is checked live, because the listing table
#     can truncate a long id and the inventory predates installs made earlier in the run.
#   - choco: the inventory is `choco list` of the local library, which is complete, so a miss means
#     "not Chocolatey's" - unless the batched listing failed (-Usable $false), then ask live.
# Nothing here may depend on anything else in ps-common.ps1.
$script:DotWingetInventory = ''
$script:DotChocoInventory = $null
$script:DotChocoInventoryUsable = $false

function Register-DotPackageInventory {
    param([string]$Winget, $Choco, [bool]$ChocoUsable = $false)
    if ($PSBoundParameters.ContainsKey('Winget')) { $script:DotWingetInventory = $Winget }
    if ($PSBoundParameters.ContainsKey('Choco')) { $script:DotChocoInventory = $Choco; $script:DotChocoInventoryUsable = $ChocoUsable }
}

# Is winget's package <Id> installed? (a miss is confirmed with one live query)
function Test-DotWingetInstalled {
    param([Parameter(Mandatory)][string]$Id)
    $pattern = [regex]::Escape($Id)
    if ($script:DotWingetInventory -and $script:DotWingetInventory -match "(?m)\s$pattern\s") { return $true }
    $live = (winget list --id $Id --exact --accept-source-agreements --disable-interactivity 2>$null | Out-String)
    return ($live -match $pattern)
}

# Does Chocolatey own <Name> here? $false when choco is not installed.
function Test-DotChocoPackage {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:DotChocoInventoryUsable -and $null -ne $script:DotChocoInventory) { return [bool]$script:DotChocoInventory.Contains($Name) }
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { return $false }
    $live = (choco list --limit-output --exact $Name 2>$null | Out-String)
    return ($live -match "(?m)^$([regex]::Escape($Name))\|")
}

# Run a program and capture its output WITHOUT a background job. Invoke-WithTimeout (a job) starts a second
# PowerShell for every call: a `winget list` of 2.7 s took 4.6 s through it, measured on Windows PowerShell
# 5.1 (2026-10-12), and the two listings at the top of every `dot up` paid that twice. A plain process
# with a wait limit keeps the cap and loses the startup. Returns $null when the program is not found, else
# an object with Text, ExitCode and TimedOut (a program past the limit is killed).
function Invoke-DotNativeCapture {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSeconds = 120)
    $program = Get-Command $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $program) { return $null }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $program.Source
    $quoted = foreach ($argument in $ArgumentList) {
        if ($argument -match '[\s"]' -or $argument -eq '') { '"' + ($argument -replace '"', '\"') + '"' } else { $argument }
    }
    $startInfo.Arguments = @($quoted) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = [System.Diagnostics.Process]::Start($startInfo)
    # Both streams are drained while it runs: a full pipe would otherwise stall the program for good.
    $null = $process.StandardError.ReadToEndAsync()
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        # Kill($true) takes the children too (PowerShell 7); Windows PowerShell 5.1 has only Kill(). Never
        # `taskkill /T`: it follows reused parent ids (tests/process_tree_reuse_contract.sh).
        try { $process.Kill($true) }
        catch {
            try { $process.Kill() } catch { Write-Verbose "kill after timeout failed: $($_.Exception.Message)" }
        }
        return [pscustomobject]@{ Text = ''; ExitCode = -1; TimedOut = $true }
    }
    $process.WaitForExit()
    return [pscustomobject]@{ Text = $outputTask.Result; ExitCode = $process.ExitCode; TimedOut = $false }
}
