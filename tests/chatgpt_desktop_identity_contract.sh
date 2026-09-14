#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

for file in run_onchange_install_packages.ps1.tmpl docs/package-groups.md docs/tool-parity.md; do
    grep -Fq -- '9PLM9XGG6VKS' "$repo_root/$file" || {
        printf 'FAIL: %s: missing current ChatGPT Work/Codex Store ID\n' "$file" >&2
        exit 1
    }
done

grep -Fq -- 'OpenAI.Codex' "$repo_root/run_onchange_install_packages.ps1.tmpl" || {
    printf 'FAIL: installer: missing OpenAI.Codex package identity\n' >&2
    exit 1
}

grep -Fq -- 'OpenAI.Codex' "$repo_root/.github/workflows/full-install-test.yml" || {
    printf 'FAIL: workflow: missing OpenAI.Codex package identity\n' >&2
    exit 1
}

if grep -Fq -- 'winget install --id 9NT1R1C2HH7J' "$repo_root/run_onchange_install_packages.ps1.tmpl"; then
    printf 'FAIL: installer still targets ChatGPT Classic\n' >&2
    exit 1
fi

printf 'PASS: current ChatGPT Work/Codex desktop identity\n'
