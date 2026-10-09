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
#     a package a staying Chocolatey package depends on is kept (opencode needs fzf and ripgrep);
#   - Invoke-WingetMigrationItem: meta package and .install in ONE choco uninstall (meta first),
#     then winget install with its args; a non-zero choco exit with the package gone still
#     installs the winget copy (neovim was lost that way); one still there is left as it is;
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
# the Chocolatey inventory must stay a case-insensitive set: `$x = if (...) { $set }` turns it into
# a case-sensitive array and `Wget` (Chocolatey) stopped matching `wget` (catalog)
if grep -Fq '$chocoHave = if (' "$ps_t"; then fail "installer: assign the choco inventory set directly (an if-expression enumerates it)"; fi
grep -Fq 'if (Get-Variable -Name chocoInstalled -ErrorAction SilentlyContinue) { $chocoHave = $chocoInstalled }' "$ps_t" ||
    fail "installer: the still-Chocolatey check must use the choco inventory set itself"
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
# Never the real tools: until the fakes below are defined, any call fails loudly (a case placed
# above them once ran the real `choco uninstall unzip`; an unelevated shell is all that stopped it).
function choco { throw "real choco called before the fakes: $args" }
function winget { throw "real winget called before the fakes: $args" }
function npm { throw "real npm called before the fakes: $args" }
$catalog = @(
    'git.install|Git.Git|git||chezmoi uses git',
    'bat|sharkdp.bat|bat||',
    'cmake|Kitware.CMake|cmake||',
    'vscode.install|Microsoft.VisualStudioCode|vscode|--scope machine|close VS Code',
    'powershell-core|Microsoft.PowerShell|powershell-core|--scope machine|cannot replace itself',
    'jq|jqlang.jq|jq||',
    'nodejs|OpenJS.NodeJS.LTS|node||Node 26 -> 24 LTS',
    'fzf|junegunn.fzf|fzf||',
    'neovim|Neovim.Neovim|neovim||'
)
$installed = @('git', 'fzf', 'opencode', 'neovim', 'git.install', 'bat', 'cmake', 'cmake.install', 'vscode.install', 'powershell-core', 'winmerge', 'wsl2', 'python', 'nodejs', 'nodejs.install', 'cutepdf', 'Ghostscript.app', 'autohotkey.portable')
# opencode (staying on Chocolatey) needs fzf; the meta `git` needs git.install, but leaves with it
$plan = @(Get-WingetMigrationPlan -CatalogLine $catalog -Installed $installed -DependedOn @{ fzf = @('opencode'); 'git.install' = @('git'); 'cmake.install' = @('cmake') })
Write-Output ('plan-keep=' + (($plan | Where-Object Action -eq 'keep' | ForEach-Object { "$($_.Choco): $($_.Risk)" }) -join ','))
Write-Output ('plan-git-companion=' + (($plan | Where-Object Choco -eq 'git.install').Companion))
Write-Output ('plan-git-after=[' + (@(($plan | Where-Object Choco -eq 'git.install').After) -join ',') + ']')
# opencode moves too (its catalog record): fzf is no longer kept - it moves AFTER opencode,
# because Chocolatey refuses to remove it while opencode is installed
$withOc = @($catalog + 'opencode|SST.opencode|opencode-cli||close every opencode session first')
$planOc = @(Get-WingetMigrationPlan -CatalogLine $withOc -Installed $installed -DependedOn @{ fzf = @('opencode'); 'git.install' = @('git') })
Write-Output ('oc-fzf=' + (($planOc | Where-Object Choco -eq 'fzf' | ForEach-Object { "$($_.Action) after $(@($_.After) -join ',')" })))
Write-Output ('oc-keeps=[' + (@($planOc | Where-Object Action -eq 'keep').Count) + ']')
# unzip: only opencode used it - offered for removal after opencode leaves; never while opencode
# stays, and never a catalog tool (fzf is one, so it is moved, not orphaned)
$withUnzip = @($installed + 'unzip')
$deps = @{ fzf = @('opencode'); unzip = @('opencode') }
Write-Output ('orphan-unzip=' + ((@(Get-WingetMigrationPlan -CatalogLine $withOc -Installed $withUnzip -DependedOn $deps) | Where-Object Action -eq 'orphan' | ForEach-Object { "$($_.Choco) after $(@($_.After) -join ',')" }) -join ';'))
Write-Output ('orphan-none-when-kept=[' + ((@(Get-WingetMigrationPlan -CatalogLine $catalog -Installed $withUnzip -DependedOn $deps) | Where-Object Action -eq 'orphan' | ForEach-Object { $_.Choco }) -join ',') + ']')
Write-Output ('plan-moves=' + (($plan | Where-Object Action -eq 'move' | ForEach-Object { $_.Choco }) -join ','))
Write-Output ('plan-drops=' + (($plan | Where-Object Action -eq 'drop' | ForEach-Object { $_.Choco }) -join ','))
Write-Output ('plan-companion=' + (($plan | Where-Object Choco -eq 'cmake').Companion))
Write-Output ('plan-risk=' + (($plan | Where-Object Choco -eq 'git.install').Risk))

$script:calls = @(); $script:wingetExit = 0; $script:chocoExit = 0; $script:chocoLeft = @()
function choco {
    if ($args[0] -eq 'list') { $script:chocoLeft | ForEach-Object { $_ }; $global:LASTEXITCODE = 0; return }
    $script:calls += 'choco ' + ($args -join ' '); $global:LASTEXITCODE = $script:chocoExit
}
$script:wingetHas = @()
function winget {
    if ($args[0] -eq 'list') { $script:wingetHas | ForEach-Object { $_ }; $global:LASTEXITCODE = 0; return }
    $script:calls += 'winget ' + ($args -join ' '); $global:LASTEXITCODE = $script:wingetExit
}
function npm { $script:calls += 'npm ' + ($args -join ' '); $global:LASTEXITCODE = 0 }
function Run($item) { $script:calls = @(); $r = Invoke-WingetMigrationItem -Item $item 6>$null; return "$r|" + ($script:calls -join ' ; ') }
Write-Output ('move-cmake=' + (Run ($plan | Where-Object Choco -eq 'cmake')))
Write-Output ('move-git=' + (Run ($plan | Where-Object Choco -eq 'git.install')))
Write-Output ('keep-fzf=' + (Run ($plan | Where-Object Choco -eq 'fzf')))
# choco exits 1 (beforeModify warned) but neovim is gone: winget still installs it
$script:chocoExit = 1
Write-Output ('move-neovim-gone=' + (Run ($plan | Where-Object Choco -eq 'neovim')))
$script:chocoLeft = @('neovim|0.12.0')
Write-Output ('move-neovim-there=' + (Run ($plan | Where-Object Choco -eq 'neovim')))
$script:chocoExit = 0; $script:chocoLeft = @()
Write-Output ('move-vscode=' + (Run ($plan | Where-Object Choco -eq 'vscode.install')))
Write-Output ('drop-wsl=' + (Run ($plan | Where-Object Choco -eq 'wsl2')))
Write-Output ('drop-winmerge=' + (Run ($plan | Where-Object Choco -eq 'winmerge')))
$script:wingetExit = 5
$failText = ((Invoke-WingetMigrationItem -Item ($plan | Where-Object Choco -eq 'bat') *>&1 | Out-String) -replace '\s+', ' ').Trim()
Write-Output ('move-fail=' + $failText)
$script:wingetExit = 0
Write-Output ('move-pwsh=' + (Run ($plan | Where-Object Choco -eq 'powershell-core')))
Write-Output ('move-node=' + (Run ($plan | Where-Object Choco -eq 'nodejs')))
# winget already has its own copy (installed next to Chocolatey's): only Chocolatey's goes
$script:wingetHas = @('Name Id Version', 'jq jqlang.jq 1.8.2')
Write-Output ('move-already=' + (Run ([pscustomobject]@{ Action = 'move'; Choco = 'jq'; Winget = 'jqlang.jq'; Id = 'jq'; Args = ''; Risk = ''; Companion = '' })))
# an orphaned dependency is removed like a drop (never before the fakes above: it calls choco)
Write-Output ('orphan-removed=' + (Run ([pscustomobject]@{ Action = 'orphan'; Choco = 'unzip'; Winget = ''; Id = 'unzip'; Args = ''; Risk = 'only opencode used it'; Companion = ''; After = @('opencode') })))
$script:wingetHas = @()
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
    expect 'plan-moves=git.install,bat,cmake,vscode.install,powershell-core,nodejs,neovim'
    expect "plan-keep=fzf: Chocolatey's opencode depends on it"
    expect 'plan-git-companion=git'
    # a meta package leaving with its .install is the companion, not something to wait for
    expect 'plan-git-after=[]'
    expect 'oc-fzf=move after opencode'
    expect 'oc-keeps=[0]'
    expect 'orphan-unzip=unzip after opencode'
    expect 'orphan-none-when-kept=[]'
    expect 'orphan-removed=ok|choco uninstall unzip -y --no-progress'
    # the script runs those last, and keeps one whose dependent stayed on Chocolatey
    awk '/\$late \+= \$b/{a=NR} /foreach \(\$c in \$careful\)/{b=NR} /foreach \(\$l in \$late\)/{c=NR} END{exit !(a && b && c && a<c && b<c)}' "$repo_root/scripts/migrate-to-winget.ps1" ||
        fail "migrate-to-winget.ps1: tools other moving packages depend on must move after the batch and the careful items"
    grep -Fq 'still depends on it)' "$repo_root/scripts/migrate-to-winget.ps1" || fail "migrate-to-winget.ps1: a late tool whose dependent stayed must be kept, with the reason"
    expect 'plan-drops=winmerge,cutepdf,Ghostscript.app,autohotkey.portable,wsl2'
    expect 'plan-companion=cmake.install'
    expect 'plan-risk=chezmoi uses git'
    expect 'move-cmake=ok|choco uninstall cmake cmake.install -y --no-progress ; winget install --id Kitware.CMake --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    expect 'move-git=ok|choco uninstall git git.install -y --no-progress ; winget install --id Git.Git --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    expect 'keep-fzf=skipped|'
    expect 'move-neovim-gone=ok|choco uninstall neovim -y --no-progress ; winget install --id Neovim.Neovim --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    expect 'move-neovim-there=failed|choco uninstall neovim -y --no-progress'
    expect 'move-vscode=ok|choco uninstall vscode.install -y --no-progress ; winget install --id Microsoft.VisualStudioCode --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --scope machine'
    expect 'drop-wsl=ok|choco uninstall wsl2 -y --no-progress --skip-autouninstaller'
    expect 'drop-winmerge=ok|choco uninstall winmerge -y --no-progress'
    printf '%s\n' "$out" | grep -q '^move-fail=.*NOT installed now; put it back with: choco install bat -y.*failed$' ||
        fail "PowerShell: a failed winget install must say how to put the app back (got: $(printf '%s' "$out" | grep '^move-fail=' | cut -c1-300))"
    expect 'pin-none=True|winget pin add --id OpenJS.NodeJS.LTS --exact --version 24.* --accept-source-agreements'
    expect 'pin-same=True|'
    expect 'pin-other=True|winget pin remove --id OpenJS.NodeJS.LTS --exact ; winget pin add --id OpenJS.NodeJS.LTS --exact --version 24.* --accept-source-agreements'
    expect 'move-pwsh=skipped|'
    expect 'move-already=ok|choco uninstall jq -y --no-progress'
    # a different Node major: no global npm tool the dotfiles install has native modules any
    # more (graft was the one), so nothing is rebuilt - and never `npm rebuild -g`, which fails
    # with EEXIST on command shims an older npm wrote
    expect 'move-node=ok|choco uninstall nodejs nodejs.install -y --no-progress ; winget install --id OpenJS.NodeJS.LTS --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    if grep -Fq 'npm rebuild -g' "$repo_root/scripts/lib/ps-common.ps1"; then
        grep -F 'npm rebuild -g' "$repo_root/scripts/lib/ps-common.ps1" | grep -vq '^ *#' && fail "ps-common.ps1: npm rebuild -g is back (it fails with EEXIST on older shims)"
    fi
    pass
else
    printf 'note: pwsh not installed - executed checks skipped\n'
fi

finish
