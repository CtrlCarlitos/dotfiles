#!/usr/bin/env bash
set -euo pipefail

# .claude/settings.json pre-approves graft for agents working in this repo. It must
# stay READ-ONLY: only the query subcommands, never a blanket `graft:*` (which would
# also pre-approve `graft upgrade`, `init`, `uninstall`, `telemetry`: network and
# config-rewriting actions). Anything else still asks.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

settings="$repo_root/.claude/settings.json"
rules="$(jq -b -r '.permissions.allow[]' "$settings")"

grep -Eq '^Bash\((npx )?graft:\*\)$' <<<"$rules" && fail "blanket graft:* allow rule is back; list read-only subcommands instead"
for sub in ask skeleton callers grep map; do
    grep -Fxq "Bash(graft $sub:*)" <<<"$rules" || fail "missing read-only allow rule: Bash(graft $sub:*)"
done
for bad in upgrade init uninstall telemetry build mcp viz; do
    grep -Eq "graft $bad" <<<"$rules" && fail "graft $bad must not be pre-approved"
done
finish
