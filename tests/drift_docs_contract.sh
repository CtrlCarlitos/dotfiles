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
require "$section" "only chezmoi's target changed"
require "$section" "review and target-apply"
require "$section" "local conflict"
require "$section" "machine and target both changed"
require "$section" "merge or move local data to its seam"
require "$section" "merge-managed rewrite"
require "$section" "app rewrote a file but forced semantics already match"
require "$section" "no cleanup solely for formatting"
require "$section" "pending script"
require "$section" "run-on-change/after script is pending"
require "$section" "operation with its own side effects"
require "$section" ".gitconfig.local"
require "$section" "data.repoPolicy.enabled"
require "$readme" '[raw `chezmoi status` drift classes](docs/invariants.md#23-interpreting-raw-chezmoi-status)'

rm -f "$section"
finish
