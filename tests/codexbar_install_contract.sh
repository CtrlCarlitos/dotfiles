#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

require() {
    grep -Fq -- "$2" "$repo_root/$1" || {
        printf 'FAIL: %s: missing %s\n' "$1" "$2" >&2
        exit 1
    }
}

require run_onchange_install_packages.sh.tmpl 'codexbar'
require run_onchange_install_packages.ps1.tmpl 'Finesssee.Win-CodexBar'
require docs/tool-parity.md 'Win-CodexBar'
require docs/tool-parity.md 'manual Linux opt-in'
require docs/package-groups.md 'CodexBar'

printf 'PASS: CodexBar installation contract\n'
