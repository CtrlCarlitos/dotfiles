#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2317  # the sourced library consumes these
set -euo pipefail

# Graft (@nanonets/graft) was dropped from the dotfiles on 2026-10-09 (a benchmark showed no
# accuracy or cost benefit). The installers and `dot upgrade` now RETIRE it from machines an
# earlier run set it up on: the MCP entries the dotfiles registered (OpenCode, agy, Codex,
# Claude Code user scope), what `graft init` wrote for every project (hook entries, a
# statusLine, allow entries, a footer regex, the shims, its skill), the global npm package and
# ~/.graft. Only what is unambiguously graft's: everything else in those files survives, an
# entry merely NAMED graft that runs something else is kept, and a skill dir named graft whose
# SKILL.md is not graft's is kept. Quiet when there is nothing to do; idempotent.
#
# Both twins are EXECUTED against the same fixture HOME, with npm/codex/claude/graft stubbed:
#   graft_retire            scripts/lib/agent-skills.sh   (installer .sh, update_ai_tools.sh)
#   Invoke-GraftRetirement  scripts/lib/ps-skills.ps1     (installer .ps1, update_ai_tools.ps1)
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v jq >/dev/null 2>&1 || skip 'jq not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Wiring: every installer runs it unconditionally, and dot upgrade runs it on both OSes.
require "$repo_root/run_onchange_install_packages.sh.tmpl" 'graft_retire "$npm_sudo"'
require "$repo_root/scripts/update_ai_tools.sh" 'graft_retire "$npm_sudo"'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'Invoke-GraftRetirement'
require "$repo_root/scripts/update_ai_tools.ps1" 'Invoke-GraftRetirement'
for f in run_onchange_install_packages.sh.tmpl run_onchange_install_packages.ps1.tmpl scripts/update_ai_tools.sh scripts/update_ai_tools.ps1; do
    forbid "$repo_root/$f" 'npm install -g --allow-scripts={{ join'
    forbid "$repo_root/$f" 'codex mcp add graft'
    forbid "$repo_root/$f" 'graft upgrade'
done

# fixture(home): graft wiring beside the user's own entries in every file it touches.
make_home() {
    local h="$1"
    mkdir -p "$h/.config/opencode" "$h/.gemini/config" "$h/.claude/helpers" "$h/.codex/hooks/graft" \
        "$h/.claude/skills/graft" "$h/.gemini/skills/graft" "$h/.agents/skills/graft" "$h/.graft"
    printf '%s\n' '{"plugin":["superpowers"],"mcp":{"graft":{"type":"local","command":["graft","mcp"],"enabled":true},"serena":{"type":"local","command":["serena","start-mcp-server"],"enabled":true}}}' >"$h/.config/opencode/opencode.json"
    printf '%s\n' '{"mcpServers":{"graft":{"command":"graft","args":["mcp"],"forceAllToolsEager":true},"serena":{"command":"serena","args":["start-mcp-server"],"forceAllToolsEager":true}}}' >"$h/.gemini/config/mcp_config.json"
    cat >"$h/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "PostToolUse": [
      { "matcher": "Write|Edit", "hooks": [ { "type": "command", "command": "guardrail hook claude" } ] },
      { "matcher": "Write|Edit", "hooks": [ { "type": "command", "command": "node \"C:/Users/u/.claude/helpers/graft-hooks.cjs\" post-edit", "timeout": 10000 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "node \"C:/Users/u/.claude/helpers/graft-hooks.cjs\" prompt" } ] }
    ]
  },
  "statusLine": { "type": "command", "command": "node \"${CLAUDE_PROJECT_DIR:-.}/.claude/helpers/graft-statusline.cjs\"" },
  "permissions": { "allow": [ "Bash(graft:*)", "Bash(npx graft:*)", "Bash(graft-dev:*)", "Bash(git status:*)" ], "deny": [ "Bash(rm:*)" ] },
  "footerLinksRegexes": [ "graft/[\\w./-]+\\.md", "notes/.*\\.md" ]
}
EOF
    cat >"$h/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      { "id": "guardrail-codex-PostToolUse", "matcher": "^apply_patch$", "hooks": [ { "type": "command", "command": "guardrail hook codex" } ] },
      { "matcher": "apply_patch|Write", "hooks": [ { "type": "command", "command": "node \"C:/Users/u/.codex/hooks/graft/graft-hooks.cjs\" post-edit" } ] }
    ],
    "SessionStart": [
      { "matcher": "startup", "hooks": [ { "type": "command", "command": "node \"C:/Users/u/.codex/hooks/graft/graft-hooks.cjs\" session-start" } ] }
    ]
  }
}
EOF
    printf '[mcp_servers.graft]\ncommand = "npx"\nargs = ["-y", "@nanonets/graft", "mcp"]\n' >"$h/.codex/config.toml"
    printf '{\n  "mcpServers": {\n    "graft": {\n      "command": "graft",\n      "args": ["mcp"]\n    }\n  }\n}\n' >"$h/.claude.json"
    printf 'x\n' >"$h/.claude/helpers/graft-hooks.cjs"
    printf 'x\n' >"$h/.claude/helpers/graft-statusline.cjs"
    printf 'mine\n' >"$h/.claude/helpers/mine.cjs"
    printf 'x\n' >"$h/.codex/hooks/graft/graft-hooks.cjs"
    printf -- '---\nname: graft\ndescription: x\n---\n' >"$h/.claude/skills/graft/SKILL.md"
    printf -- '---\nname: graft\ndescription: x\n---\n' >"$h/.gemini/skills/graft/SKILL.md"
    # a skill of the user's that happens to live in a dir called graft
    printf -- '---\nname: graft-notes\ndescription: mine\n---\n' >"$h/.agents/skills/graft/SKILL.md"
    printf '{}\n' >"$h/.graft/telemetry.json"
}

make_prefix() { # the global npm prefix, with graft installed in it
    mkdir -p "$1/lib/node_modules/@nanonets/graft/dist" "$1/node_modules/@nanonets/graft/dist"
}

# assert_home <label> <home>: graft's parts gone, everything else intact.
assert_home() {
    local label="$1" h="$2"
    [ "$(jq -c '.mcp | keys' "$h/.config/opencode/opencode.json")" = '["serena"]' ] || fail "$label: OpenCode mcp.graft must go, serena stay ($(jq -c . "$h/.config/opencode/opencode.json"))"
    [ "$(jq -c '.plugin' "$h/.config/opencode/opencode.json")" = '["superpowers"]' ] || fail "$label: OpenCode's other keys must survive"
    [ "$(jq -c '.mcpServers | keys' "$h/.gemini/config/mcp_config.json")" = '["serena"]' ] || fail "$label: agy mcpServers.graft must go, serena stay"
    local s="$h/.claude/settings.json"
    [ "$(jq -c '.hooks | keys' "$s")" = '["PostToolUse"]' ] || fail "$label: an event left with only graft's hooks must go ($(jq -c '.hooks' "$s"))"
    [ "$(jq -r '.hooks.PostToolUse | length' "$s")" = 1 ] || fail "$label: graft's PostToolUse entry must go, the guardrail one stay"
    [ "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$s")" = 'guardrail hook claude' ] || fail "$label: the user's hook must survive"
    [ "$(jq -r 'has("statusLine")' "$s")" = false ] || fail "$label: graft's statusLine must go"
    [ "$(jq -c '.permissions' "$s")" = '{"allow":["Bash(git status:*)"],"deny":["Bash(rm:*)"]}' ] || fail "$label: only graft's allow entries go ($(jq -c '.permissions' "$s"))"
    [ "$(jq -c '.footerLinksRegexes' "$s")" = '["notes/.*\\.md"]' ] || fail "$label: only graft's footer regex goes ($(jq -c '.footerLinksRegexes' "$s"))"
    [ "$(jq -r '.model' "$s")" = opus ] || fail "$label: Claude Code's other settings must survive"
    local c="$h/.codex/hooks.json"
    [ "$(jq -c '.hooks | keys' "$c")" = '["PostToolUse"]' ] || fail "$label: Codex SessionStart held only graft and must go"
    [ "$(jq -r '.hooks.PostToolUse[0].id' "$c")" = 'guardrail-codex-PostToolUse' ] || fail "$label: guardrail's Codex hook must survive"
    [ "$(jq -r '.hooks.PostToolUse | length' "$c")" = 1 ] || fail "$label: graft's Codex hook must go"
    for p in .claude/helpers/graft-hooks.cjs .claude/helpers/graft-statusline.cjs .codex/hooks/graft .claude/skills/graft .gemini/skills/graft .graft; do
        [ ! -e "$h/$p" ] || fail "$label: $p must be removed"
    done
    [ -f "$h/.claude/helpers/mine.cjs" ] || fail "$label: a helper that is not graft's must survive"
    [ -f "$h/.agents/skills/graft/SKILL.md" ] || fail "$label: a skill dir named graft whose SKILL.md is not graft's must survive"
    pass
}

# assert_kept <label> <home>: an entry named graft that runs something else is not graft's.
make_lookalike_home() {
    mkdir -p "$1/.config/opencode" "$1/.gemini/config"
    printf '%s\n' '{"mcp":{"graft":{"type":"local","command":["/opt/graftwrap/bin/run","mcp"],"enabled":true}}}' >"$1/.config/opencode/opencode.json"
    printf '%s\n' '{"mcpServers":{"graft":{"command":"my-graft-server","args":[]}}}' >"$1/.gemini/config/mcp_config.json"
}
assert_lookalike() {
    [ "$(jq -c '.mcp | keys' "$2/.config/opencode/opencode.json")" = '["graft"]' ] || fail "$1: an OpenCode entry named graft that runs something else must be kept"
    [ "$(jq -c '.mcpServers | keys' "$2/.gemini/config/mcp_config.json")" = '["graft"]' ] || fail "$1: an agy entry named graft that runs something else must be kept"
    pass
}

# --- stubs (bash twin) -----------------------------------------------------------------------
bin="$tmp/bin"
mkdir -p "$bin"
cat >"$bin/npm" <<'EOF'
#!/bin/sh
printf 'npm %s\n' "$*" >> "${STUB_LOG:?}"
if [ "$1" = prefix ] && [ "$2" = -g ]; then printf '%s\n' "${FAKE_PREFIX:?}"; exit 0; fi
if [ "$1" = uninstall ]; then
    [ "${NPM_FAIL:-0}" = 1 ] && exit 1
    rm -rf "${FAKE_PREFIX:?}/lib/node_modules/@nanonets/graft"
fi
exit 0
EOF
# codex / claude: log, and drop the entry from their config the way the real CLIs do
cat >"$bin/codex" <<'EOF'
#!/bin/sh
printf 'codex %s\n' "$*" >> "${STUB_LOG:?}"
: >"$HOME/.codex/config.toml"
EOF
cat >"$bin/claude" <<'EOF'
#!/bin/sh
printf 'claude %s\n' "$*" >> "${STUB_LOG:?}"
printf '{}\n' >"$HOME/.claude.json"
EOF
printf '#!/bin/sh\nexit 0\n' >"$bin/graft"
chmod +x "$bin/npm" "$bin/codex" "$bin/claude" "$bin/graft"
# A PATH without this machine's own tools (a real graft must never be found): the stubs, jq,
# and the base system.
syspath="$(dirname -- "$(command -v jq)"):/usr/bin:/bin"

run_sh() { # $1 = home, $2 = prefix, $3 = PATH, then extra env assignments
    local h="$1" p="$2" path="$3"
    shift 3
    env "$@" HOME="$h" PATH="$path" FAKE_PREFIX="$p" STUB_LOG="$tmp/stub.log" \
        bash -c '. "$1"; graft_retire ""' _ "$repo_root/scripts/lib/agent-skills.sh" 2>&1
}

# --- bash twin -----------------------------------------------------------------------------
home="$tmp/home-sh"; prefix="$tmp/prefix-sh"
make_home "$home"; make_prefix "$prefix"
: >"$tmp/stub.log"
out="$(run_sh "$home" "$prefix" "$bin:$syspath")"
assert_home bash "$home"
[ ! -d "$prefix/lib/node_modules/@nanonets/graft" ] || fail "bash: the npm package must be uninstalled"
grep -Fq "npm uninstall -g --prefix $prefix @nanonets/graft" "$tmp/stub.log" || fail "bash: npm uninstall must target graft's prefix (stub log: $(tr '\n' '|' <"$tmp/stub.log"))"
grep -Fxq 'codex mcp remove graft' "$tmp/stub.log" || fail "bash: Codex's graft MCP entry must be removed through the codex CLI"
grep -Fxq 'claude mcp remove graft -s user' "$tmp/stub.log" || fail "bash: Claude Code's user-scope graft MCP must be removed through the claude CLI"
printf '%s\n' "$out" | grep -Fq 'Retired Graft' || fail "bash: one line must say what was retired (got: $out)"
# idempotent and quiet: nothing left to do, nothing said, nothing uninstalled
: >"$tmp/stub.log"
out="$(run_sh "$home" "$prefix" "$bin:$syspath")"
[ -z "$out" ] || fail "bash: a second run must be silent (got: $out)"
! grep -q 'uninstall\|mcp remove' "$tmp/stub.log" || fail "bash: a second run must not uninstall or unregister anything ($(tr '\n' '|' <"$tmp/stub.log"))"
# a machine that never had graft: silent, and npm is not even asked
clean="$tmp/home-clean"; mkdir -p "$clean"
: >"$tmp/stub.log"
nograft="$tmp/bin-nograft"; mkdir -p "$nograft"; cp "$bin/npm" "$bin/codex" "$bin/claude" "$nograft/"
out="$(run_sh "$clean" "$prefix" "$nograft:$syspath")"
[ -z "$out" ] || fail "bash: a machine without graft must hear nothing (got: $out)"
[ ! -s "$tmp/stub.log" ] || fail "bash: a machine without graft must not run npm/codex/claude ($(tr '\n' '|' <"$tmp/stub.log"))"
# an uninstall that fails keeps ~/.graft (the package would recreate it) and never fails the run
home2="$tmp/home-sh-fail"; prefix2="$tmp/prefix-sh-fail"
make_home "$home2"; make_prefix "$prefix2"
if out="$(run_sh "$home2" "$prefix2" "$bin:$syspath" NPM_FAIL=1)"; then pass; else fail "bash: a failed uninstall must not fail the run"; fi
printf '%s\n' "$out" | grep -Fq 'Could not uninstall Graft' || fail "bash: a failed uninstall must warn (got: $out)"
[ -d "$home2/.graft" ] || fail "bash: ~/.graft must stay while the package is still installed"
# lookalikes
look="$tmp/home-sh-look"; make_lookalike_home "$look"
run_sh "$look" "$prefix" "$nograft:$syspath" >/dev/null
assert_lookalike bash "$look"

# --- PowerShell twin -----------------------------------------------------------------------
ps_twin() { # $1 = label, $2 = interpreter command
    local label="$1" interp="$2" h p lh
    h="$tmp/home-$label"; p="$tmp/prefix-$label"; lh="$tmp/home-$label-look"
    make_home "$h"; make_prefix "$p"; make_lookalike_home "$lh"
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$UserDir, [string]$Root, [string]$Log, [string]$Look)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib
function npm {
    Add-Content -LiteralPath $Log -Value ('npm ' + ($args -join ' '))
    if ($args[0] -eq 'root') { $Root; $global:LASTEXITCODE = 0; return }
    if ($args[0] -eq 'uninstall') { Remove-Item -LiteralPath (Join-Path $Root '@nanonets\graft') -Recurse -Force }
    $global:LASTEXITCODE = 0
}
function codex { Add-Content -LiteralPath $Log -Value ('codex ' + ($args -join ' ')); Set-Content -LiteralPath (Join-Path $env:USERPROFILE '.codex\config.toml') -Value ''; $global:LASTEXITCODE = 0 }
function claude { Add-Content -LiteralPath $Log -Value ('claude ' + ($args -join ' ')); Set-Content -LiteralPath (Join-Path $env:USERPROFILE '.claude.json') -Value '{}'; $global:LASTEXITCODE = 0 }
function graft { $global:LASTEXITCODE = 0 }
# Only the stubs above may answer: a real graft/npm on this machine must never be found.
$env:PATH = if ($env:OS -eq 'Windows_NT') { [Environment]::SystemDirectory } else { '/usr/bin:/bin' }
$env:USERPROFILE = $UserDir
$first = (Invoke-GraftRetirement 6>&1 | Out-String).Trim()
$second = (Invoke-GraftRetirement 6>&1 | Out-String).Trim()
Write-Output ('first=' + $first)
Write-Output ('second=[' + $second + ']')
$env:USERPROFILE = $Look
Remove-Item Function:\graft
$look = (Invoke-GraftRetirement 6>&1 | Out-String).Trim()
Write-Output ('look=[' + $look + ']')
PSEOF
    : >"$tmp/stub.log"
    out="$($interp -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" \
        -UserDir "$(winpath "$h")" -Root "$(winpath "$p/node_modules")" -Log "$(winpath "$tmp/stub.log")" -Look "$(winpath "$lh")" 2>&1 | tr -d '\r')" ||
        fail "$label: the harness failed: $out"
    assert_home "$label" "$h"
    assert_lookalike "$label" "$lh"
    [ ! -d "$p/node_modules/@nanonets/graft" ] || fail "$label: the npm package must be uninstalled"
    grep -Fq 'npm uninstall -g @nanonets/graft' "$tmp/stub.log" || fail "$label: npm uninstall -g @nanonets/graft must run (log: $(tr -d '\r' <"$tmp/stub.log" | tr '\n' '|'))"
    tr -d '\r' <"$tmp/stub.log" | grep -Fxq 'codex mcp remove graft' || fail "$label: Codex's graft MCP entry must be removed through the codex CLI"
    tr -d '\r' <"$tmp/stub.log" | grep -Fxq 'claude mcp remove graft -s user' || fail "$label: Claude Code's user-scope graft MCP must be removed"
    printf '%s\n' "$out" | grep -q '^first=.*Retired Graft' || fail "$label: one line must say what was retired (got: $out)"
    printf '%s\n' "$out" | grep -Fxq 'second=[]' || fail "$label: a second run must be silent (got: $out)"
    printf '%s\n' "$out" | grep -Fxq 'look=[]' || fail "$label: lookalike entries are not graft's and nothing may be said (got: $out)"
    [ "$(grep -c 'npm uninstall' "$tmp/stub.log")" = 1 ] || fail "$label: the package is uninstalled once, not again"
    # BOM-less writes (Go and Node JSON readers reject a BOM; PS 5.1 would add one with Set-Content)
    for f in .claude/settings.json .codex/hooks.json .config/opencode/opencode.json .gemini/config/mcp_config.json; do
        [ "$(head -c3 "$h/$f" | od -An -tx1 | tr -d ' \n')" != 'efbbbf' ] || fail "$label: $f must be written without a BOM"
    done
}
if command -v pwsh >/dev/null 2>&1; then
    ps_twin pwsh 'pwsh -NoProfile'
    # Windows PowerShell 5.1 serializes JSON differently (single-element arrays, escaping)
    if command -v powershell >/dev/null 2>&1; then ps_twin ps51 'powershell -NoProfile -ExecutionPolicy Bypass'; fi
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

finish
