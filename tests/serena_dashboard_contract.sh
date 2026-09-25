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
