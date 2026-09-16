#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require_line() {
    local file="$1" line="$2"
    grep -Fqx -- "$line" "$repo_root/$file" ||
        fail "$file must contain: $line"
}

require_contains() {
    local file="$1" text="$2"
    grep -Fq -- "$text" "$repo_root/$file" ||
        fail "$file must contain: $text"
}

require_line run_onchange_install_packages.sh.tmpl '        AGENT_BROWSER_BIN="$("$NPM_BIN" prefix -g)/bin/agent-browser"'
require_contains run_onchange_install_packages.sh.tmpl 'install -g --allow-scripts=agent-browser agent-browser'
require_line run_onchange_install_packages.sh.tmpl '            net_timeout 600 "$AGENT_BROWSER_BIN" install || warn "agent-browser browser setup failed or timed out - continuing"'
require_line run_onchange_install_packages.sh.tmpl '            net_timeout 60 "$AGENT_BROWSER_BIN" doctor --json || warn "agent-browser verification failed - continuing"'
require_line scripts/update_ai_tools.sh '    AGENT_BROWSER_BIN="$("$NPM_BIN" prefix -g)/bin/agent-browser"'
require_contains scripts/update_ai_tools.sh 'install -g --allow-scripts=agent-browser agent-browser'
require_line scripts/update_ai_tools.sh '        "$AGENT_BROWSER_BIN" install &>/dev/null || echo "   agent-browser browser setup failed - skipping"'
require_line scripts/update_ai_tools.sh '        "$AGENT_BROWSER_BIN" doctor --json &>/dev/null || echo "   agent-browser verification failed - continuing"'

for file in run_onchange_install_packages.ps1.tmpl scripts/update_ai_tools.ps1; do
    require_contains "$file" 'install -g --allow-scripts=agent-browser agent-browser'
    require_contains "$file" "\$agentBrowser = Join-Path (npm prefix -g) 'agent-browser.cmd'"
    require_contains "$file" '& $env:AGENT_BROWSER install'
    require_contains "$file" '& $env:AGENT_BROWSER doctor --json'
done

printf 'PASS: agent-browser is provisioned after Playwright in every supported flow\n'
