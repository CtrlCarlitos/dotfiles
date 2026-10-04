#!/usr/bin/env bash
set -euo pipefail

# OpenCode's MCP registration must CONVERGE on the catalog, not merely register
# what is absent (#230). The installers used to add a server only when its name
# was missing from opencode.json (`grep -q '"graft"'` / `-notmatch '"graft"'`),
# so an entry written in an older form kept that form forever: OpenCode started
# graft through `npx -y @nanonets/graft mcp` (a ~46 s cold start, and a graft
# that can drift from the installed one) long after .chezmoidata/agents.yaml
# said `graft mcp`. agy's registration already refreshed its keys every run;
# OpenCode's did not.
#
# Both installer twins (invariant #10) are rendered from the real templates, the
# registration function of each is extracted and EXECUTED against the same
# scenarios:
#   a. a stale `npx -y` entry: `command` is repaired to the installed binary,
#      while `enabled` and every other key (the user's) survive;
#   b. an already-converged config is not rewritten and reports nothing;
#   c. no config at all: created with every present server;
#   d. a server whose binary is absent is neither added nor touched.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed'
command -v python3 >/dev/null 2>&1 || skip 'python3 not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

groups='"core":true,"modern_cli":true,"fonts":true,"agent_toolkit":true,"opencode_cli":true,"opencode_desktop":false,"claude_cli":true,"claude_desktop":false,"chatgpt_cli":true,"chatgpt_desktop":false,"antigravity_cli":true,"antigravity_desktop":false,"remote_access":false,"remote_access_server":false,"guardrail":false,"dev_desktop":false,"vscode_settings":false'
data() { printf '{"chezmoi":{"os":"%s","kernel":{"osrelease":"6.8.0-generic"}},"packages":{%s},"accounts":[]}' "$1" "$groups"; }
render --override-data "$(data linux)" <"$repo_root/run_onchange_install_packages.sh.tmpl" >"$tmp/install.sh"
render --override-data "$(data windows)" <"$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/install.ps1"

winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
q() { # $1 = json file, $2 = python expression over d -> compact JSON
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8-sig")); print(json.dumps(eval(sys.argv[2]), separators=(",", ":")))' "$1" "$2"
}

stale='{"plugin":["superpowers"],"mcp":{"graft":{"type":"local","command":["npx","-y","@nanonets/graft","mcp"],"enabled":false},"custom":{"type":"local","command":["mine"],"enabled":true}}}'
serena_cmd='["serena","start-mcp-server","--context","ide-assistant"]'
graft_cmd='["graft","mcp"]'

check_twin() { # $1 = label, $2 = function that runs the registration: run CONFIG NAME...
    local label="$1" run="$2" cfg before after out
    cfg="$tmp/$label.json"

    # a. stale npx entry beside a user server and a plugin key
    printf '%s' "$stale" >"$cfg"
    out="$("$run" "$cfg" serena graft)" || fail "$label: registration failed on the stale config: $out"
    [ "$(q "$cfg" 'd["mcp"]["graft"]["command"]')" = "$graft_cmd" ] ||
        fail "$label: a stale npx graft entry must be repaired to the installed binary (got $(q "$cfg" 'd["mcp"]["graft"]["command"]'))"
    [ "$(q "$cfg" 'd["mcp"]["graft"]["enabled"]')" = 'false' ] ||
        fail "$label: the repair must keep the user's enabled flag"
    [ "$(q "$cfg" 'd["mcp"]["serena"]["command"]')" = "$serena_cmd" ] ||
        fail "$label: a missing serena entry must be added from the catalog"
    [ "$(q "$cfg" 'd["plugin"]')" = '["superpowers"]' ] ||
        fail "$label: the plugin key must survive the merge"
    [ "$(q "$cfg" 'd["mcp"]["custom"]["command"]')" = '["mine"]' ] ||
        fail "$label: a user-added server must survive the merge"
    printf '%s\n' "$out" | tr -d '\r' | tr ',' '\n' | grep -Fxq graft ||
        fail "$label: the changed servers must be reported (graft missing from: $out)"

    # b. converged: a second run neither rewrites the file nor reports anything
    before="$(cksum <"$cfg")"
    out="$("$run" "$cfg" serena graft)"
    after="$(cksum <"$cfg")"
    [ "$before" = "$after" ] || fail "$label: a converged config must not be rewritten"
    [ -z "$(printf '%s' "$out" | tr -d '\r\n ')" ] || fail "$label: nothing changed, so nothing is reported (got: $out)"

    # c. no config at all: created with every present server
    rm -f "$cfg"
    "$run" "$cfg" serena graft >/dev/null || fail "$label: registration failed with no config"
    [ "$(q "$cfg" 'd["mcp"]["graft"]')" = "{\"type\":\"local\",\"command\":$graft_cmd,\"enabled\":true}" ] ||
        fail "$label: a new graft entry must be {type: local, command: graft mcp, enabled: true} (got $(q "$cfg" 'd["mcp"]["graft"]'))"

    # d. binary absent: not added, and a stale entry is left alone
    printf '%s' "$stale" >"$cfg"
    "$run" "$cfg" serena >/dev/null || fail "$label: registration failed without graft"
    [ "$(q "$cfg" 'd["mcp"]["graft"]["command"]')" = '["npx","-y","@nanonets/graft","mcp"]' ] ||
        fail "$label: graft is not installed, so its entry must not be touched"
    printf '{}' >"$cfg"
    "$run" "$cfg" serena >/dev/null || fail "$label: registration failed on an empty config"
    [ "$(q "$cfg" 'sorted(d["mcp"])')" = '["serena"]' ] ||
        fail "$label: only servers whose binary is present may be added"

    # No BOM in anything written (Go JSON consumers reject one; PS 5.1's
    # Set-Content -Encoding utf8 would add it).
    [ "$(head -c3 "$cfg" | od -An -tx1 | tr -d ' \n')" != 'efbbbf' ] ||
        fail "$label: the config must be written without a UTF-8 BOM"
    printf '  ok: %s twin converges (stale repaired, user keys kept, no rewrite when converged)\n' "$label"
}

# --- sh twin ---------------------------------------------------------------------
sh_fn="$(sed -n '/^    opencode_mcp_sync() {$/,/^    }$/p' "$tmp/install.sh")"
if [ -z "$sh_fn" ]; then
    fail 'run_onchange_install_packages.sh.tmpl: no opencode_mcp_sync function (the registration must converge, #230)'
else
    run_sh() { bash -c "$sh_fn"$'\n''opencode_mcp_sync "$@"' _ "$@"; }
    check_twin sh run_sh
fi

# --- ps1 twin --------------------------------------------------------------------
if ! command -v pwsh >/dev/null 2>&1; then
    printf 'SKIP (ps1 twin only): pwsh not installed\n'
else
    ps_catalog="$(sed -n '/^\$mcpCatalog = @{$/,/^}$/p' "$tmp/install.ps1")"
    ps_fn="$(sed -n '/^function Sync-OpenCodeMcp {$/,/^}$/p' "$tmp/install.ps1")"
    if [ -z "$ps_catalog" ]; then
        fail 'run_onchange_install_packages.ps1.tmpl: $mcpCatalog not rendered'
    elif [ -z "$ps_fn" ]; then
        fail 'run_onchange_install_packages.ps1.tmpl: no Sync-OpenCodeMcp function (the registration must converge, #230)'
    else
        {
            printf '%s\n' "$ps_catalog" "$ps_fn"
            printf '%s\n' '$names = @($args[1] -split "," | Where-Object { $_ })'
            printf '%s\n' '@(Sync-OpenCodeMcp -ConfigPath $args[0] -Catalog $mcpCatalog -Present $names) -join ","'
        } >"$tmp/sync.ps1"
        run_ps() { local cfg="$1"; shift; local IFS=,; pwsh -NoProfile -File "$(winpath "$tmp/sync.ps1")" "$(winpath "$cfg")" "$*"; }
        check_twin ps1 run_ps
        # Windows PowerShell 5.1 (the installer's real interpreter on Windows,
        # chezmoi.toml [interpreters.ps1]) serializes JSON differently from pwsh 7.
        if command -v powershell >/dev/null 2>&1; then
            run_ps51() { local cfg="$1"; shift; local IFS=,; powershell -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$tmp/sync.ps1")" "$(winpath "$cfg")" "$*"; }
            check_twin ps51 run_ps51
        fi
    fi
fi

finish
