#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
ci_workflow="$repo_root/.github/workflows/ci.yml"

require() {
    grep -Fq -- "$1" "$installer" || {
        printf 'FAIL: run_onchange_install_packages.ps1.tmpl: missing %s\n' "$1" >&2
        exit 1
    }
}

# A PATH shim is not proof that the native parser builds are usable.
require 'graft --version 2>&1 | Out-Null'
require 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
require 'Python.Python.3.13'
require 'Microsoft.VisualStudio.2022.BuildTools'
require 'NPM_CONFIG_PYTHON'
require 'sys.version_info >= (3, 8)'
require 'graft telemetry disable'

# The installer must diagnose prerequisites rather than silently downloading
# a large compiler toolchain or hiding npm's native-build error.
require 'Install the C++ Build Tools manually'
require 'Install Python manually'
require 'npm install failed'

grep -Fq -- 'bash tests/graft_windows_install_contract.sh' "$ci_workflow" || {
    printf 'FAIL: ci.yml: Windows Graft contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: Windows Graft installation contract\n'
