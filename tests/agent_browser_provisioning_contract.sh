#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

require_line() { # exact-line match; lib's require is substring-level
    local file="$1" line="$2"
    grep -Fqx -- "$line" "$repo_root/$file" ||
        fail "$file must contain: $line"
}

require_line run_onchange_install_packages.sh.tmpl '        AGENT_BROWSER_BIN="$("$NPM_BIN" prefix -g)/bin/agent-browser"'
require "$repo_root/run_onchange_install_packages.sh.tmpl" 'install -g --allow-scripts=agent-browser agent-browser'
require_line run_onchange_install_packages.sh.tmpl '            net_timeout 600 "$AGENT_BROWSER_BIN" install || warn "agent-browser browser setup failed or timed out - continuing"'
require_line run_onchange_install_packages.sh.tmpl '            net_timeout 60 "$AGENT_BROWSER_BIN" doctor --json || warn "agent-browser verification failed - continuing"'
require_line scripts/update_ai_tools.sh '    AGENT_BROWSER_BIN="$("$NPM_BIN" prefix -g)/bin/agent-browser"'
require "$repo_root/scripts/update_ai_tools.sh" 'install -g --allow-scripts=agent-browser agent-browser'
require_line scripts/update_ai_tools.sh '        "$AGENT_BROWSER_BIN" install &>/dev/null || echo "   agent-browser browser setup failed - skipping"'
require_line scripts/update_ai_tools.sh '        "$AGENT_BROWSER_BIN" doctor --json &>/dev/null || echo "   agent-browser verification failed - continuing"'

for file in run_onchange_install_packages.ps1.tmpl scripts/update_ai_tools.ps1; do
    require "$repo_root/$file" 'install -g --allow-scripts=agent-browser agent-browser'
    require "$repo_root/$file" "\$agentBrowser = Join-Path (npm prefix -g) 'agent-browser.cmd'"
    require "$repo_root/$file" '& $env:AGENT_BROWSER install'
    require "$repo_root/$file" '& $env:AGENT_BROWSER doctor --json'
done

finish
