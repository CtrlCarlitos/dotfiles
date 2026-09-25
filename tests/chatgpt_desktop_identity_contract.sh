#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

for file in run_onchange_install_packages.ps1.tmpl docs/package-groups.md docs/tool-parity.md; do
    require "$repo_root/$file" '9PLM9XGG6VKS'
done

require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'OpenAI.Codex'
require "$repo_root/.github/workflows/full-install-test.yml" 'OpenAI.Codex'

forbid "$repo_root/run_onchange_install_packages.ps1.tmpl" 'winget install --id 9NT1R1C2HH7J'
forbid "$repo_root/docs/tool-parity.md" 'existing ChatGPT Classic'

finish
