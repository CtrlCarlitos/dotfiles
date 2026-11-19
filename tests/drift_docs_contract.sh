#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
guide="$repo_root/docs/invariants.md"
readme="$repo_root/README.md"
heading='## 23. Interpreting raw `chezmoi status`'

. "$repo_root/tests/lib.sh"

heading_count="$(grep -Fxc -- "$heading" "$guide" || true)"
if [ "$heading_count" -eq 1 ]; then
    pass
else
    fail "docs/invariants.md: expected one canonical raw chezmoi status section, found $heading_count"
fi

section="$(mktemp)"
awk -v heading="$heading" '
    $0 == heading { in_section = 1 }
    in_section && $0 == "---" { exit }
    in_section { print }
' "$guide" | tr '\n' ' ' | tr -s ' ' >"$section"

require "$section" "baseline update"
require "$section" "local conflict"
require "$section" "merge-managed rewrite"
require "$section" "pending script"
require "$section" ".gitconfig.local"
require "$section" "data.repoPolicy.enabled"
require "$readme" '[raw `chezmoi status` drift classes](docs/invariants.md#23-interpreting-raw-chezmoi-status)'

rm -f "$section"
finish
