#!/usr/bin/env bash
set -euo pipefail

# Agent config probes (scripts/lib/agent-skills.sh, twin in scripts/lib/ps-skills.ps1): answers
# from the agents' own config files instead of CLI round-trips. A no-op WSL `dot up`
# (2026-10-11) spent 17 s in install_claude_cli - `claude plugin install` 7.8 s and two
# `claude mcp get` probes 8.8 s - plus `serena setup codex` 2 s on every run, all for facts that
# sit in ~/.claude/plugins/*.json, ~/.claude.json and ~/.codex/config.toml.
#   claude_marketplace_known <name>   0 yes / 1 no / 2 unknown (no file, no jq)
#   claude_plugin_installed <id>      user scope; 0 / 1 / 2 as above
#   mcp_registered <claude|codex> <server>   0 yes / 1 no, ALWAYS definitive: the file first,
#                                            the agent's `mcp get` only when the file cannot say
# The installer skips the marketplace add, the plugin install, the three `mcp get` probes and
# `serena setup codex` when the files already say yes; `dot upgrade` keeps everything current.
# install_chatgpt_cli carries sub-marks ("Codex: ...") so a slow Codex section names its part.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
lib="$repo_root/scripts/lib/agent-skills.sh"
tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"
ps_lib="$repo_root/scripts/lib/ps-skills.ps1"
ps_tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"

command -v jq >/dev/null 2>&1 || skip 'jq not installed'
# jq ships inside /usr/bin on Linux/macOS/WSL (where the fixed PATH below already looks), but a
# Windows winget/choco install puts it somewhere else entirely - a sandboxed run here otherwise
# "can't find jq", falls back to the fake CLI, and every probe below looks broken (2026-10-24).
jq_dir="$(dirname -- "$(command -v jq)")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
mkdir -p "$home/.claude/plugins" "$home/.codex" "$tmp/bin" "$tmp/empty-home"
cat >"$home/.claude/plugins/known_marketplaces.json" <<'EOF2'
{"claude-plugins-official": {"source": {"source": "github"}}, "superpowers-marketplace": {"source": {"source": "github", "repo": "obra/superpowers-marketplace"}, "installLocation": "/x", "lastUpdated": "2026-10-11T00:00:00Z"}}
EOF2
cat >"$home/.claude/plugins/installed_plugins.json" <<'EOF2'
{"version": 2, "plugins": {"superpowers@superpowers-marketplace": [{"scope": "user", "version": "7.0.0"}, {"scope": "local", "version": "6.2.0", "projectPath": "/p"}], "other@m": [{"scope": "user", "version": "1.0.0"}], "localonly@m": [{"scope": "local", "version": "1.0.0", "projectPath": "/p"}]}}
EOF2
printf '{"mcpServers": {"maestro": {"type": "stdio", "command": "maestro", "args": ["mcp"]}}, "projects": {}}\n' >"$home/.claude.json"
printf '[mcp_servers.serena]\ncommand = "serena"\nargs = ["start-mcp-server"]\n\n[mcp_servers.agent-device]\ncommand = "agent-device"\n' >"$home/.codex/config.toml"
# fake agents: log every call; `mcp get` answers FAKE_MCP_RC
for a in claude codex; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"${CLI_LOG:?}"\ncase "$1 $2" in "mcp get") exit "${FAKE_MCP_RC:-1}" ;; esac\nexit 0\n' "$a" >"$tmp/bin/$a"
done
chmod +x "$tmp/bin"/*

run() { # <home> <fn...> -> stdout + "rc=N"
    local h="$1"; shift
    : >"$tmp/cli.log"
    HOME="$h" PATH="$tmp/bin:/usr/bin:/bin:$jq_dir" CLI_LOG="$tmp/cli.log" \
        bash -c 'set -uo pipefail; . "$1"; shift; "$@"; echo "rc=$?"' _ "$lib" "$@" 2>&1
}

# A. marketplace
[ "$(run "$home" claude_marketplace_known superpowers-marketplace)" = "rc=0" ] || fail "marketplace known: expected 0"
[ "$(run "$home" claude_marketplace_known nope)" = "rc=1" ] || fail "marketplace unknown name: expected 1"
[ "$(run "$tmp/empty-home" claude_marketplace_known superpowers-marketplace)" = "rc=2" ] || fail "marketplace, no file: expected 2 (unknown)"
pass
# B. plugin at user scope (a local-scope install alone does not count)
[ "$(run "$home" claude_plugin_installed superpowers@superpowers-marketplace)" = "rc=0" ] || fail "plugin installed (user): expected 0"
[ "$(run "$home" claude_plugin_installed localonly@m)" = "rc=1" ] || fail "plugin only at local scope: expected 1"
[ "$(run "$home" claude_plugin_installed absent@m)" = "rc=1" ] || fail "plugin absent: expected 1"
[ "$(run "$tmp/empty-home" claude_plugin_installed superpowers@superpowers-marketplace)" = "rc=2" ] || fail "plugin, no file: expected 2 (unknown)"
pass
# C. Claude MCP: the file answers, no CLI call; without the file the CLI decides
[ "$(run "$home" mcp_registered claude maestro)" = "rc=0" ] || fail "claude maestro registered (file): expected 0"
[ ! -s "$tmp/cli.log" ] || fail "claude maestro: the file answered, no CLI call allowed (log: $(/bin/cat "$tmp/cli.log"))"
[ "$(run "$home" mcp_registered claude agent-device)" = "rc=1" ] || fail "claude agent-device not in file: expected 1"
[ ! -s "$tmp/cli.log" ] || fail "claude agent-device: the file answered, no CLI call allowed"
[ "$(FAKE_MCP_RC=0 run "$tmp/empty-home" mcp_registered claude maestro)" = "rc=0" ] || fail "claude, no file, CLI says yes: expected 0"
grep -Fxq 'claude mcp get maestro' "$tmp/cli.log" || fail "claude, no file: must fall back to the CLI probe (log: $(/bin/cat "$tmp/cli.log"))"
[ "$(FAKE_MCP_RC=1 run "$tmp/empty-home" mcp_registered claude maestro)" = "rc=1" ] || fail "claude, no file, CLI says no: expected 1"
pass
# D. Codex MCP: config.toml tables
[ "$(run "$home" mcp_registered codex serena)" = "rc=0" ] || fail "codex serena registered (file): expected 0"
[ "$(run "$home" mcp_registered codex agent-device)" = "rc=0" ] || fail "codex agent-device registered (file): expected 0"
[ "$(run "$home" mcp_registered codex maestro)" = "rc=1" ] || fail "codex maestro not in file: expected 1"
[ ! -s "$tmp/cli.log" ] || fail "codex: the file answered, no CLI call allowed"
[ "$(FAKE_MCP_RC=0 run "$tmp/empty-home" mcp_registered codex serena)" = "rc=0" ] || fail "codex, no file, CLI says yes: expected 0"
grep -Fxq 'codex mcp get serena' "$tmp/cli.log" || fail "codex, no file: must fall back to the CLI probe"
pass

# D2. Superpowers installs for Claude Code: the same file answers the report and the update gate
# (`claude plugin update` took 14 s on WSL, 2026-10-12, to say "already at the latest version")
got="$(run "$home" claude_superpowers_installs)"
[ "$got" = "$(printf '7.0.0\tuser\t\n6.2.0\tlocal\t/p\nrc=0')" ] || fail "claude_superpowers_installs (file): got '$got'"
[ ! -s "$tmp/cli.log" ] || fail "claude_superpowers_installs: the file answered, no CLI call allowed (log: $(/bin/cat "$tmp/cli.log"))"
[ "$(run "$home" claude_superpowers_user_version)" = "$(printf '7.0.0\nrc=0')" ] || fail "claude_superpowers_user_version: expected 7.0.0"
run "$tmp/empty-home" claude_superpowers_installs >/dev/null
grep -Fxq 'claude plugin list --json' "$tmp/cli.log" || fail "claude_superpowers_installs, no file: must fall back to the CLI (log: $(/bin/cat "$tmp/cli.log"))"
[ "$(run "$tmp/empty-home" claude_superpowers_installs_file)" = "rc=2" ] || fail "claude_superpowers_installs_file, no file: expected 2 (unknown)"
mkdir -p "$tmp/empty-home/.claude/plugins" && printf 'not json\n' >"$tmp/empty-home/.claude/plugins/installed_plugins.json"
[ "$(run "$tmp/empty-home" claude_superpowers_installs_file)" = "rc=2" ] || fail "claude_superpowers_installs_file, unreadable JSON: expected 2 (unknown)"
rm -rf "$tmp/empty-home/.claude"
pass
# the updaters gate the plugin update on it and give the two Superpowers refreshes their own marks
ai_sh="$repo_root/scripts/update_ai_tools.sh"
ai_ps1="$repo_root/scripts/update_ai_tools.ps1"
require "$ai_sh" 'claude_superpowers_user_version'
require "$ai_sh" "dot_timing_mark 'Superpowers (Codex)'"
require "$ai_sh" "dot_timing_mark 'Superpowers (Claude Code)'"
require "$ai_ps1" 'Get-ClaudeSuperpowersUserVersion'
require "$ai_ps1" "Add-DotTimingMark -Name 'Superpowers (Codex)'"
require "$ai_ps1" "Add-DotTimingMark -Name 'Superpowers (Claude Code)'"

# E. the installer uses the probes; no bare CLI probe is left; Codex has sub-marks
require "$tmpl" 'claude_marketplace_known superpowers-marketplace'
require "$tmpl" 'claude_plugin_installed superpowers@superpowers-marketplace'
for pair in 'claude serena' 'claude maestro' 'claude agent-device' 'codex serena' 'codex maestro' 'codex agent-device'; do
    require "$tmpl" "mcp_registered $pair"
done
forbid "$tmpl" '! claude mcp get'
forbid "$tmpl" '! codex mcp get'
[ "$(grep -c "dot_timing_mark 'Codex: " "$tmpl")" -ge 3 ] || fail "install_chatgpt_cli: at least three 'Codex: ...' sub-marks (the 16 s WSL Codex section needs naming)"
grep -Fq 'skipping the plugin install (dot upgrade updates it)' "$tmpl" || fail "installer: an installed Superpowers for Claude Code must be reported as skipped, like Codex's"

# F. install_claude_cli, executed from the render: files say yes -> no CLI round-trip at all
if command -v chezmoi >/dev/null 2>&1; then
    render_to "$tmp/linux.sh" sh '{"core": true, "claude_cli": true, "agent_toolkit": true, "mobile_dev": true}'
    fn_body() { awk -v n="$1" 'index($0, n "() {") == 1 {f=1} f{print} f && /^}$/{exit}' "$tmp/linux.sh"; }
    fn_body install_claude_cli >"$tmp/claude-fn.sh"
    grep -q '^install_claude_cli() {' "$tmp/claude-fn.sh" || fail "render: install_claude_cli() not found"
    for b in maestro agent-device; do printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/$b"; chmod +x "$tmp/bin/$b"; done
    run_claude() { # <home>
        : >"$tmp/cli.log"
        HOME="$1" PATH="$tmp/bin:/usr/bin:/bin:$jq_dir" CLI_LOG="$tmp/cli.log" \
            bash -c 'set -uo pipefail; . "$1"; . "$2"; configure_claude_attribution() { :; }; install_claude_cli' _ "$lib" "$tmp/claude-fn.sh" 2>&1
    }
    # maestro and agent-device both registered in the fixture for this case
    printf '{"mcpServers": {"maestro": {}, "agent-device": {}}}\n' >"$home/.claude.json"
    out="$(run_claude "$home")"
    if grep -Eq 'claude (plugin|mcp)' "$tmp/cli.log"; then fail "files say installed+registered: no claude CLI call may run (log: $(tr '\n' '|' <"$tmp/cli.log"))"; else pass; fi
    case "$out" in *'Superpowers for Claude Code is installed'*) pass ;; *) fail "files say installed: must say so (output: $out)" ;; esac
    # nothing on disk: the add, the install and the probes run (the probes through the CLI)
    FAKE_MCP_RC=1 run_claude "$tmp/empty-home" >/dev/null
    grep -Fxq 'claude plugin marketplace add obra/superpowers-marketplace' "$tmp/cli.log" || fail "fresh: marketplace add must run"
    grep -Fxq 'claude plugin install superpowers@superpowers-marketplace' "$tmp/cli.log" || fail "fresh: plugin install must run"
    grep -Fxq 'claude mcp get maestro' "$tmp/cli.log" || fail "fresh: the CLI probe must decide when no file can"
    grep -Eq 'claude mcp add -s user maestro' "$tmp/cli.log" || fail "fresh, probe says no: maestro must be registered"
else
    printf 'note: chezmoi not installed - the executed installer check is skipped\n'
fi

# G. the PowerShell twin, under pwsh
if command -v pwsh >/dev/null 2>&1; then
    winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
    cat >"$tmp/ps-harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$UserHome, [string]$EmptyHome, [string]$CaseHome)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib
Write-Output ('mk-known=' + (Test-ClaudeMarketplaceKnown -Name 'superpowers-marketplace' -UserHome $UserHome))
Write-Output ('mk-other=' + (Test-ClaudeMarketplaceKnown -Name 'nope' -UserHome $UserHome))
$u = Test-ClaudeMarketplaceKnown -Name 'superpowers-marketplace' -UserHome $EmptyHome
Write-Output ('mk-nofile-null=' + ($null -eq $u))
Write-Output ('pl-user=' + (Test-ClaudePluginInstalled -Id 'superpowers@superpowers-marketplace' -UserHome $UserHome))
Write-Output ('pl-local=' + (Test-ClaudePluginInstalled -Id 'localonly@m' -UserHome $UserHome))
$u = Test-ClaudePluginInstalled -Id 'superpowers@superpowers-marketplace' -UserHome $EmptyHome
Write-Output ('pl-nofile-null=' + ($null -eq $u))
Write-Output ('mcp-claude-yes=' + (Test-McpRegistered -Agent claude -Server maestro -UserHome $UserHome))
Write-Output ('mcp-claude-no=' + (Test-McpRegistered -Agent claude -Server agent-device -UserHome $UserHome))
Write-Output ('mcp-codex-yes=' + (Test-McpRegistered -Agent codex -Server serena -UserHome $UserHome))
Write-Output ('mcp-codex-no=' + (Test-McpRegistered -Agent codex -Server maestro -UserHome $UserHome))
$u = Test-McpRegistered -Agent claude -Server maestro -UserHome $EmptyHome
# project keys that differ only by case (Windows paths) made ConvertFrom-Json throw, the probe
# returned $null and the installer ran the 11 s `claude mcp get` on every dot up (2026-10-13)
Write-Output ('mcp-case-yes=' + (Test-McpRegistered -Agent claude -Server serena -UserHome $CaseHome))
Write-Output ('mcp-case-no=' + (Test-McpRegistered -Agent claude -Server maestro -UserHome $CaseHome))
Write-Output ('mcp-nofile-null=' + ($null -eq $u))
$sp = @(Get-ClaudeSuperpowersInstallFromFile -UserHome $UserHome)
Write-Output ('sp-installs=' + (($sp | ForEach-Object { "$($_.Version):$($_.Scope):$($_.ProjectPath)" }) -join ';'))
Write-Output ('sp-user=' + (Get-ClaudeSuperpowersUserVersion -UserHome $UserHome))
$u = Get-ClaudeSuperpowersInstallFromFile -UserHome $EmptyHome
Write-Output ('sp-nofile-null=' + ($null -eq $u))
PSEOF
    printf '{"mcpServers": {"maestro": {}}}\n' >"$home/.claude.json"
    mkdir -p "$tmp/case-home"
    printf '{"projects": {"C:/p/x": {}, "c:/p/x": {}}, "mcpServers": {"serena": {}}}
' >"$tmp/case-home/.claude.json"
    ps_out="$(pwsh -NoProfile -File "$(winpath "$tmp/ps-harness.ps1")" -Lib "$(winpath "$ps_lib")" -UserHome "$(winpath "$home")" -EmptyHome "$(winpath "$tmp/empty-home")" -CaseHome "$(winpath "$tmp/case-home")" 2>&1 | tr -d '\r' || true)"
    pexpect() { printf '%s\n' "$ps_out" | grep -Fxq -- "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$ps_out" | tr '\n' '|' | cut -c1-600))"; }
    pexpect 'mk-known=True'; pexpect 'mk-other=False'; pexpect 'mk-nofile-null=True'
    pexpect 'pl-user=True'; pexpect 'pl-local=False'; pexpect 'pl-nofile-null=True'
    pexpect 'mcp-claude-yes=True'; pexpect 'mcp-claude-no=False'; pexpect 'mcp-codex-yes=True'; pexpect 'mcp-codex-no=False'; pexpect 'mcp-nofile-null=True'
    pexpect 'mcp-case-yes=True'; pexpect 'mcp-case-no=False'
    pexpect 'sp-installs=7.0.0:user:;6.2.0:local:/p'; pexpect 'sp-user=7.0.0'; pexpect 'sp-nofile-null=True'
    pass
else
    printf 'note: pwsh not installed - the PowerShell probes are not executed\n'
fi
require "$ps_tmpl" 'Test-ClaudeMarketplaceKnown -Name'
require "$ps_tmpl" 'Test-ClaudePluginInstalled -Id'
require "$ps_tmpl" 'Test-McpRegistered -Agent claude -Server serena'
require "$ps_tmpl" 'Test-McpRegistered -Agent codex -Server serena'

finish
