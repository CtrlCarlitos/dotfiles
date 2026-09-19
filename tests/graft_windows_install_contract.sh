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

# 1.0.4 policy: with the elevation gate guaranteeing admin, the installer
# installs the Build Tools workload itself (capped, streamed, announced)
# instead of diagnosing-and-skipping - ONE elevated dotup does the whole
# chain. The manual guidance survives as the fallback when the winget
# attempt fails; npm's native-build errors are never hidden.
require 'installing via winget (one-time, multi-GB, ~10-20 min)'
require '"VS Build Tools install" -Seconds 1800'
require 'Build Tools still not detected after the winget attempt'
require 'Install the C++ Build Tools manually'
require 'Install Python manually'
require 'npm install failed'

# JSONC: Windows Terminal and VS Code settings.json legally carry comments
# and trailing commas; the installer must parse them tolerantly.
require 'function ConvertFrom-JsonC'
require 'Could not parse VS Code settings.json even as JSONC'
# Dotted keys (font, files.exclude members) must be probed via
# PSObject.Properties, never dotted into (StrictMode rejects the navigation -
# confirmed live).
require '$vsJson.PSObject.Properties[$k]'

grep -Fq -- 'bash tests/graft_windows_install_contract.sh' "$ci_workflow" || {
    printf 'FAIL: ci.yml: Windows Graft contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: Windows Graft installation contract\n'
