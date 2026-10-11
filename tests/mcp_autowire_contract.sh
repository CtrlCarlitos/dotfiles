#!/usr/bin/env bash
set -euo pipefail

# MCP autowire contract: the catalog's servers (serena) must load into EVERY
# plane's fresh session with zero ritual. Survey (2026-09-20, live): claude and
# codex already automagic via user-scope config; opencode only reads the mcp
# block of its GLOBAL config (a server was absent there). agy is the #175 correction
# (2026-09-28, live): agy marks every server's tools lazy, lazy tools are
# only reachable through the generic call_mcp_tool invoker guardrail denies,
# and a plugin bundle prefixes server names into forms guardrail's registry
# does not know - so the servers are declared in the TOP-LEVEL
# mcp_config.json with forceAllToolsEager, under unprefixed names. The old
# `agy mcp add` (writes the deferred file) must not return, and the
# dotfiles-mcp plugin bundle is retired by the installer.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"

. "$repo_root/tests/lib.sh"

# 1. opencode: the catalog's servers go into the GLOBAL mcp block, both twins.
# The server table lives in .chezmoidata/agents.yaml (#83): both twins must
# render it. Graft was dropped (2026-10-09): the catalog no longer carries it.
for f in "$ps1_installer" "$sh_installer"; do
    grep -Fq '.agents.mcp' "$f" ||
        fail "$f: no MCP wiring from the agent catalog (.chezmoidata/agents.yaml)"
done
! grep -Fq 'command: graft' "$repo_root/.chezmoidata/agents.yaml" ||
    fail ".chezmoidata/agents.yaml: graft was dropped and must not be registered as an MCP server"
# The registration CONVERGES (a stale `npx -y` entry is repaired, #230); what it
# does is asserted by executing it: tests/opencode_mcp_sync_contract.sh.
grep -Fq 'function Sync-OpenCodeMcp' "$ps1_installer" ||
    fail "$ps1_installer: no registration step for opencode global (Sync-OpenCodeMcp)"
grep -Fq 'opencode_mcp_sync()' "$sh_installer" ||
    fail "$sh_installer: no registration step for opencode global (opencode_mcp_sync)"

# 2. agy: TOP-LEVEL mcp_config.json with forceAllToolsEager, both twins
#    (#175). The dotfiles-mcp plugin bundle is retired (plugin-prefixed
#    server names are unknown to guardrail; cross-source doubles);
#    `agy mcp add` stays banned.
for f in "$ps1_installer" "$sh_installer"; do
    grep -Fq 'forceAllToolsEager' "$f" ||
        fail "$f: agy MCP servers must be declared forceAllToolsEager (#175)"
    grep -Fq 'dotfiles-mcp' "$f" ||
        fail "$f: no retirement of the old dotfiles-mcp plugin bundle"
    ! grep -Fq 'plugin.json' "$f" ||
        fail "$f: must not write a plugin bundle any more (the global mcp_config.json is the source)"
    ! grep -Fq 'agy mcp add' "$f" ||
        fail "$f: agy mcp add is superseded by the forceAllToolsEager registration (deferred path)"
done

# 3. The catalog carries serena with the live-verified command: the installed
#    binary, not an npx form (#175: with an npx -y form agy exposed zero
#    tools - slow npx cold start).
grep -Fq 'args: [start-mcp-server, --context, ide-assistant]' "$repo_root/.chezmoidata/agents.yaml" ||
    fail ".chezmoidata/agents.yaml: serena MCP command changed from the live-verified form"
grep -Fq 'command: serena' "$repo_root/.chezmoidata/agents.yaml" ||
    fail ".chezmoidata/agents.yaml: serena MCP must be the installed binary, not npx (#175)"

# 4. The global mcp_config.json is NEVER deleted: guardrail's
#    `doctor --coverage antigravity` (the `guardrail setup` gate) fails hard
#    on an absent or 0-byte file (agent-guardrails#334), so an emptied file
#    keeps `"mcpServers": {}` and every run repairs an absent/0-byte one to
#    that same shape. The registration is a merge: user-added servers
#    survive.
! grep -Fq 'Remove-Item $agyGlobalMcp' "$ps1_installer" ||
    fail "$ps1_installer: must not delete the global mcp_config.json (agent-guardrails#334)"
! grep -Fq 'os.remove(p)' "$sh_installer" ||
    fail "$sh_installer: must not delete the global mcp_config.json (agent-guardrails#334)"
for f in "$ps1_installer" "$sh_installer"; do
    grep -Fq '"mcpServers": {}' "$f" ||
        fail "$f: must leave/repair the global mcp_config.json as an empty mcpServers object"
done
grep -Fq -- '-not (Test-Path $agyGlobalMcp) -or (Get-Item $agyGlobalMcp).Length -eq 0' "$ps1_installer" ||
    fail "$ps1_installer: no absent/0-byte repair of the global mcp_config.json"
grep -Fq -- '! -s "$AGY_GLOBAL_MCP"' "$sh_installer" ||
    fail "$sh_installer: no absent/0-byte repair of the global mcp_config.json"

# 5. Expo MCP: a REMOTE catalog shape (type: remote + url - Maestro stays
#    local, design doc §3.2/§3.8), consumed by OpenCode (type: "remote",
#    url) and agy (httpUrl, oauth) ONLY. A remote entry has no binary, so it
#    is gated on mobile_dev instead of `command -v`. Claude Code/Codex Expo
#    registration is Task 3/out of scope and must stay untouched here.
require "$repo_root/.chezmoidata/agents.yaml" '    expo:'
require "$repo_root/.chezmoidata/agents.yaml" '      type: remote'
require "$repo_root/.chezmoidata/agents.yaml" 'url: https://mcp.expo.dev/mcp'
! grep -Fq 'command: graft' "$repo_root/.chezmoidata/agents.yaml" ||
    fail ".chezmoidata/agents.yaml: graft must still not be registered as an MCP server"
# The catalog comment documents the gating exception for remote entries,
# naming the flag that substitutes for the absent binary.
require "$repo_root/.chezmoidata/agents.yaml" 'A REMOTE entry has no binary'
require "$repo_root/.chezmoidata/agents.yaml" 'mobile_dev'

# opencode_mcp_sync(): a remote entry is written/repaired by `url`, not
# `command` - the local-entry code path (serena) is untouched, asserted by
# executing it in tests/opencode_mcp_sync_contract.sh.
require "$sh_installer" 'catalog[name].get("type") == "remote"'
require "$sh_installer" '"type": "remote", "url": url, "enabled": True'

# agy: a remote entry is httpUrl + oauth (+ forceAllToolsEager, #175's ruling
# applies to every transport), never command/args.
require "$sh_installer" 'srv.get("type") == "remote"'
require "$sh_installer" '"httpUrl": srv["url"], "oauth": {}, "forceAllToolsEager": True'

# Gating: a remote entry cannot be probed with `command -v` (it has no
# .command key); the OC_PRESENT loop must branch on the entry's shape and
# gate a remote entry on mobile_dev instead - asserted structurally here and
# behaviorally by the mobile_dev=true/false renders below.
require "$sh_installer" 'hasKey $srv "type"'
require "$sh_installer" 'eq $srv.type "remote"'

groups() { # $1 = mobile_dev bool
    printf '{"core":true,"modern_cli":true,"fonts":true,"agent_toolkit":true,"opencode_cli":true,"opencode_desktop":false,"claude_cli":true,"claude_desktop":false,"chatgpt_cli":true,"chatgpt_desktop":false,"antigravity_cli":true,"antigravity_desktop":false,"remote_access":true,"remote_access_server":true,"guardrail":false,"dev_desktop":true,"vscode_settings":false,"mobile_dev":%s}' "$1"
}
if command -v chezmoi >/dev/null 2>&1; then
    out="$(mktemp -d)/rendered.sh"
    render_to "$out" sh "$(groups true)"
    grep -Fq 'OC_PRESENT+=("expo")' "$out" ||
        fail "render (mobile_dev=true): Expo must be added to OC_PRESENT (gated on mobile_dev, not a binary check)"
    grep -Fq 'AGY_WANT="${AGY_WANT:+$AGY_WANT,}expo"' "$out" ||
        fail "render (mobile_dev=true): Expo must be added to agy's AGY_WANT"
    bash -n "$out" || fail "rendered installer has invalid bash syntax with mobile_dev=true"
    pass

    render_to "$out" sh "$(groups false)"
    if grep -Fq 'OC_PRESENT+=("expo")' "$out" || grep -Fq 'AGY_WANT="${AGY_WANT:+$AGY_WANT,}expo"' "$out"; then
        fail "render (mobile_dev=false): Expo must not be registered for OpenCode/agy when mobile_dev is off"
    else
        pass
    fi
    bash -n "$out" || fail "rendered installer has invalid bash syntax with mobile_dev=false"
else
    skip "chezmoi not installed"
fi

# agy's remote branch CONVERGES like OpenCode's: an entry already at the catalog
# url is skipped whole, so OAuth state agy keeps inside it survives a re-run;
# only a new or drifted entry is written. Executes the real agy merge heredoc.
command -v python3 >/dev/null 2>&1 || skip 'python3 not installed'
agy_tmp="$(mktemp -d)"
render_to "$agy_tmp/rendered.sh" sh "$(groups true)"
sed -n "/python3 - \"\$AGY_GLOBAL_MCP\" \"\$AGY_WANT\" <<'PYEOF'/,/^PYEOF\$/p" "$agy_tmp/rendered.sh" | sed '1d;$d' >"$agy_tmp/merge.py"
[ -s "$agy_tmp/merge.py" ] || fail "rendered installer: no agy merge heredoc to execute"
agy_cfg="$agy_tmp/mcp_config.json"
agy_run() { python3 -I "$agy_tmp/merge.py" "$agy_cfg" expo >/dev/null; }
agy_check() { # $1 = label, $2 = python expression over d that must be True
    local got
    got="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8-sig")); print(json.dumps(bool(eval(sys.argv[2]))))' "$agy_cfg" "$2")"
    if [ "$got" = 'true' ]; then pass; else fail "agy $1 (expression: $2)"; fi
}
converged='{"httpUrl":"https://mcp.expo.dev/mcp","oauth":{"access_token":"tok","refresh_token":"ref"},"forceAllToolsEager":false}'
printf '{"mcpServers":{"expo":%s,"mine":{"command":"x","args":[]}}}' "$converged" >"$agy_cfg"
agy_run || fail "agy merge failed on an already-converged Expo entry"
agy_check 'converged entry must be left whole (oauth state and every field kept)' \
    'd["mcpServers"]["expo"] == {"httpUrl":"https://mcp.expo.dev/mcp","oauth":{"access_token":"tok","refresh_token":"ref"},"forceAllToolsEager":False}'
agy_check 'a user server beside the converged entry must survive' 'd["mcpServers"]["mine"] == {"command":"x","args":[]}'

printf '{"mcpServers":{"expo":{"httpUrl":"https://old.example/mcp","oauth":{"access_token":"tok"},"forceAllToolsEager":false}}}' >"$agy_cfg"
agy_run || fail "agy merge failed on a drifted Expo entry"
agy_check 'a drifted httpUrl must be repaired to the catalog url' \
    'd["mcpServers"]["expo"] == {"httpUrl":"https://mcp.expo.dev/mcp","oauth":{},"forceAllToolsEager":True}'

rm -f "$agy_cfg"
agy_run || fail "agy merge failed with no config"
agy_check 'a new Expo entry must be created as {httpUrl, oauth: {}, forceAllToolsEager: true}' \
    'd["mcpServers"]["expo"] == {"httpUrl":"https://mcp.expo.dev/mcp","oauth":{},"forceAllToolsEager":True}'

# 6. Maestro MCP reaches OpenCode and agy through the catalog (final fix
#    round, C1): a LOCAL entry `maestro mcp`, gated on the binary like serena.
#    Executes the real rendered sync_agent_mcp_catalog() against a scratch
#    HOME with a PATH holding only stubs, so `command -v` sees exactly the
#    binaries the fixture says are installed.
require "$repo_root/.chezmoidata/agents.yaml" '    maestro:'
require "$repo_root/.chezmoidata/agents.yaml" '      command: maestro'
require "$repo_root/.chezmoidata/agents.yaml" '      args: [mcp]'
# agy's want-list walks the catalog generically (no serena special case).
forbid "$sh_installer" 'command -v serena &>/dev/null && AGY_WANT="serena"'
sync_tmp="$(mktemp -d)"
sync_fn="$(sed -n '/^sync_agent_mcp_catalog() {$/,/^}$/p' "$agy_tmp/rendered.sh")"
[ -n "$sync_fn" ] || fail "rendered installer: no top-level sync_agent_mcp_catalog() function"
mkdir -p "$sync_tmp/bin" "$sync_tmp/home"
bash_bin="$(command -v bash)"
for tool in python3 mkdir dirname tr rm; do
    real="$(command -v "$tool")" || skip "$tool not installed"
    ln -s "$real" "$sync_tmp/bin/$tool"
done
for stub in opencode maestro serena; do
    printf '#!/bin/sh\nexit 0\n' >"$sync_tmp/bin/$stub"
    chmod +x "$sync_tmp/bin/$stub"
done
run_sync() { # runs the rendered function with HOME/PATH pointed at the fixture
    HOME="$sync_tmp/home" PATH="$sync_tmp/bin" "$bash_bin" -c \
        'info() { :; }; warn() { printf "WARN: %s\n" "$*" >&2; }; '"$sync_fn"$'\n''sync_agent_mcp_catalog'
}
run_sync || fail "sync_agent_mcp_catalog() failed on a fresh HOME"
sync_check() { # $1 = label, $2 = file, $3 = python expression over d
    local got
    got="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8-sig")); print(json.dumps(bool(eval(sys.argv[2]))))' "$2" "$3" 2>/dev/null)" || got=false
    if [ "$got" = 'true' ]; then pass; else fail "sync: $1 (expression: $3)"; fi
}
oc_json="$sync_tmp/home/.config/opencode/opencode.json"
agy_json="$sync_tmp/home/.gemini/config/mcp_config.json"
sync_check 'OpenCode must get maestro as a local `maestro mcp` server' "$oc_json" \
    'd["mcp"]["maestro"] == {"type":"local","command":["maestro","mcp"],"enabled":True}'
sync_check 'OpenCode must still get serena' "$oc_json" '"serena" in d["mcp"]'
sync_check 'OpenCode must get Expo (render has mobile_dev=true)' "$oc_json" 'd["mcp"]["expo"]["type"] == "remote"'
sync_check 'agy must get maestro as {command, args, forceAllToolsEager}' "$agy_json" \
    'd["mcpServers"]["maestro"] == {"command":"maestro","args":["mcp"],"forceAllToolsEager":True}'
sync_check 'agy must still get serena' "$agy_json" '"serena" in d["mcpServers"]'
sync_check 'agy must get Expo (render has mobile_dev=true)' "$agy_json" '"expo" in d["mcpServers"]'
# No maestro binary: no maestro entry for either agent (the local gate holds).
rm -f "$sync_tmp/bin/maestro"
rm -rf "$sync_tmp/home"
mkdir -p "$sync_tmp/home"
run_sync || fail "sync_agent_mcp_catalog() failed without maestro"
sync_check 'OpenCode must not get maestro without its binary' "$oc_json" '"maestro" not in d["mcp"]'
sync_check 'agy must not get maestro without its binary' "$agy_json" '"maestro" not in d["mcpServers"]'
rm -rf "$sync_tmp"

# 7. agent-device MCP reaches OpenCode and agy through the catalog (Task 8,
#    mirrors Maestro's section 6 exactly): a LOCAL entry `agent-device mcp`,
#    gated on the binary like serena/maestro. Proves the brief's claim that
#    OpenCode/agy need ZERO new code - adding the catalog entry alone is
#    enough for the existing generic `.agents.mcp` iteration to pick it up.
require "$repo_root/.chezmoidata/agents.yaml" '    agent-device:'
require "$repo_root/.chezmoidata/agents.yaml" '      command: agent-device'
require "$repo_root/.chezmoidata/agents.yaml" '      args: [mcp]'
sync_tmp="$(mktemp -d)"
sync_fn="$(sed -n '/^sync_agent_mcp_catalog() {$/,/^}$/p' "$agy_tmp/rendered.sh")"
[ -n "$sync_fn" ] || fail "rendered installer: no top-level sync_agent_mcp_catalog() function"
mkdir -p "$sync_tmp/bin" "$sync_tmp/home"
for tool in python3 mkdir dirname tr rm; do
    real="$(command -v "$tool")" || skip "$tool not installed"
    ln -s "$real" "$sync_tmp/bin/$tool"
done
for stub in opencode maestro serena agent-device; do
    printf '#!/bin/sh\nexit 0\n' >"$sync_tmp/bin/$stub"
    chmod +x "$sync_tmp/bin/$stub"
done
run_sync || fail "sync_agent_mcp_catalog() failed on a fresh HOME (agent-device fixture)"
oc_json="$sync_tmp/home/.config/opencode/opencode.json"
agy_json="$sync_tmp/home/.gemini/config/mcp_config.json"
sync_check 'OpenCode must get agent-device as a local `agent-device mcp` server' "$oc_json" \
    'd["mcp"]["agent-device"] == {"type":"local","command":["agent-device","mcp"],"enabled":True}'
sync_check 'OpenCode must still get maestro and serena alongside agent-device' "$oc_json" \
    '"maestro" in d["mcp"] and "serena" in d["mcp"]'
sync_check 'agy must get agent-device as {command, args, forceAllToolsEager}' "$agy_json" \
    'd["mcpServers"]["agent-device"] == {"command":"agent-device","args":["mcp"],"forceAllToolsEager":True}'
sync_check 'agy must still get maestro and serena alongside agent-device' "$agy_json" \
    '"maestro" in d["mcpServers"] and "serena" in d["mcpServers"]'
# No agent-device binary: no agent-device entry for either agent (the local gate holds).
rm -f "$sync_tmp/bin/agent-device"
rm -rf "$sync_tmp/home"
mkdir -p "$sync_tmp/home"
run_sync || fail "sync_agent_mcp_catalog() failed without agent-device"
sync_check 'OpenCode must not get agent-device without its binary' "$oc_json" '"agent-device" not in d["mcp"]'
sync_check 'agy must not get agent-device without its binary' "$agy_json" '"agent-device" not in d["mcpServers"]'
rm -rf "$sync_tmp"

# Task 4 is OpenCode/agy only (Task 3 already handled Claude Code/Codex
# Maestro registration directly) - Expo must not be wired into claude/codex
# `mcp add`.
! grep -Fq 'claude mcp add expo' "$sh_installer" ||
    fail "$sh_installer: Expo Claude Code registration is out of scope for this task"
! grep -Fq 'codex mcp add expo' "$sh_installer" ||
    fail "$sh_installer: Expo Codex registration is out of scope for this task"

finish
