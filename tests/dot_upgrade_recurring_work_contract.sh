#!/usr/bin/env bash
# shellcheck disable=SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# What a Windows `dot upgrade` still spent on a no-op, or left unsaid (2026-10-12):
#   - "Superpowers (Codex) 18s": `codex plugin add` asks OpenAI's backend every run, to learn that the
#     marketplace still has 6.4.2 while upstream is 7.0.0. It is now asked once a day per installed
#     version (a stamp, scripts/lib/ps-skills.ps1);
#   - "NPM packages 9s": every `npm view` waited with npm's own defaults (minutes on a degraded link);
#   - `wsl --update` printed nothing for 3 minutes: its output now streams, with a "still running" line;
#   - Docker Desktop was stopped for its upgrade and never started again: it is, after the sweeps.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

updater="$repo_root/scripts/update_ai_tools.ps1"
du="$repo_root/scripts/dotupgrade.ps1"
common="$repo_root/scripts/lib/ps-common.ps1"

# --- wiring (works without pwsh) -----------------------------------------------------------------
grep -Fq 'npm view $Package version --fetch-retries=1 --fetch-timeout=20000' "$common" || fail "Test-NpmGlobalCurrent must bound its npm view"
grep -Fq "Open-DotHeartbeat -Tool 'wsl --update'" "$du" || fail "wsl --update must show a still-running line"
grep -Fq "Test-DotCheckRecent -Name 'codex-superpowers'" "$updater" || fail "the Codex Superpowers add must be remembered for a day"
resume_line="$(grep -n 'Resume-DockerDesktop -Path' "$du" | head -n 1 | cut -d: -f1)"
ai_line="$(grep -n "update_ai_tools.ps1')" "$du" | head -n 1 | cut -d: -f1)"
summary_line="$(grep -n "Write-DotTimingSummary -Title 'dot upgrade'" "$du" | head -n 1 | cut -d: -f1)"
if [ -z "$resume_line" ] || [ "$resume_line" -le "$ai_line" ] || [ "$resume_line" -ge "$summary_line" ]; then
    fail "Docker Desktop must be started again after the sweeps and the AI tools, before the summary (resume $resume_line, ai $ai_line, summary $summary_line)"
fi
grep -Fq '$dockerStopped = -not $dockerKept' "$du" || fail "only a Docker Desktop this run stopped may be started again"
pass

command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (executed part needs PowerShell): pwsh not installed\n'; finish; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Updater, [string]$Background, [string]$Skills, [string]$Common, [string]$State)
$ErrorActionPreference = 'Stop'
$env:XDG_STATE_HOME = $State
. $Background
. $Skills
function Out($label, $value) { Write-Output ("$label=$value") }

# --- the Codex step, run from the script's own text ----------------------------------------------------
$G = @{ sparkles = '*' }
$script:adds = 0
$script:installedVersion = '6.4.2'
function codex {
    $script:adds++
    $global:LASTEXITCODE = 0
    'Added plugin superpowers'
    'Installed plugin root: C:\Users\u\.codex\plugins\cache\mkt\superpowers\' + $script:installedVersion
}
function Get-CodexSuperpowersMarketplace { 'mkt' }
function Get-CodexSuperpowersCachedVersion { $script:installedVersion }
function Get-SuperpowersLatestVersionCached { '7.0.0' }
function Test-Deferred([string]$Tool) { $false }
$text = (Get-DotSectionText -Path $Updater -Name 'Superpowers (Codex)')['Superpowers (Codex)']
function Run { $script:adds = 0; (. ([scriptblock]::Create($text)) 6>&1 | ForEach-Object { "$_" }) -join '|' }
Remove-Item -LiteralPath (Get-DotCheckStampPath -Name 'codex-superpowers') -ErrorAction SilentlyContinue
$first = Run
Out 'first-adds' $script:adds
Out 'first-stamp' (Get-DotCheckValue -Name 'codex-superpowers')
$second = Run
Out 'second-adds' $script:adds
Out 'second-says' ($second -match 'checked within the last day')
Out 'second-names-the-lag' ($second -match 'has not published v7\.0\.0')
$script:installedVersion = '6.5.0'
$null = Run
Out 'new-version-adds' $script:adds

# --- Docker Desktop, started again ------------------------------------------------------------------
. $Common
$env:ProgramFiles = Join-Path $State 'no-program-files'
Out 'docker-missing' (Resume-DockerDesktop -Path (Join-Path $State 'nothing.exe'))
$fake = Join-Path $State 'Docker Desktop.exe'
Set-Content -LiteralPath $fake -Value 'x'
Out 'docker-whatif' (Resume-DockerDesktop -Path $fake -WhatIf)

# --- desktop apps closed for the upgrade, started again at the end ------------------------------------
$appExe = Join-Path $State 'ollama app.exe'
Set-Content -LiteralPath $appExe -Value 'x'
$script:ClosedDesktopApp = @([pscustomobject]@{ Label = 'Ollama'; Path = $appExe; Service = '' })
$said = (Resume-ClosedDesktopApp -WhatIf 6>&1 | ForEach-Object { "$_" }) -join '|'
Out 'resume-whatif-starts-nothing' (-not ($said -match 'Started again'))
Out 'resume-clears-the-list' (@($script:ClosedDesktopApp).Count -eq 0)
$script:ClosedDesktopApp = @([pscustomobject]@{ Label = 'Ollama'; Path = $appExe; Service = '' })
$env:DOT_NO_RESTART = '1'
$said = (Resume-ClosedDesktopApp 6>&1 | ForEach-Object { "$_" }) -join '|'
Out 'resume-opt-out' ($said -match 'Not restarting Ollama')
Remove-Item Env:\DOT_NO_RESTART
$script:ClosedDesktopApp = @([pscustomobject]@{ Label = 'ChatGPT / Codex'; Path = ''; Service = '' })
$said = (Resume-ClosedDesktopApp 6>&1 | ForEach-Object { "$_" }) -join '|'
Out 'resume-names-what-it-cannot-start' ($said -match 'open by hand: ChatGPT / Codex')
Out 'resume-wired-ollama-launch' (@($script:AgentDesktopApp | Where-Object { $_.Label -eq 'Ollama' })[0].Launch -eq 'ollama app.exe')
PSEOF
out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Updater "$(winpath "$updater")" -Background "$(winpath "$repo_root/scripts/lib/ps-background.ps1")" -Skills "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" -Common "$(winpath "$common")" -State "$(winpath "$tmp/state")" 2>&1 | tr -d '\r')" || fail "the harness must run: $out"
expect() { if printf '%s\n' "$out" | grep -Fxq "$1"; then pass; else fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-700))"; fi; }
expect 'first-adds=1'
expect 'first-stamp=6.4.2'
expect 'second-adds=0'
expect 'second-says=True'
expect 'second-names-the-lag=True'
expect 'new-version-adds=1'
expect 'docker-missing=False'
expect 'docker-whatif=False'
expect 'resume-whatif-starts-nothing=True'
expect 'resume-clears-the-list=True'
expect 'resume-opt-out=True'
expect 'resume-names-what-it-cannot-start=True'
expect 'resume-wired-ollama-launch=True'
if grep -Fq 'Resume-ClosedDesktopApp' "$repo_root/scripts/dotupgrade.ps1"; then pass; else fail "dotupgrade.ps1 must start the closed desktop apps again"; fi

finish
