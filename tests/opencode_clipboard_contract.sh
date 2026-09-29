#!/usr/bin/env bash
set -euo pipefail

# OpenCode copy-on-select contract: OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT
# must be set to "false" in EVERY shell that can launch opencode - both
# PowerShell profiles on Windows and .zshrc on WSL/Linux/macOS/SSH hosts - and
# docs/terminal.md must document the behavior. Unset, opencode 1.18 reads the
# flag as "disabled = true" and copies on right-click instead of on select.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

for f in \
    'Documents/PowerShell/Microsoft.PowerShell_profile.ps1' \
    'Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1'; do
    grep -Fq "\$env:OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT = 'false'" "$repo_root/$f" ||
        fail "$f: must set OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT to 'false' (highlight copies, like every terminal)"
done
grep -Fq 'export OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT=false' "$repo_root/dot_zshrc" ||
    fail "dot_zshrc: must export OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT=false"
grep -Fq 'OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT' "$repo_root/docs/terminal.md" ||
    fail "docs/terminal.md: the clipboard section must document the flag"

finish
