#!/usr/bin/env bash
set -euo pipefail

# Serena dashboard auto-open contract.
#
# Serena's MCP server opens its web dashboard in a browser tab every time a
# client starts it; with four agents each spawning their own instance that is
# a tab per session. The switch is `web_dashboard_open_on_launch` in
# ~/.serena/serena_config.yml, which `serena init` regenerates with Serena's
# default (true). The dotfiles own the value:
#   - the default is data, in .chezmoidata/agents.yaml `agents.serena.open_dashboard`
#     (false: the dashboard keeps running, it just does not pop a tab);
#   - a machine overrides it in ~/.config/chezmoi/chezmoi.toml
#     `[data.agents.serena] open_dashboard = true` (config data beats catalog data);
#   - both installer twins re-assert exactly that one line after `serena init`,
#     so a fresh machine, a Serena upgrade and an override all converge.
# The MCP registration args are not the place for it: `serena setup` writes
# those, and the config file is what every client's instance reads.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
catalog="$repo_root/.chezmoidata/agents.yaml"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
doc="$repo_root/docs/agent-context-tools.md"

. "$repo_root/tests/lib.sh"

# 1. The defaults are catalog data, under the serena key: no auto-open, and
#    the browser interface (the platform default on Windows/macOS is the
#    native app with one tray icon PER INSTANCE; every agent session and
#    every `claude -p` run spawns an instance, and exited ones leave ghost
#    icons behind - 48 were counted on 2026-09-24).
awk '/^  serena:/{on=1; next} on && /^  [^ ]/{on=0} on' "$catalog" | grep -Eq '^    open_dashboard: false$' ||
    fail ".chezmoidata/agents.yaml: agents.serena.open_dashboard must exist and default to false"
awk '/^  serena:/{on=1; next} on && /^  [^ ]/{on=0} on' "$catalog" | grep -Eq '^    dashboard_interface: browser$' ||
    fail ".chezmoidata/agents.yaml: agents.serena.dashboard_interface must exist and default to browser"

# 2. Both twins render the flag and write Serena's key, once per serena-init site.
for f in "$sh_installer" "$ps1_installer"; do
    grep -Fq '{{ .agents.serena.open_dashboard }}' "$f" ||
        fail "$f: must render agents.serena.open_dashboard"
    grep -Fq 'web_dashboard_open_on_launch' "$f" ||
        fail "$f: must write web_dashboard_open_on_launch in serena_config.yml"
    grep -Fq '{{ .agents.serena.dashboard_interface }}' "$f" ||
        fail "$f: must render agents.serena.dashboard_interface"
    grep -Fq 'web_dashboard_interface' "$f" ||
        fail "$f: must write web_dashboard_interface in serena_config.yml"
    # Command shapes only (net_timeout N serena init | -Action { serena init), not comments.
    inits=$(grep -cE 'net_timeout [0-9]+ serena init|\{ serena init ' "$f" || true)
    writes=$(grep -c '{{ .agents.serena.open_dashboard }}' "$f" || true)
    [ "$inits" -eq "$writes" ] ||
        fail "$f: every serena init site must re-assert the dashboard flag ($inits init, $writes writes)"
done

# 2b. The substitution must also fix Serena's own shipped default: the key
#     with NO value at all (confirmed directly against a real serena-agent
#     install, 2026-10-24), not only an explicit "true"/"false" line. A regex
#     that required a literal value silently left every fresh install's
#     dashboard popping a browser tab on every launch - run the REAL
#     extracted command against that exact fixture, not a copy of the regex.
sh_block="$(awk '/sed -i\.bak -E -e/{f=1} f{print} f&&/"\$SERENA_CFG"; then$/{exit}' "$sh_installer")"
[ -n "$sh_block" ] || fail "$sh_installer: could not locate the Serena dashboard sed command"
sh_cmd="${sh_block%; then}"
sh_cmd="${sh_cmd#*if }"
sh_fixture="$(mktemp)"
printf 'web_dashboard_open_on_launch:\nweb_dashboard_interface: browser\n' >"$sh_fixture"
SERENA_CFG="$sh_fixture" SERENA_OPEN=false SERENA_IFACE=browser bash -c "$sh_cmd" ||
    fail "$sh_installer: the sed command itself failed against Serena's unset default"
grep -Fxq 'web_dashboard_open_on_launch: false' "$sh_fixture" ||
    fail "$sh_installer: must rewrite Serena's unset default (not only an explicit true/false)"
rm -f "$sh_fixture" "$sh_fixture.bak"

if command -v pwsh >/dev/null 2>&1; then
    ps_fixture="$(mktemp)"
    printf 'web_dashboard_open_on_launch:\r\nweb_dashboard_interface: browser\r\n' >"$ps_fixture"
    PS_FIXTURE="$ps_fixture" pwsh -NoProfile -Command '
        $serenaOpen = "false"; $serenaIface = "browser"
        $lines = [IO.File]::ReadAllLines($env:PS_FIXTURE)
        $new = @($lines | ForEach-Object {
            $_ -replace "^web_dashboard_open_on_launch:\s*(true|false)?\s*$", "web_dashboard_open_on_launch: $serenaOpen" `
               -replace "^web_dashboard_interface:.*$", "web_dashboard_interface: $serenaIface"
        })
        [IO.File]::WriteAllLines($env:PS_FIXTURE, $new)
    ' || fail "$ps1_installer: the -replace expression itself failed against Serena's unset default"
    grep -Fxq 'web_dashboard_open_on_launch: false' "$ps_fixture" ||
        fail "$ps1_installer: must rewrite Serena's unset default (not only an explicit true/false)"
    rm -f "$ps_fixture"
else
    printf 'note: pwsh not installed - the PowerShell -replace expression is not executed\n'
fi
pass

# 3. The file is only ever edited on that one line: no rewrite from a template.
grep -Fq 'serena_config.yml' "$repo_root/.chezmoiignore" 2>/dev/null &&
    fail ".chezmoiignore: serena_config.yml is Serena's file, not a chezmoi target"
! find "$repo_root" -maxdepth 2 -name 'serena_config.yml*' -not -path '*/node_modules/*' | grep -q . ||
    fail "serena_config.yml must not be a chezmoi-managed source file; the installers edit one line in place"

# 4. The override is documented where Serena is.
grep -Fq 'dashboard_interface' "$doc" ||
    fail "docs/agent-context-tools.md: document agents.serena.dashboard_interface"
grep -Fq '[data.agents.serena]' "$doc" ||
    fail "docs/agent-context-tools.md: document the per-machine override [data.agents.serena] open_dashboard = true"

finish
