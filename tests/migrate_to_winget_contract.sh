#!/usr/bin/env bash
# shellcheck disable=SC2016  # PowerShell source and template text are literal
set -euo pipefail

# winget is the primary Windows package manager, Chocolatey the fallback (catalog fields `winget`,
# `winget_args`, `choco_was`). This pins (executed against fakes where it runs code):
#   - the installer installs the catalog's winget ids after the choco pass, one `winget list`
#     inventory first, extra args (winget_args) passed through; WSL is installed when missing;
#   - dot upgrade updates WSL with `wsl --update` and holds Claude Desktop while claude.exe runs;
#   - install.ps1 installs chezmoi and Git through winget (Chocolatey only without winget);
#   - Get-WingetMigrationPlan: only installed Chocolatey copies, .install companions found, drops;
#   - Invoke-WingetMigrationItem: choco uninstall, companion, then winget install with its args;
#     the WSL record is dropped with --skip-autouninstaller; a failed winget install says how to
#     put the app back; PowerShell 7 never replaces itself.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
ps_t="$repo_root/run_onchange_install_packages.ps1.tmpl"

# --- wiring -----------------------------------------------------------------------------------------
[ -f "$repo_root/.chezmoitemplates/winget-packages" ] || fail ".chezmoitemplates/winget-packages is missing"
[ "$(grep -c 'includeTemplate "winget-packages"' "$ps_t")" = "$(grep -c 'includeTemplate "choco-packages"' "$ps_t")" ] ||
    fail "installer: every group that renders choco packages must render its winget packages too"
grep -Fq 'winget list --accept-source-agreements --disable-interactivity' "$ps_t" || fail "installer: one winget list inventory before installing"
grep -Fq 'winget install --id $env:WINGET_PKG --exact --source winget --silent' "$ps_t" || fail "installer: winget install of missing ids"
grep -Fq '@extra' "$ps_t" || fail "installer: winget_args must reach winget install"
grep -Fq 'wsl.exe --install --no-distribution' "$ps_t" || fail "installer: WSL must be installed when missing"
grep -Fq 'wsl.exe --update' "$repo_root/scripts/dotupgrade.ps1" || fail "dotupgrade.ps1: WSL must be updated with wsl --update"
grep -Fq "\$wingetHold += 'Anthropic.Claude'" "$repo_root/scripts/dotupgrade.ps1" || fail "dotupgrade.ps1: Claude Desktop must be held while claude.exe runs"
grep -Fq 'winget install --id twpayne.chezmoi' "$repo_root/install.ps1" || fail "install.ps1: chezmoi must come from winget"
grep -Fq 'winget install --id Git.Git' "$repo_root/install.ps1" || fail "install.ps1: Git must come from winget"
# Node: the same major on every platform (versions.node_major), pinned in winget on Windows
grep -Fq 'Set-NodeLtsPin -Major $nodeMajor' "$repo_root/scripts/dotupgrade.ps1" || fail "dotupgrade.ps1: Node must be pinned to node_major before the winget sweep"
awk '/Set-NodeLtsPin -Major \$nodeMajor/{a=NR} /Invoke-WingetUpgradeAll -RunningNote/{b=NR} END{exit !(a && b && a<b)}' "$repo_root/scripts/dotupgrade.ps1" ||
    fail "dotupgrade.ps1: the Node pin must be set before winget upgrade --all"
grep -Fq 'winget pin add --id OpenJS.NodeJS.LTS --exact --version "$nodeMajor.*"' "$ps_t" || fail "installer: a winget Node install must be pinned to node_major"
pass

# --- executed ---------------------------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
. $Lib
$catalog = @(
    'git.install|Git.Git|git||chezmoi uses git',
    'bat|sharkdp.bat|bat||',
    'cmake|Kitware.CMake|cmake||',
    'vscode.install|Microsoft.VisualStudioCode|vscode|--scope machine|close VS Code',
    'powershell-core|Microsoft.PowerShell|powershell-core|--scope machine|cannot replace itself',
    'jq|jqlang.jq|jq||',
    'nodejs|OpenJS.NodeJS.LTS|node||Node 26 -> 24 LTS'
)
$installed = @('git.install', 'bat', 'cmake', 'cmake.install', 'vscode.install', 'powershell-core', 'winmerge', 'wsl2', 'python', 'nodejs', 'nodejs.install', 'cutepdf', 'Ghostscript.app', 'autohotkey.portable')
$plan = @(Get-WingetMigrationPlan -CatalogLine $catalog -Installed $installed)
Write-Output ('plan-moves=' + (($plan | Where-Object Action -eq 'move' | ForEach-Object { $_.Choco }) -join ','))
Write-Output ('plan-drops=' + (($plan | Where-Object Action -eq 'drop' | ForEach-Object { $_.Choco }) -join ','))
Write-Output ('plan-companion=' + (($plan | Where-Object Choco -eq 'cmake').Companion))
Write-Output ('plan-risk=' + (($plan | Where-Object Choco -eq 'git.install').Risk))

$script:calls = @(); $script:wingetExit = 0
function choco { $script:calls += 'choco ' + ($args -join ' '); $global:LASTEXITCODE = 0 }
function winget { $script:calls += 'winget ' + ($args -join ' '); $global:LASTEXITCODE = $script:wingetExit }
function npm { $script:calls += 'npm ' + ($args -join ' '); $global:LASTEXITCODE = 0 }
function Run($item) { $script:calls = @(); $r = Invoke-WingetMigrationItem -Item $item 6>$null; return "$r|" + ($script:calls -join ' ; ') }
Write-Output ('move-cmake=' + (Run ($plan | Where-Object Choco -eq 'cmake')))
Write-Output ('move-vscode=' + (Run ($plan | Where-Object Choco -eq 'vscode.install')))
Write-Output ('drop-wsl=' + (Run ($plan | Where-Object Choco -eq 'wsl2')))
Write-Output ('drop-winmerge=' + (Run ($plan | Where-Object Choco -eq 'winmerge')))
$script:wingetExit = 5
$failText = ((Invoke-WingetMigrationItem -Item ($plan | Where-Object Choco -eq 'bat') *>&1 | Out-String) -replace '\s+', ' ').Trim()
Write-Output ('move-fail=' + $failText)
$script:wingetExit = 0
Write-Output ('move-pwsh=' + (Run ($plan | Where-Object Choco -eq 'powershell-core')))
Write-Output ('move-node=' + (Run ($plan | Where-Object Choco -eq 'nodejs')))
# Set-NodeLtsPin: no pin -> add "24.*"; the right pin -> nothing; another major -> replaced
$script:pinList = @()
function winget { $script:calls += 'winget ' + ($args -join ' '); if ($args[0] -eq 'pin' -and $args[1] -eq 'list') { $script:pinList | ForEach-Object { $_ } }; $global:LASTEXITCODE = 0 }
function Pin([string[]]$Existing) { $script:calls = @(); $script:pinList = $Existing; $r = Set-NodeLtsPin -Major 24; return "$r|" + (($script:calls | Where-Object { $_ -notmatch 'pin list' }) -join ' ; ') }
Write-Output ('pin-none=' + (Pin @()))
Write-Output ('pin-same=' + (Pin @('Node.js LTS OpenJS.NodeJS.LTS 24.21.0 Gating 24.*')))
Write-Output ('pin-other=' + (Pin @('Node.js LTS OpenJS.NodeJS.LTS 22.11.0 Gating 22.*')))
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '\r' || true)"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-600))"; }
    expect 'plan-moves=git.install,bat,cmake,vscode.install,powershell-core,nodejs'
    expect 'plan-drops=winmerge,cutepdf,Ghostscript.app,autohotkey.portable,wsl2'
    expect 'plan-companion=cmake.install'
    expect 'plan-risk=chezmoi uses git'
    expect 'move-cmake=ok|choco uninstall cmake -y --no-progress ; choco uninstall cmake.install -y --no-progress ; winget install --id Kitware.CMake --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    expect 'move-vscode=ok|choco uninstall vscode.install -y --no-progress ; winget install --id Microsoft.VisualStudioCode --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --scope machine'
    expect 'drop-wsl=ok|choco uninstall wsl2 -y --no-progress --skip-autouninstaller'
    expect 'drop-winmerge=ok|choco uninstall winmerge -y --no-progress'
    printf '%s\n' "$out" | grep -q '^move-fail=.*NOT installed now; put it back with: choco install bat -y.*failed$' ||
        fail "PowerShell: a failed winget install must say how to put the app back (got: $(printf '%s' "$out" | grep '^move-fail=' | cut -c1-300))"
    expect 'pin-none=True|winget pin add --id OpenJS.NodeJS.LTS --exact --version 24.* --accept-source-agreements'
    expect 'pin-same=True|'
    expect 'pin-other=True|winget pin remove --id OpenJS.NodeJS.LTS --exact ; winget pin add --id OpenJS.NodeJS.LTS --exact --version 24.* --accept-source-agreements'
    expect 'move-pwsh=skipped|'
    # a different Node major: the global npm tools' native modules are rebuilt right after
    expect 'move-node=ok|choco uninstall nodejs -y --no-progress ; choco uninstall nodejs.install -y --no-progress ; winget install --id OpenJS.NodeJS.LTS --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity ; npm rebuild -g'
    pass
else
    printf 'note: pwsh not installed - executed checks skipped\n'
fi

finish
