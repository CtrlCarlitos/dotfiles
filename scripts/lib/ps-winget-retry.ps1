# scripts/lib/ps-winget-retry.ps1 - retry a winget install once when the network blinked, and name what still failed.
#
# A fresh install on LAB-DOT-WIN-HOM (#434 Run 8, 2026-10-25) left Go missing: its winget call failed in under
# a second with 0x80072EE7 (InternetOpenUrl: name not resolved) while the installs either side of it worked.
# Nothing retries a package this installer missed: it is run_onchange, so the next `dot up` does not rerun it,
# and `winget upgrade --all` (dot upgrade) only upgrades what is already installed.
#
# Inlined with {{ include }} into the Windows installer template (it never loads ps-common.ps1). Nothing here
# may depend on anything else in ps-common.ps1. tests/winget_network_retry_contract.sh executes it.

# winget's exit code is the HRESULT as a signed 32-bit integer. These are the WinINet/WinHTTP errors of a link
# that dropped for a moment: winget never got an answer, so asking again can help. Every other failure (winget
# answered, the installer failed, the job timed out) is not retried.
$script:DotWingetNetworkErrors = @{
    '-2147012894' = '0x80072EE2, timed out'
    '-2147012889' = '0x80072EE7, name not resolved'
    '-2147012867' = '0x80072EFD, cannot connect'
    '-2147012866' = '0x80072EFE, connection aborted'
    '-2147012865' = '0x80072EFF, connection reset'
}

function Get-DotWingetNetworkError {
    param($ExitCode)
    if ($null -eq $ExitCode) { return $null }
    return $script:DotWingetNetworkErrors["$ExitCode"]
}

# -Attempt runs one `winget install` and returns its exit code ($null when unknown, e.g. a timeout).
function Invoke-DotWingetInstall {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][scriptblock]$Attempt, [int]$RetryDelaySeconds = 15)
    $code = & $Attempt
    $network = Get-DotWingetNetworkError -ExitCode $code
    if ($network) {
        Write-Host "  $Id`: winget could not reach the network ($network); trying once more in ${RetryDelaySeconds}s..." -ForegroundColor Yellow
        Start-Sleep -Seconds $RetryDelaySeconds
        $code = & $Attempt
    }
    return $code
}

# Said once, at the end, so a run that ends "Package installation complete!" does not hide a missing package.
function Write-DotWingetFailedNote {
    param([string[]]$Failed = @(), [Parameter(Mandatory)][string]$InstallerKey)
    $Failed = @($Failed | Where-Object { $_ })
    if ($Failed.Count -eq 0) { return }
    Write-Host "[Post-Install] Not installed by winget: $($Failed -join ', ')." -ForegroundColor Yellow
    Write-Host "  The next dot up does not retry them (this installer reruns only when its content changes). To retry, in this elevated terminal:" -ForegroundColor Yellow
    Write-Host "    chezmoi state delete --bucket=entryState --key=$InstallerKey; dot up" -ForegroundColor Yellow
}
