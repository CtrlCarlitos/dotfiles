#!/usr/bin/env bash
set -euo pipefail

# VS Code global-extensions contract: the curated list lives in
# .chezmoidata.yaml (single source of truth), rendered into BOTH installers,
# installed idempotently, gated by vscode_settings. The operator explicitly
# VETOED two extensions during curation - they must never return. SSH hosts:
# machine-local [[data.ssh_hosts]] in chezmoi.toml renders through
# private_dot_ssh/private_config.tmpl with a comment field so the config is
# self-documenting.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
data="$repo_root/.chezmoidata.yaml"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
ssh_tmpl="$repo_root/private_dot_ssh/private_config.tmpl"
vscode_hosts_tmpl="$repo_root/private_dot_ssh/private_vscode_hosts.tmpl"
config_tmpl="$repo_root/.chezmoi.toml.tmpl"
docs="$repo_root/docs/secrets.md"

. "$repo_root/tests/lib.sh"

grep -Fq 'vscode:' "$data" || fail ".chezmoidata.yaml: no vscode.extensions block"
grep -Fq 'EditorConfig.EditorConfig' "$data" || fail "data: EditorConfig missing"
grep -Fq 'ms-azuretools.vscode-docker' "$data" || fail "data: docker extension missing"
grep -Fq 'ms-azuretools.vscode-containers' "$data" || fail "data: containers extension missing"
grep -Fq 'rahulraghunathb.excel-lite' "$data" || fail "data: excel-lite missing (replaced edit-csv)"
grep -Fq 'extensions_windows:' "$data" || fail "data: no Windows-only list (remote-wsl)"

# Operator veto, contract-enforced: these must never return.
! grep -Fq 'eamodio.gitlens' "$data" || fail "data: gitlens is VETOED by the operator"
! grep -Fq 'Gruntfuggly.todo-tree' "$data" || fail "data: todo-tree is VETOED by the operator"

for f in "$sh_installer" "$ps1_installer"; do
    grep -Fq -- '--install-extension' "$f" || fail "$f: no extension install step"
done
# Node occasionally writes non-fatal warnings to stderr. Windows PowerShell
# turns those into terminating errors under the installer's global Stop
# preference, so the native extension command must scope it to Continue.
grep -Pzq 'try \{\r?\n                \$ErrorActionPreference = "Continue"\r?\n                & code --install-extension \$ext \*> \$null\r?\n            \} finally \{' "$ps1_installer" ||
    fail "$ps1_installer: VS Code extension install must tolerate native stderr"

# `dot up` installs only MISSING extensions and never forces (--force always asked the
# marketplace: one slow response cost minutes in a live run, and it upgraded silently).
# One local listing decides; `dot upgrade` owns updates.
grep -Fq -- 'code --list-extensions' "$ps1_installer" || fail "$ps1_installer: must list installed extensions once and install only the missing"
if grep -Fq -- 'install-extension $ext --force' "$ps1_installer"; then fail "$ps1_installer: --force re-installs every extension on every run"; fi
# ...in the background, alongside the AI tools (a minute on WSL on its own), and waited for after
# them, before the summary.
# Its output lands in a file (reported after the wait: tests/superpowers_refresh_contract.sh).
grep -Fq -- 'code --update-extensions >"$vscode_ext_out" 2>&1 &' "$repo_root/scripts/dotupgrade.sh" ||
    fail "dotupgrade.sh: the VS Code extension update must run in the background"
grep -Fq -- "-ArgumentList '--update-extensions' -WindowStyle Hidden -PassThru -RedirectStandardOutput" "$repo_root/scripts/dotupgrade.ps1" ||
    fail "dotupgrade.ps1: the VS Code extension update must run in the background"
awk '/update_ai_tools.sh"$/{a=NR} /wait "\$vscode_ext_pid"/{b=NR} END{exit !(a && b && a<b)}' "$repo_root/scripts/dotupgrade.sh" ||
    fail "dotupgrade.sh: the background extension update must be waited for after the AI tools"
awk '/update_ai_tools.ps1.\)/{a=NR} /vsCodeExtensionUpdate.WaitForExit/{b=NR} END{exit !(a && b && a<b)}' "$repo_root/scripts/dotupgrade.ps1" ||
    fail "dotupgrade.ps1: the background extension update must be waited for after the AI tools"

# Root cause of the blank exit code ("exited with code  - continuing", 2026-10-12, and again
# 2026-10-13 after an unrelated fix): `dot upgrade` runs under Windows PowerShell 5.1 (.NET
# Framework), where Start-Process -PassThru never turns on the Process object's exited-event
# bookkeeping - without it, .ExitCode stays unreadable forever even once HasExited is already
# true. Confirmed by reproducing it directly under powershell.exe, not pwsh (which never showed
# it) - EnableRaisingEvents right after Start-Process is the actual fix. PowerShell's
# property-get access silently swallows a .NET getter exception regardless (confirmed 2026-10-13:
# no catchable error, no $Error entry, $? stays True), so the remaining fallback below reports a
# still-null ExitCode as unreadable instead of printing it blank, rather than a try/catch (dead
# code: it could never fire). EXTRACTED from dotupgrade.ps1 and run against fakes.
if command -v pwsh >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
    # \r?: *.ps1 is eol=crlf (.gitattributes) even on a Linux checkout; the anchors would
    # otherwise never match the trailing \r (2026-10-13 CI failure - it passed locally, where
    # git-bash's awk opens files in text mode and strips \r transparently).
    awk '/^\$vsCodeExtensionUpdate = \$null\r?$/{f=1} f{print} f && /^\}\r?$/{exit}' "$repo_root/scripts/dotupgrade.ps1" >"$tmp/start_block.ps1"
    grep -Fq 'EnableRaisingEvents' "$tmp/start_block.ps1" || fail "start_block extraction lost the VS Code extension start (source shape changed?)"
    cat >"$tmp/start_harness.ps1" <<'PSEOF'
param([string]$Block)
Set-StrictMode -Version Latest
function Get-Command { param($Name, $ErrorAction) [pscustomobject]@{ Source = 'C:\fake\code.cmd' } }
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru, $RedirectStandardOutput, $RedirectStandardError)
    [pscustomobject]@{ EnableRaisingEvents = $false }
}
. $Block
Write-Output ('enableRaisingEvents=' + $vsCodeExtensionUpdate.EnableRaisingEvents)
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/start_harness.ps1")" -Block "$(winpath "$tmp/start_block.ps1")" 2>&1 | tr -d '\r')"
    printf '%s\n' "$out" | grep -Fxq 'enableRaisingEvents=True' || fail "EnableRaisingEvents must be set right after Start-Process, or .ExitCode never becomes readable under Windows PowerShell 5.1 (got: $out)"
    pass

    awk '/^if \(\$vsCodeExtensionUpdate\) \{\r?$/{f=1} f{print} f && /^\}\r?$/{exit}' "$repo_root/scripts/dotupgrade.ps1" >"$tmp/block.ps1"
    grep -Fq 'WaitForExit' "$tmp/block.ps1" || fail "block extraction lost the VS Code extension wait (source shape changed?)"
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Block, [string]$Mode)
Set-StrictMode -Version Latest
function Add-DotTimingMark { param([string]$Name) }
function Write-VSCodeExtensionsReport { param([string[]]$Lines) Write-Output ('report=' + ($Lines -join '|')) }
$script:waitCalls = @()
$vsCodeExtensionUpdate = [pscustomobject]@{ ExitCode = $null }
$vsCodeExtensionUpdate | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param($Milliseconds)
    $script:waitCalls += $Milliseconds
    # the parameterless overload returns void in real .NET - no `return` here, unlike the timed
    # overload below, so a bare call doesn't leak a stray value into the pipeline
    if ($null -eq $Milliseconds) {
        # the process has already exited, but (as in real .NET) ExitCode is not readable yet -
        # only this overload settles it (settled mode only)
        if ($Mode -eq 'settled') { $this.ExitCode = 0 }
        return
    }
    return $true
}
$vsCodeExtOut = $null
$vsCodeExtErr = $null
. $Block
Write-Output ('waits=' + ($script:waitCalls -join ','))
PSEOF
    run_mode() { pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Block "$(winpath "$tmp/block.ps1")" -Mode "$1" 2>&1 | tr -d '\r'; }

    out="$(run_mode settled)"
    printf '%s\n' "$out" | grep -Fxq 'waits=300000,' || fail "settled: expected 'waits=300000,' (got: $(printf '%s' "$out" | tr '\n' ' '))"
    printf '%s\n' "$out" | grep -Fq 'report=' || fail "settled: ExitCode read before it settled must not be misreported as a failed update (got: $out)"

    out="$(run_mode stillnull)"
    printf '%s\n' "$out" | grep -Fq 'exited, but its exit code could not be read' || fail "stillnull: a null ExitCode must say so, not print blank (got: $out)"
    pass
else
    printf 'note: pwsh not installed - the executed VS Code wait check was skipped\n'
fi

# SSH: the hosts template renders [[data.ssh_hosts]] with the self-documenting
# comment - moved out of private_config.tmpl so VS Code's remote.SSH.configFile
# can point at it alone, without the github-<user> identity aliases.
grep -Fq 'ssh_hosts' "$vscode_hosts_tmpl" || fail "vscode_hosts template: no ssh_hosts rendering"
grep -Fq 'comment' "$vscode_hosts_tmpl" || fail "vscode_hosts template: no comment field support"
grep -Fq 'ProxyJump' "$vscode_hosts_tmpl" || fail "vscode_hosts template: no proxy field support"
if grep -Fq 'range .ssh_hosts' "$ssh_tmpl"; then
    fail "private_config.tmpl: still renders [[data.ssh_hosts]] directly - must Include vscode_hosts instead"
fi
grep -Fqx 'Include vscode_hosts' "$ssh_tmpl" || fail "private_config.tmpl: no 'Include vscode_hosts' line"

# The source template keeps a separator before each valid generated alias.
grep -Fq $'{{- if and $name $hostname }}\n\n{{- if hasKey . "comment" }}' "$vscode_hosts_tmpl" ||
    fail "vscode_hosts template: generated aliases need a source separator"

# Rendered output is checked where ChezMoi is available. The lint job does not
# install it, but the platform and devcontainer jobs exercise the template.
if command -v chezmoi >/dev/null; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    : >"$tmp/chezmoi.toml"
    override='{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"accounts":[],"ssh_hosts":[{"name":"first","hostname":"first.example"},{"name":"second","hostname":"second.example"}]}'
    rendered=$(chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
        --override-data "$override" \
        <"$vscode_hosts_tmpl")
    expected=$'Host first\n    HostName first.example\n\nHost second\n    HostName second.example'
    [[ "$rendered" == *"$expected"* ]] ||
        fail "vscode_hosts template: generated aliases need one blank separator"

    # End-to-end: ~/.ssh/config Includes vscode_hosts, so a real ssh client must
    # resolve a host defined only in the second file when asked through the first.
    # An account is configured here on purpose: a preceding Host block is what
    # exposed the Include-gets-nested-under-it bug (docs/invariants.md #18).
    if command -v ssh >/dev/null 2>&1; then
        home="$tmp/home"; mkdir -p "$home/.ssh"
        config_rendered=$(chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
            --override-data '{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"accounts":[{"name":"Fixture","username":"fixture","provider":"github","key":"id_git"}]}' \
            <"$ssh_tmpl")
        printf '%s\n' "$config_rendered" >"$home/.ssh/config"
        printf '%s\n' "$rendered" >"$home/.ssh/vscode_hosts"
        resolved=$(HOME="$home" ssh -F "$home/.ssh/config" -G first 2>&1) ||
            fail "ssh -G could not resolve a host defined only in the Include'd vscode_hosts file: $resolved"
        grep -Eq '^hostname first\.example$' <<<"$resolved" ||
            fail "ssh -G first: hostname did not resolve through the Include (got: $resolved)"
    else
        printf 'note: ssh not installed - end-to-end Include check skipped\n'
    fi
fi

# Secrets pattern documented.
grep -Fqi 'ssh_hosts' "$docs" || fail "docs/secrets.md: ssh_hosts not documented"
grep -Fqi 'never' "$docs" || fail "docs/secrets.md: git-never-sees-it caveat missing"

# Machine-local drift: overrides live in [data.vscode_overrides] (NOT
# [data.vscode].extensions - a list set in the config replaces the repo's whole
# list). Both installers must read that key for extensions AND settings.
for f in "$sh_installer" "$ps1_installer"; do
    grep -Fq 'vscode_overrides' "$f" || fail "$f: no vscode_overrides merge"
    grep -Fq 'exclude_settings' "$f" || fail "$f: no settings exclusion support"
    grep -Fq 'extra_settings' "$f" || fail "$f: no extra-settings support"
done
grep -Fqi 'vscode_overrides' "$repo_root/docs/vscode.md" || fail "docs/vscode.md: overrides not documented"

# Config-template order is semantic in TOML and mirrors the operator-facing
# flow: dev_desktop, its VS Code gate, overrides, accounts, then SSH hosts.
dev_desktop_line=$(grep -n 'dev_desktop = ' "$config_tmpl" | head -n1 | cut -d: -f1)
settings_line=$(grep -n 'vscode_settings = ' "$config_tmpl" | head -n1 | cut -d: -f1)
overrides_line=$(grep -n '{{/\* vscode_overrides:' "$config_tmpl" | cut -d: -f1)
accounts_line=$(grep -n '^\[\[data\.accounts\]\]$' "$config_tmpl" | head -n1 | cut -d: -f1)
ssh_hosts_line=$(grep -n '{{/\* ssh_hosts:' "$config_tmpl" | cut -d: -f1)
(( dev_desktop_line < settings_line && settings_line < overrides_line && overrides_line < accounts_line && accounts_line < ssh_hosts_line )) || fail "config template: machine-local blocks are out of order"
for package_key in remote_access remote_access_server guardrail; do
    package_line=$(grep -n "    $package_key = " "$config_tmpl" | head -n1 | cut -d: -f1)
    (( package_line < overrides_line )) || fail "config template: $package_key must stay in [data.packages]"
done

# JSON object syntax is not TOML inline-table syntax (`:` vs `=`). Map values
# in extra_settings therefore require a TOML serializer, not toJson.
! grep -Fq '{{ $v | toJson }}' "$config_tmpl" || fail "config template: extra_settings maps emit invalid TOML JSON"
grep -Fq 'replace "[vscode_overrides" "[data.vscode_overrides"' "$config_tmpl" || fail "config template: override serializer must not redefine [data]"

# Generated config documents active machine-local blocks, not only empty ones.
grep -Fq 'VS Code Machine-Local Overrides' "$config_tmpl" || fail "config template: active VS Code overrides lack documentation"
grep -Fq 'SSH Host Aliases' "$config_tmpl" || fail "config template: active SSH hosts lack documentation"

# The gate belongs to [data.packages], alongside dev_desktop, in both installers.
for f in "$sh_installer" "$ps1_installer"; do
    grep -Fq 'hasKey .packages "vscode_settings"' "$f" || fail "$f: vscode_settings must be read from packages"
done

# Settings/extensions are independent of font installation. On Windows, the
# fonts gate therefore applies only to the Windows Terminal mutation, before
# the shared VS Code management block.
grep -Fq $'{{- if $fonts }}\nif ($wtSettings)' "$ps1_installer" ||
    fail "$ps1_installer: fonts gate must start at Windows Terminal settings"
grep -Fq $'}\n{{- end }}\n\n# User-level global settings' "$ps1_installer" ||
    fail "$ps1_installer: fonts gate must end before VS Code management"

# First-run devcontainers have no [data.packages] table. The guard must check
# for that table before reading its VS Code gate. The end-to-end devcontainer
# CI job also initializes this template on every pull request.
grep -Fq 'if and (hasKey . "packages") (hasKey .packages "vscode_settings")' "$config_tmpl" ||
    fail "config template: vscode_settings must guard a missing packages table"
if command -v chezmoi >/dev/null; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" CI=true DEVCONTAINER=true \
        chezmoi init --source="$repo_root" >/dev/null ||
        fail "config template: first-run devcontainer initialization failed"
    grep -Eq 'email[[:space:]]*=[[:space:]]*"devcontainer@local"' "$tmp/config/chezmoi/chezmoi.toml" ||
        fail "config template: first-run devcontainer identity missing"
fi

# Remote-SSH reads remote.SSH.configFile, FORCED to ~/.ssh/vscode_hosts - not
# ~/.ssh/config - so its host list excludes the github-<user> identity aliases.
# The static seed (.chezmoitemplates/vscode-settings.toml) stays plain, strict
# TOML - CI's "Validate all TOML and YAML files" step parses it with tomllib,
# so it cannot hold a template expression. The value needs this machine's home
# dir, which the seed cannot compute, so .chezmoi.toml.tmpl injects it into
# [forced] right after loading the seed (first-seed only, same as every other
# forced key - see docs/vscode.md's migration note for an existing machine).
seed="$repo_root/.chezmoitemplates/vscode-settings.toml"
config_tmpl_src="$repo_root/.chezmoi.toml.tmpl"
grep -Eq '^unset = \[\]' "$seed" || fail "vscode-settings.toml: unset must be empty by default (remote.SSH.configFile moved to forced)"
if grep -Fq 'remote.SSH.configFile' "$seed"; then
    fail "vscode-settings.toml: remote.SSH.configFile must not be a literal/template in the seed - it breaks CI's strict-TOML lint (tomllib)"
fi
if grep -Eq '^unset = \[.*"remote\.SSH\.configFile"' "$seed"; then
    fail "vscode-settings.toml: remote.SSH.configFile must not be back in the unset tier"
fi
python3 -c "import sys, tomllib; tomllib.load(sys.stdin.buffer)" <"$seed" ||
    fail "vscode-settings.toml: must be valid raw TOML (CI lints it with tomllib, unlike a .tmpl file)"
grep -Fq 'set $vscodeSettings.forced "remote.SSH.configFile"' "$config_tmpl_src" ||
    fail "config template: no longer injects remote.SSH.configFile into the forced tier"
grep -Fq 'vscode_hosts' "$config_tmpl_src" ||
    fail "config template: remote.SSH.configFile injection must point at vscode_hosts"
grep -Fq -- '(get $vsCfg "unset"' "$ps1_installer" ||
    fail "$ps1_installer: no longer renders the UNSET tier"
grep -Fq -- '(get $vsCfg "unset"' "$sh_installer" ||
    fail "$sh_installer: no longer renders the UNSET tier"

# Rendered end-to-end through the real config template (not just the seed
# fragment): a fresh machine's chezmoi.toml gets remote.SSH.configFile forced
# to an absolute path ending in .ssh/vscode_hosts.
if command -v chezmoi >/dev/null; then
    empty_cfg="$tmp/empty-for-seed.toml"
    : >"$empty_cfg"
    value=$(CI=1 chezmoi execute-template --init --config "$empty_cfg" --source "$repo_root" \
        --override-data '{"chezmoi":{"homeDir":"/home/operator"}}' \
        <"$config_tmpl_src" | python3 -c '
import sys, tomllib
data = tomllib.loads(sys.stdin.read())
print(data["data"]["vscode"]["settings"]["forced"]["remote.SSH.configFile"])
')
    [ "$value" = "/home/operator/.ssh/vscode_hosts" ] ||
        fail "config template: remote.SSH.configFile rendered '$value', want '/home/operator/.ssh/vscode_hosts'"
fi

finish
