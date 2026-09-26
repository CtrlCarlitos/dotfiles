#!/usr/bin/env bash
set -euo pipefail

# MCP autowire contract: graft + serena must load into EVERY plane's fresh
# session with zero ritual. Survey (2026-09-20, live): claude and codex
# already automagic via user-scope config; opencode only reads the mcp block
# of its GLOBAL config (graft was absent); agy defers global mcp_config.json
# entries until /mcp - its own documented fix is a plugin bundle, whose
# servers start eagerly. The installer owns both wirings; the superseded
# `agy mcp add` (writes the deferred file) must not return.
#
# Executed (v2, #135): the opencode registration, the agy plugin bundle and
# the old-global retirement/repair are extracted from BOTH RENDERED installer
# twins and run against a fixture home, then asserted on the files they
# actually write - catalog values included, so .chezmoidata/agents.yaml drift
# fails here without any source greps. The forbid-greps below stay: they pin
# the ABSENCE of the superseded/destructive idioms, which fixtures cannot
# prove.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed (the PowerShell twin blocks need it)"
command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed (rendering requires it)"
PWSH_BIN="$(command -v pwsh)"
# Some Windows hosts only carry the Store python3 alias stub (resolves, never
# runs). The sh-twin heredocs need a real interpreter; the pwsh twin does not.
PY_BIN=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then
        PY_BIN="$c"; break
    fi
done
SH_OK=1
if [ -z "$PY_BIN" ]; then
    SH_OK=0
    printf '%s\n' 'NOTE: no working python3/python - the sh-twin wiring checks are skipped (pwsh twin still runs)'
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Render both installer twins (render_to normalizes line endings) ----------
sh_rendered="$tmp/installer.sh"
render_to "$sh_rendered" sh '{"agent_toolkit": true}'

ps1_rendered="$tmp/installer.ps1"
render_to "$ps1_rendered" ps1 '{"agent_toolkit": true}'

[ -s "$sh_rendered" ] || fail "sh installer did not render"
[ -s "$ps1_rendered" ] || fail "ps1 installer did not render"

# --- PATH stubs: the registration gates on binary presence --------------------
# Extensionless shebang stubs for Linux CI; .cmd twins so Get-Command also
# resolves them under pwsh on a Windows host.
bin="$tmp/bin"
mkdir -p "$bin"
for c in serena graft opencode; do
    printf '#!/bin/sh\nexit 0\n' >"$bin/$c"
    chmod +x "$bin/$c"
    printf '@echo off\r\nexit /b 0\r\n' >"$bin/$c.cmd"
done
# The installer's own heredocs call `python3`; shim it to the real interpreter
# when only `python` exists (Windows hosts).
if [ "$SH_OK" = 1 ] && [ "$PY_BIN" != "python3" ]; then
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$PY_BIN")" >"$bin/python3"
    chmod +x "$bin/python3"
fi

# --- sh twin: extract the three regions between stable rendered anchors -------
if [ "$SH_OK" = 1 ]; then
oc_region="$tmp/oc.sh"
awk '/# opencode: global config mcp keys/{on=1} /# agy: MCP via plugin bundle/{exit} on' \
    "$sh_rendered" >"$oc_region"
agy_region="$tmp/agy.sh"
awk '/# agy: MCP via plugin bundle/{on=1} /# One-time migration/{exit} on' \
    "$sh_rendered" >"$agy_region"
retire_region="$tmp/retire.sh"
awk '/# One-time migration/{on=1} /^    # Graft \(trailhq/{exit} on' \
    "$sh_rendered" >"$retire_region"
for region in "$oc_region" "$agy_region" "$retire_region"; do
    [ -s "$region" ] || fail "$(basename -- "$region"): extraction from the rendered sh installer came up empty"
done

run_sh_regions() { # $1 = home; runs the wiring end to end
    HOME="$1" PATH="$bin:$PATH" bash -c '
        set -euo pipefail
        . "'"$repo_root"'/scripts/lib/agent-skills.sh"
        . "'"$oc_region"'"
        . "'"$agy_region"'"
        . "'"$retire_region"'"
    '
}

home="$tmp/home-sh"
mkdir -p "$home"

# 1. Fresh home: both servers registered into the GLOBAL opencode config with
#    the catalog's exact commands; plugin bundle written; absent global
#    mcp_config.json repaired to an empty mcpServers object (#334).
run_sh_regions "$home"
oc_json="$home/.config/opencode/opencode.json"
[ -f "$oc_json" ] || fail "sh twin: opencode.json was not created"
"$PY_BIN" - "$oc_json" <<'PYEOF' || fail "sh twin: opencode.json content wrong"
import json, sys
cfg = json.load(open(sys.argv[1]))
mcp = cfg.get("mcp", {})
assert mcp.get("serena") == {"type": "local", "command": ["serena", "start-mcp-server", "--context", "ide-assistant"], "enabled": True}, mcp.get("serena")
assert mcp.get("graft") == {"type": "local", "command": ["npx", "-y", "@nanonets/graft", "mcp"], "enabled": True}, mcp.get("graft")
PYEOF
agy_bundle="$home/.gemini/config/plugins/dotfiles-mcp/mcp_config.json"
[ -f "$home/.gemini/config/plugins/dotfiles-mcp/plugin.json" ] ||
    fail "sh twin: agy plugin.json missing"
"$PY_BIN" - "$agy_bundle" <<'PYEOF' || fail "sh twin: agy plugin bundle content wrong"
import json, sys
bundle = json.load(open(sys.argv[1]))
servers = bundle.get("mcpServers", {})
assert servers.get("serena") == {"command": "serena", "args": ["start-mcp-server", "--context", "ide-assistant"]}, servers.get("serena")
assert servers.get("graft") == {"command": "npx", "args": ["-y", "@nanonets/graft", "mcp"]}, servers.get("graft")
PYEOF
grep -Fq '"mcpServers": {}' "$home/.gemini/config/mcp_config.json" ||
    fail "sh twin: absent global mcp_config.json not repaired to an empty mcpServers object"

# 2. Merge, never clobber: an existing plugin key survives registration.
rm -rf "$home"
mkdir -p "$home/.config/opencode" "$home/.gemini/config"
printf '{"plugin": ["superpowers"]}\n' >"$oc_json"
printf '{"mcpServers": {"serena": {"command": "old"}, "custom": {"command": "keep-me"}}}\n' \
    >"$home/.gemini/config/mcp_config.json"
run_sh_regions "$home"
"$PY_BIN" - "$oc_json" <<'PYEOF' || fail "sh twin: registration clobbered or lost data"
import json, sys
cfg = json.load(open(sys.argv[1]))
assert cfg.get("plugin") == ["superpowers"], cfg.get("plugin")
assert "graft" in cfg.get("mcp", {}), cfg.get("mcp")
PYEOF

# 3. Retirement is surgical: only serena/graft leave the old global file,
#    which is NEVER deleted (agent-guardrails#334) - a user server survives.
"$PY_BIN" - "$home/.gemini/config/mcp_config.json" <<'PYEOF' || fail "sh twin: retirement wrong"
import json, sys
cfg = json.load(open(sys.argv[1]))
servers = cfg.get("mcpServers")
assert servers is not None, "file was replaced without mcpServers"
assert "serena" not in servers and "graft" not in servers, servers
assert servers.get("custom") == {"command": "keep-me"}, servers
PYEOF

# 4. Idempotence: a second run changes nothing (raw pre-checks, no rewrite).
before="$(cat "$oc_json")"
run_sh_regions "$home"
if [ "$before" = "$(cat "$oc_json")" ]; then pass; else fail "sh twin: re-run rewrote opencode.json (idempotence broken)"; fi

# 5. Unparsable non-empty global file is never touched; 0-byte is repaired.
printf 'not json at all\n' >"$home/.gemini/config/mcp_config.json"
run_sh_regions "$home"
[ "$(cat "$home/.gemini/config/mcp_config.json")" = "not json at all" ] ||
    fail "sh twin: an unparsable non-empty global mcp_config.json was modified"
: >"$home/.gemini/config/mcp_config.json"
run_sh_regions "$home"
grep -Fq '"mcpServers": {}' "$home/.gemini/config/mcp_config.json" ||
    fail "sh twin: 0-byte global mcp_config.json not repaired"
fi # SH_OK - sh-twin wiring checks

# --- ps1 twin: extract the mcpCatalog + wiring blocks and execute -------------
# Line ranges: start anchors are unique rendered lines; the end is the first
# column-0 closing brace after the block opens (the blocks are written with
# indented inner braces).
ps1_block() { # $1 = start anchor regex; prints start and end line numbers
    local start
    start="$(grep -nE "$1" "$ps1_rendered" | head -1 | cut -d: -f1)"
    [ -n "$start" ] || fail "ps1 render: anchor not found: $1"
    local end
    end="$(awk -v s="$start" 'NR > s && $0 == "}"{print NR; exit}' "$ps1_rendered")"
    [ -n "$end" ] || fail "ps1 render: block end not found after line $start"
    printf '%s %s' "$start" "$end"
}

catalog_range="$(grep -nE '^\$mcpCatalog = @\{' "$ps1_rendered" | head -1 | cut -d: -f1)"
[ -n "$catalog_range" ] || fail "ps1 render: \$mcpCatalog assignment not found"
catalog_end="$(awk -v s="$catalog_range" 'NR >= s && /^\}/{print NR; exit}' "$ps1_rendered")"
read -r oc_start oc_end <<<"$(ps1_block '^if \(Get-Command opencode -ErrorAction SilentlyContinue\) \{')"
agy_start="$(grep -nE '^\$agyPluginsDir' "$ps1_rendered" | head -1 | cut -d: -f1)"
[ -n "$agy_start" ] || fail "ps1 render: agy block start not found"
# End BEFORE the graft install chain that follows in the same gate: the agy
# blocks are straight-line and stop right before that comment.
agy_end="$(grep -nE '^# Graft \(trailhq/Graft\)' "$ps1_rendered" | head -1 | cut -d: -f1)"
[ -n "$agy_end" ] || fail "ps1 render: agy block end anchor not found"
agy_end=$((agy_end - 1))

fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"
cat >"$fixture" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$rendered, $catalogStart, $catalogEnd, $ocStart, $ocEnd, $agyStart, $agyEnd, $mode = $args
$fixtureHome = Join-Path ([IO.Path]::GetTempPath()) ('mcp-autowire-' + [guid]::NewGuid().ToString('N'))
$env:USERPROFILE = $fixtureHome
New-Item -ItemType Directory -Force -Path $fixtureHome | Out-Null
# grep -n line numbers are 1-based; ReadAllLines is 0-based.
$lines = [IO.File]::ReadAllLines($rendered)
function Slice([object[]]$All, [int]$From, [int]$To) { ($All[($From - 1)..($To - 1)] -join "`n") + "`n" }
$catalog = Slice $lines $catalogStart $catalogEnd
$ocBlock = Slice $lines $ocStart $ocEnd
$agyBlock = Slice $lines $agyStart $agyEnd

function Fail([string]$m) { Write-Host "FAIL: $m"; Remove-Item -Recurse -Force $fixtureHome; exit 1 }

# The registration blocks gate on Get-Command finding the stub executables the
# bash side laid out - resolved through PATH, same as production.
Invoke-Expression $catalog

# The extracted blocks address files under USERPROFILE with BACKSLASH
# literals: PS cmdlets normalize those on Linux (nested dirs) while .NET IO
# treats them as one literal name. The fixture therefore seeds and asserts
# each spelling exactly where the block uses it, and pre-creates the literal
# parents so the blocks' .NET writes can land.
$ocLit     = "$fixtureHome\.config\opencode\opencode.json"
$globalLit = "$fixtureHome\.gemini\config\mcp_config.json"
$ocN       = Join-Path $fixtureHome '.config/opencode/opencode.json'   # block reads (PS-normalized)
$globalN   = Join-Path $fixtureHome '.gemini/config/mcp_config.json'   # block reads (PS-normalized)
$bundleN   = Join-Path $fixtureHome '.gemini/config/plugins/dotfiles-mcp/mcp_config.json' # block writes (Join-Path)
[void][IO.Directory]::CreateDirectory("$fixtureHome\.config\opencode")
[void][IO.Directory]::CreateDirectory("$fixtureHome\.gemini\config")

if ($mode -eq 'fresh') {
    # Two passes, matching production: the first apply registers serena and
    # creates the mcp block as a hashtable; a graft added beside that
    # in-memory hashtable is lost until the next apply re-reads the file as
    # JSON (the registration is idempotent, chezmoi re-fires on every apply,
    # and the pre-checks keep re-registering until '"graft"' is present).
    Invoke-Expression $ocBlock
    Invoke-Expression $ocBlock
    Invoke-Expression $agyBlock
    $oc = [IO.File]::ReadAllText($ocLit) | ConvertFrom-Json
    if ((@($oc.mcp.serena.command) -join ' ') -cne 'serena start-mcp-server --context ide-assistant') { Fail "ps1 serena command wrong: $(@($oc.mcp.serena.command) -join ' ')" }
    if ((@($oc.mcp.graft.command) -join ' ') -cne 'npx -y @nanonets/graft mcp') { Fail "ps1 graft command wrong: $(@($oc.mcp.graft.command) -join ' ')" }
    if ($oc.mcp.serena.enabled -ne $true) { Fail 'ps1 serena not enabled' }
    $bundle = Get-Content $bundleN -Raw | ConvertFrom-Json
    if ((@($bundle.mcpServers.graft.args) -join ' ') -cne '-y @nanonets/graft mcp') { Fail 'ps1 bundle graft args wrong' }
    $global = [IO.File]::ReadAllText($globalLit)
    if ($global -notmatch '"mcpServers": \{\}') { Fail "ps1 repair did not write an empty mcpServers object: $global" }
}
elseif ($mode -eq 'merge') {
    # The block READS the existing config through PS-normalized spelling.
    $ocDir = New-Item -ItemType Directory -Force -Path (Join-Path $fixtureHome '.config/opencode')
    [IO.File]::WriteAllText((Join-Path $ocDir 'opencode.json'), '{"plugin": ["superpowers"]}')
    Invoke-Expression $ocBlock
    Invoke-Expression $ocBlock
    # ...and WRITES through the backslash literal: assert on the literal file.
    $oc = [IO.File]::ReadAllText($ocLit) | ConvertFrom-Json
    # ConvertTo-Json may collapse a 1-element array to a scalar; @() normalizes.
    if ((@($oc.plugin) -contains 'superpowers') -and $oc.mcp.graft) {
        Write-Host '  ok: ps1 twin merged without clobbering the plugin key'
    } else {
        Fail "ps1 twin clobbered or lost data: $([IO.File]::ReadAllText($ocLit))"
    }
}
elseif ($mode -eq 'retire') {
    # Reads are PS-normalized (seed here); writes land on the backslash
    # literal (assert there).
    $gemini = New-Item -ItemType Directory -Force -Path (Join-Path $fixtureHome '.gemini/config')
    $globalPath = Join-Path $gemini 'mcp_config.json'
    [IO.File]::WriteAllText($globalPath, '{"mcpServers": {"serena": {"command": "old"}, "graft": {"command": "old"}, "custom": {"command": "keep-me"}}}')
    Invoke-Expression $agyBlock
    $after = [IO.File]::ReadAllText($globalLit) | ConvertFrom-Json
    if ($after.mcpServers.serena -or $after.mcpServers.graft) { Fail 'ps1 twin: serena/graft still in the old global file' }
    if ($after.mcpServers.custom.command -cne 'keep-me') { Fail 'ps1 twin: a user server was removed' }
    if (-not (Test-Path $globalLit)) { Fail 'ps1 twin: global file was deleted (agent-guardrails#334)' }
    # Unparsable non-empty file (in the read view) is never touched.
    [IO.File]::WriteAllText($globalPath, 'not json')
    $before = [IO.File]::ReadAllText($globalLit)
    Invoke-Expression $agyBlock
    if ([IO.File]::ReadAllText($globalLit) -cne $before) { Fail 'ps1 twin: unparsable non-empty file was modified' }
    # 0-byte file (in the read view) is repaired to the shape guardrail's
    # coverage gate needs.
    [IO.File]::WriteAllText($globalPath, '')
    Invoke-Expression $agyBlock
    $repaired = [IO.File]::ReadAllText($globalLit)
    if ($repaired -notmatch '"mcpServers": \{\}') { Fail "ps1 twin: 0-byte file not repaired: $repaired" }
}
else { Fail "unknown mode: $mode" }

Remove-Item -Recurse -Force $fixtureHome
POWERSHELL

# The fixtures gate on Get-Command finding the stub executables, so they need
# the stub bin prepended explicitly (a CI runner has none of these tools).
PATH="$bin:/usr/bin:/bin" "$PWSH_BIN" -NoProfile -File "$fixture" "$ps1_rendered" "$catalog_range" "$catalog_end" \
    "$oc_start" "$oc_end" "$agy_start" "$agy_end" fresh ||
    fail "ps1 twin: fresh-home wiring failed"
PATH="$bin:/usr/bin:/bin" "$PWSH_BIN" -NoProfile -File "$fixture" "$ps1_rendered" "$catalog_range" "$catalog_end" \
    "$oc_start" "$oc_end" "$agy_start" "$agy_end" merge ||
    fail "ps1 twin: merge-not-clobber failed"
PATH="$bin:/usr/bin:/bin" "$PWSH_BIN" -NoProfile -File "$fixture" "$ps1_rendered" "$catalog_range" "$catalog_end" \
    "$oc_start" "$oc_end" "$agy_start" "$agy_end" retire ||
    fail "ps1 twin: retirement/repair failed"
rm -f "$fixture"

# --- Absence invariants: fixtures cannot prove these, greps stay (one each) --
for f in "$repo_root/run_onchange_install_packages.ps1.tmpl" "$repo_root/run_onchange_install_packages.sh.tmpl"; do
    if grep -Fq 'agy mcp add' "$f"; then fail "$f: agy mcp add is superseded by the plugin bundle (deferred path)"; else pass; fi
done
if grep -Fq 'Remove-Item $agyGlobalMcp' "$repo_root/run_onchange_install_packages.ps1.tmpl"; then
    fail "ps1 installer: retirement must not delete the global mcp_config.json (agent-guardrails#334)"
else
    pass
fi
if grep -Fq 'os.remove(p)' "$repo_root/run_onchange_install_packages.sh.tmpl"; then
    fail "sh installer: retirement must not delete the global mcp_config.json (agent-guardrails#334)"
else
    pass
fi

finish
