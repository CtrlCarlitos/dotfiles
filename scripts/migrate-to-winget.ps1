#Requires -Version 5.1
<#
migrate-to-winget.ps1 - move this machine's Chocolatey copies to winget, the primary Windows manager.

The catalog (.chezmoidata/packages.yaml) names winget for every tool that moved, with the old
Chocolatey name in `choco_was`. A Chocolatey install cannot be adopted by winget, so each one is
uninstalled from Chocolatey and installed with winget. It also drops what dotfiles replaced
(WinMerge -> Meld, Notepad++ -> Geany, WinSCP -> Termius), Chocolatey GUI, and Chocolatey's WSL
record (WSL itself stays: --skip-autouninstaller).

  List only:  pwsh -File migrate-to-winget.ps1 -ListOnly
  Move:       pwsh -File migrate-to-winget.ps1            (elevated)

Tools without a risk note are asked about once, as a batch; each one with a risk note (VS Code,
Git, Tailscale, PowerShell...) is asked about on its own. PowerShell 7 cannot replace itself: run
the script once more from Windows PowerShell (powershell.exe) for that one.
#>
param([switch]$ListOnly)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\ps-common.ps1')

if (-not (Test-IsAdmin) -and -not $ListOnly) {
    Write-Host "migrate-to-winget needs an elevated terminal (choco uninstall + winget install)." -ForegroundColor Red
    Write-Host "  Re-run as Administrator, or use -ListOnly to see the plan." -ForegroundColor Yellow
    exit 1
}
Repair-InBoxModulePath

$template = '{{ range .catalog.packages }}{{ if and (hasKey . "winget") (hasKey . "choco_was") }}{{ .choco_was }}|{{ .winget }}|{{ .id }}|{{ get . "winget_args" }}|{{ get . "migrate_risk" }}{{ "\n" }}{{ end }}{{ end }}'
$catalogLines = @((chezmoi execute-template $template | Out-String) -split "`r?`n" | Where-Object { $_ })
if ($catalogLines.Count -eq 0) { Write-Host "Could not read the package catalog (chezmoi execute-template)." -ForegroundColor Red; exit 1 }
$installed = @(choco list --limit-output | ForEach-Object { ($_ -split '\|')[0] })
try { $script:WingetMigrationNodeMajor = [int]((chezmoi execute-template '{{ .versions.node_major }}' | Out-String).Trim()) } catch { $script:WingetMigrationNodeMajor = 0 }

$plan = @(Get-WingetMigrationPlan -CatalogLine $catalogLines -Installed $installed)
if ($plan.Count -eq 0) { Write-Host "Nothing to move: no Chocolatey copy of a winget-managed tool, nothing to drop."; exit 0 }

$batch = @($plan | Where-Object { $_.Action -eq 'move' -and -not $_.Risk })
$careful = @($plan | Where-Object { $_.Action -eq 'move' -and $_.Risk })
$drops = @($plan | Where-Object { $_.Action -eq 'drop' })
Write-Host "Chocolatey -> winget plan:"
if ($batch.Count) { Write-Host "  Move as one batch ($($batch.Count)): $(($batch | ForEach-Object { $_.Choco }) -join ', ')" }
foreach ($c in $careful) { Write-Host "  Move, asked on its own: $($c.Choco) -> $($c.Winget)  ($($c.Risk))" }
foreach ($d in $drops) { Write-Host "  Drop: $($d.Choco)  ($($d.Risk))" }
if ($ListOnly) { exit 0 }

$results = @()
if ($batch.Count -and (Read-Host "Move the batch of $($batch.Count) tools now? [y/N]").Trim().ToLower() -eq 'y') {
    foreach ($b in $batch) { $results += Invoke-WingetMigrationItem -Item $b }
}
foreach ($c in $careful) {
    if ((Read-Host "Move $($c.Choco) -> $($c.Winget)? $($c.Risk) [y/N]").Trim().ToLower() -eq 'y') { $results += Invoke-WingetMigrationItem -Item $c }
}
if ($drops.Count -and (Read-Host "Drop $(($drops | ForEach-Object { $_.Choco }) -join ', ')? [y/N]").Trim().ToLower() -eq 'y') {
    foreach ($d in $drops) { $results += Invoke-WingetMigrationItem -Item $d }
}
$failed = @($results | Where-Object { $_ -eq 'failed' }).Count
Write-Host ("Done: {0} moved or dropped, {1} skipped, {2} failed." -f @($results | Where-Object { $_ -eq 'ok' }).Count, @($results | Where-Object { $_ -eq 'skipped' }).Count, $failed)
if ($failed) { exit 1 }
exit 0
