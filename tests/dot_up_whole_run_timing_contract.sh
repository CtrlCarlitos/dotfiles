#!/usr/bin/env bash
# shellcheck disable=SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# A Windows `dot up` took 3m10s and its own "Timings (dot up, 1m38s)" line accounted for half of it
# (2026-10-12): the clock started at the first section mark, after the checks and the Node.js step, and
# nothing timed the pull, the init or the apply around the installer. Now:
#   - the profile's `dot up` prints "dot up took <total>: pull .., init .., apply .." (executed here);
#   - the installer's clock starts at 'startup' and the work before the first package section has
#     its own marks (WSL, Node.js);
#   - the two package listings at the top of the installer run without a background job: a job is a
#     second PowerShell start (about 2 s: winget list 2.7 s direct, 4.6 s through Invoke-WithTimeout),
#     so Invoke-DotNativeCapture keeps the time cap and loses the startup (executed here).
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
lib="$repo_root/scripts/lib/ps-package-inventory.ps1"

# --- wiring (works without pwsh) -----------------------------------------------------------------
first_mark() { grep -n "Add-DotTimingMark -Name '$1'" "$tmpl" | head -n 1 | cut -d: -f1; }
startup="$(first_mark startup)"; wsl="$(first_mark WSL)"; node="$(first_mark 'Node.js')"; choco="$(first_mark 'choco packages')"
for pair in "startup:$startup" "WSL:$wsl" "Node.js:$node" "choco packages:$choco"; do
    [ -n "${pair#*:}" ] || fail "the installer must mark '${pair%%:*}'"
done
if [ "$startup" -ge "$wsl" ] || [ "$wsl" -ge "$node" ] || [ "$node" -ge "$choco" ]; then
    fail "marks must run startup < WSL < Node.js < choco packages (got $startup, $wsl, $node, $choco)"
fi
pass
grep -Fq "Invoke-DotNativeCapture -FilePath 'winget'" "$tmpl" || fail "the winget inventory must use Invoke-DotNativeCapture"
grep -Fq "Invoke-DotNativeCapture -FilePath 'choco'" "$tmpl" || fail "the choco inventory must use Invoke-DotNativeCapture"
if grep -Fq 'Description "winget list (local inventory)"' "$tmpl"; then fail "the winget inventory must not go through a job (Invoke-WithTimeout)"; fi
if grep -Fq 'Description "batched choco list (local inventory)"' "$tmpl"; then fail "the choco inventory must not go through a job (Invoke-WithTimeout)"; fi
pass
for profile in Documents/PowerShell Documents/WindowsPowerShell; do
    grep -Fq 'dot up took' "$repo_root/$profile/Microsoft.PowerShell_profile.ps1" || fail "$profile: dot up must print its own timing line"
done
pass

# --- the zsh/bash dot up, executed with chezmoi stubbed (invariant #10: every dispatcher) -----------
zsh_tmp="$(mktemp -d)"
awk '/^dot\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$repo_root/dot_aliases.zsh" >"$zsh_tmp/dot.fn"
[ -s "$zsh_tmp/dot.fn" ] || fail "could not extract dot() from dot_aliases.zsh"
zsh_out="$(bash -c 'eval "$(cat "$1")"; chezmoi() { return 0; }; DOTFILES_DIR=/x dot up' _ "$zsh_tmp/dot.fn" 2>&1)"
rm -rf "$zsh_tmp"
case "$zsh_out" in
    *'dot up took '*'pull '*'init '*'apply '*) pass ;;
    *) fail "zsh/bash: dot up must end with 'dot up took <total>: pull .., init .., apply ..' (got: ${zsh_out:0:300})" ;;
esac

# --- the slow-step marks: a dot up showed 'Node.js 1m01s' and 'agent toolkit 28s' with nothing inside ---
for section in 'npm registry check' 'npm catalog tools' 'agent-browser setup' 'Serena' 'agent MCP wiring' 'Codex Superpowers' 'Codex MCP'; do
    grep -Fq "Add-DotTimingMark -Name '$section'" "$tmpl" || fail "the installer must time '$section' on its own"
done
pass
npm_check="$(grep -nF 'Get-NpmInstalledVersion -Package $npmTool' "$tmpl" | head -n 1 | cut -d: -f1)"
npm_ls="$(grep -nF 'npm ls -g --depth=0 $npmTool' "$tmpl" | head -n 1 | cut -d: -f1)"
if [ -z "$npm_check" ] || [ -z "$npm_ls" ] || [ "$npm_check" -ge "$npm_ls" ]; then fail "a global tool's package.json must be read before the slow npm ls -g"; else pass; fi

command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (executed part needs PowerShell): pwsh not installed\n'; finish; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# --- Invoke-DotNativeCapture, executed (pwsh is the program) ---------------------------------------
cat >"$tmp/capture.ps1" <<'PSEOF'
param([string]$Lib, [string]$Program)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $Lib
function Out($label, $value) { Write-Output ("$label=$value") }

$ok = Invoke-DotNativeCapture -FilePath $Program -ArgumentList @('-NoProfile', '-Command', "'alpha'; 'beta gamma'; exit 3")
Out 'text' (($ok.Text -replace "\s+", '|').Trim('|'))
Out 'exit' $ok.ExitCode
Out 'timedout-no' $ok.TimedOut
$spaced = Invoke-DotNativeCapture -FilePath $Program -ArgumentList @('-NoProfile', '-Command', 'param($a) ''x''', '-NoLogo')
Out 'spaced-ran' ($null -ne $spaced -and -not $spaced.TimedOut)
$quoted = Invoke-DotNativeCapture -FilePath $Program -ArgumentList @('-NoProfile', '-Command', 'Write-Output ''two words''')
Out 'spaced-arg' ($quoted.Text.Trim())
$big = Invoke-DotNativeCapture -FilePath $Program -ArgumentList @('-NoProfile', '-Command', '1..20000 | ForEach-Object { "line $_" }; [Console]::Error.WriteLine(("e" * 200000))')
Out 'big-lines' (@($big.Text -split "`r?`n" | Where-Object { $_ }).Count)
$watch = [Diagnostics.Stopwatch]::StartNew()
$slow = Invoke-DotNativeCapture -FilePath $Program -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -TimeoutSeconds 2
Out 'timed-out' $slow.TimedOut
Out 'cut-short' ($watch.Elapsed.TotalSeconds -lt 20)
Out 'missing' ($null -eq (Invoke-DotNativeCapture -FilePath 'definitely-not-a-program-xyz'))
PSEOF
program="$(command -v pwsh)"
out="$(pwsh -NoProfile -File "$(winpath "$tmp/capture.ps1")" -Lib "$(winpath "$lib")" -Program "$(winpath "$program")" 2>&1 | tr -d '\r')" || fail "the capture harness must run: $out"
expect() { case "$out" in *"$1"*) pass ;; *) fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-900))" ;; esac; }
expect 'text=alpha|beta|gamma'
expect 'exit=3'
expect 'timedout-no=False'
expect 'spaced-ran=True'
expect 'spaced-arg=two words'
expect 'big-lines=20000'
expect 'timed-out=True'
expect 'cut-short=True'
expect 'missing=True'

# --- the profile's dot up, executed with chezmoi stubbed -------------------------------------------
for profile in Documents/PowerShell Documents/WindowsPowerShell; do
    tr -d '\r' <"$repo_root/$profile/Microsoft.PowerShell_profile.ps1" >"$tmp/profile.ps1"
    awk '/^function dot \{/{f=1} f{print} f && /^\}$/{exit}' "$tmp/profile.ps1" >"$tmp/dot.ps1"
    [ -s "$tmp/dot.ps1" ] || { fail "could not extract the dot function from $profile"; continue; }
    cat >"$tmp/up.ps1" <<'PSEOF'
param([string]$Dot)
. $Dot
function chezmoi { $global:LASTEXITCODE = 0 }
dot up *>&1 | Out-String
PSEOF
    up_out="$(pwsh -NoProfile -File "$(winpath "$tmp/up.ps1")" -Dot "$(winpath "$tmp/dot.ps1")" 2>&1 | tr -d '\r')" || fail "$profile: dot up must run: $up_out"
    case "$up_out" in
        *'dot up took '*'pull '*'init '*'apply '*) pass ;;
        *) fail "$profile: dot up must end with 'dot up took <total>: pull .., init .., apply ..' (got: ${up_out:0:300})" ;;
    esac
done

finish
