#!/usr/bin/env bash
set -euo pipefail

# OpenCode 2 on Windows loads Superpowers from the installer's path install
# (~\.config\opencode\node_modules\superpowers), a DIRECTORY plugin. A fresh
# install on the LAB-DOT-WIN-HOM VM (dotfiles#434 Run 15, 2026-11-15) showed
# three things the V1-era code got wrong for major 2:
#   - OpenCode 2 does not expand `~`: it read the V1 spelling as an npm `file:`
#     package, failed its update check on every start ("Package checks only
#     support registry and Git package specs") and left a literal `~` tree in
#     its npm cache. Superpowers' own index.js asks for an absolute path.
#   - `opencode plugin update` never moves a directory plugin, so `dot upgrade`
#     refreshed nothing (invariant 19).
#   - `opencode plugin list` never lists one, so the report always said
#     "version unknown".
#
# Executed under StrictMode on pwsh and, where it exists, Windows PowerShell 5.1:
#   a. Add-OpenCodePluginSpec -Supersedes swaps the V1 `~` entry for the
#      absolute one under V2's `plugins` key and keeps the user's entries;
#   b. Invoke-OpenCodeSuperpowersPathRefresh re-resolves the path install with
#      npm --prefix (its config dir) and reports npm's exit code;
#   c. Get-OpenCodeSuperpowersPathVersion reads the path install's package.json.
# And the major-2 Windows render writes the absolute spec with the supersede.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v python3 >/dev/null 2>&1 || skip 'python3 not installed'
shells=()
command -v pwsh >/dev/null 2>&1 && shells+=(pwsh)
command -v powershell.exe >/dev/null 2>&1 && shells+=(powershell.exe)
[ "${#shells[@]}" -gt 0 ] || skip 'no PowerShell installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
q() { # $1 = json file, $2 = python expression over d -> compact JSON
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8-sig")); print(json.dumps(eval(sys.argv[2]), separators=(",", ":")))' "$1" "$2"
}

# Stubs: an OpenCode 2 and an npm that logs its arguments, bumps the path
# install's version, and exits with $NPM_EXIT.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/opencode.ps1" <<'PSSTUB'
if ($args[0] -eq '--version') { 'opencode v2.2.7' }
exit 0
PSSTUB
cat >"$tmp/bin/npm.ps1" <<'PSSTUB'
Add-Content -LiteralPath $env:NPM_LOG -Value ($args -join ' ')
$i = [array]::IndexOf($args, '--prefix')
if ($args[0] -eq 'install' -and $i -ge 0) {
    $f = Join-Path $args[$i + 1] 'node_modules/superpowers/package.json'
    if (Test-Path $f) { Set-Content -LiteralPath $f -Value "{`n  `"name`": `"superpowers`",`n  `"version`": `"7.1.0`"`n}" }
}
exit [int]$env:NPM_EXIT
PSSTUB
# The report also asks the other harnesses; empty stubs keep it off the real CLIs.
for t in claude agy codex; do printf "if (\$args[0] -eq 'plugin') { '[]' }\nexit 0\n" >"$tmp/bin/$t.ps1"; done

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Bin, [string]$UserDir, [string]$Cfg, [string]$Spec, [string]$Old, [string]$NpmLog)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Functions, not PATH: a function wins over any command on every OS, while on Linux `$env:Path`
# is not PATH (names are case-sensitive) and the runner's real npm answered instead (#492 CI).
foreach ($t in 'opencode', 'npm', 'claude', 'agy', 'codex') {
    Set-Item -Path "function:global:$t" -Value ([scriptblock]::Create("& '$(Join-Path $Bin "$t.ps1")' @args"))
}
$env:USERPROFILE = $UserDir
$env:HOME = $UserDir
$env:NPM_LOG = $NpmLog
. $Lib
Add-OpenCodePluginSpec -Path $Cfg -Spec $Spec -Supersedes $Old
Write-Output ('version-before=' + (Get-OpenCodeSuperpowersPathVersion))
$env:NPM_EXIT = '0'
Write-Output ('refresh=' + (Invoke-OpenCodeSuperpowersPathRefresh))
Write-Output ('version-after=' + (Get-OpenCodeSuperpowersPathVersion))
$env:NPM_EXIT = '1'
Write-Output ('refresh-failed=' + (Invoke-OpenCodeSuperpowersPathRefresh))
$env:CODEX_HOME = Join-Path $UserDir '.codex'
Write-Output ('report=' + ((Write-SuperpowersReport -Upstream '7.1.0' *>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'OpenCode' }) -join '|'))
PSEOF

# shellcheck disable=SC2088  # the literal V1 spec the installer used to write
old='~/.config/opencode/node_modules/superpowers'
for sh in "${shells[@]}"; do
    home="$tmp/$sh-home"
    sp="$home/.config/opencode/node_modules/superpowers"
    mkdir -p "$sp"
    printf '{\n  "name": "superpowers",\n  "version": "7.0.2"\n}\n' >"$sp/package.json"
    spec="$(ps_path "$sh" "$sp")"
    cfg="$home/.config/opencode/opencode.json"
    printf '{"mcp":{"servers":{}},"plugins":["%s","other"]}' "$old" >"$cfg"
    : >"$tmp/$sh-npm.log"
    # `|| true`: a harness that throws must reach the assertions below, not end the test silently.
    out="$("$sh" -NoProfile -ExecutionPolicy Bypass -File "$(ps_path "$sh" "$tmp/harness.ps1")" \
        -Lib "$(ps_path "$sh" "$repo_root/scripts/lib/ps-skills.ps1")" -Bin "$(ps_path "$sh" "$tmp/bin")" \
        -UserDir "$(ps_path "$sh" "$home")" -Cfg "$(ps_path "$sh" "$cfg")" -Spec "$spec" -Old "$old" \
        -NpmLog "$(ps_path "$sh" "$tmp/$sh-npm.log")" 2>&1 | tr -d '\r' || true)"

    # a. the `~` entry is replaced in place by the absolute one; the user's entry and mcp stay.
    want="$(python3 -c 'import json,sys; print(json.dumps([sys.argv[1], "other"], separators=(",", ":")))' "$spec")"
    [ "$(q "$cfg" 'd.get("plugins")')" = "$want" ] || fail "$sh: a: plugins must be [absolute spec, other] (got $(q "$cfg" 'd.get("plugins")'); output: $out)"
    [ "$(q "$cfg" '"plugin" in d')" = 'false' ] || fail "$sh: a: a V2 machine must not gain a V1 plugin key"
    [ "$(q "$cfg" 'd["mcp"]')" = '{"servers":{}}' ] || fail "$sh: a: the mcp key must survive"

    # b./c. the refresh goes through npm --prefix on the config dir, and the version is read back.
    printf '%s\n' "$out" | grep -Fxq 'version-before=7.0.2' || fail "$sh: c: the path install's version must be read (output: $out)"
    printf '%s\n' "$out" | grep -Fxq 'refresh=True' || fail "$sh: b: a successful npm must report True (output: $out)"
    printf '%s\n' "$out" | grep -Fxq 'version-after=7.1.0' || fail "$sh: b: the refresh must update the copy OpenCode loads (output: $out)"
    printf '%s\n' "$out" | grep -Fxq 'refresh-failed=False' || fail "$sh: b: a failing npm must report False (output: $out)"
    grep -Eq '^install superpowers@git\+https://github\.com/obra/superpowers\.git --prefix [^ ]*-home[/\\]\.config[/\\]opencode ' "$tmp/$sh-npm.log" \
        || fail "$sh: b: npm must re-resolve the git spec into the prefix (log: $(cat "$tmp/$sh-npm.log"))"
    # d. the report reads the path install, not V2's plugin list (which never shows it).
    printf '%s\n' "$out" | grep -Fxq 'report=   OpenCode: 7.1.0 (current)' || fail "$sh: d: the report must name the path install's version (output: $out)"
    pass
done

# The major-2 Windows render writes the absolute directory spec and supersedes the
# `~` one; major 1 keeps the V1 spelling.
if command -v chezmoi >/dev/null 2>&1; then
    : >"$tmp/empty.toml"
    for major in 1 2; do
        chezmoi execute-template --config "$tmp/empty.toml" --source "$repo_root" \
            --override-data "{\"chezmoi\":{\"os\":\"windows\"},\"packages\":{\"opencode_cli\":true,\"agent_toolkit\":true},\"opencodeMajor\":\"$major\"}" \
            < "$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/v$major.ps1"
    done
    require "$tmp/v2.ps1" "\$ocPluginSpec = Join-Path \$ocConfigDir 'node_modules\\superpowers'"
    require "$tmp/v2.ps1" 'Add-OpenCodePluginSpec -Path $ocConfig -Spec $ocPluginSpec -Supersedes $ocSupersedes'
    forbid "$tmp/v1.ps1" "\$ocPluginSpec = Join-Path \$ocConfigDir"
    pass
else
    skip_part 'chezmoi not installed - render check skipped'
fi

finish
