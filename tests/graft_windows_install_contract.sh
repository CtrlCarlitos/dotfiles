#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/run_onchange_install_packages.ps1.tmpl"

# A PATH shim is not proof that the native parser builds are usable.
require "$installer" 'graft --version 2>&1 | Out-Null'
require "$installer" 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
require "$installer" 'Python.Python.3.13'
require "$installer" 'Microsoft.VisualStudio.2022.BuildTools'
require "$installer" 'NPM_CONFIG_PYTHON'
require "$installer" 'sys.version_info >= (3, 8)'
require "$installer" 'graft telemetry disable'

# 1.0.4 policy: with the elevation gate guaranteeing admin, the installer
# installs the Build Tools workload itself (capped, streamed, announced)
# instead of diagnosing-and-skipping - ONE elevated dotup does the whole
# chain. The manual guidance survives as the fallback when the winget
# attempt fails; npm's native-build errors are never hidden.
require "$installer" 'installing via winget (one-time, multi-GB, ~10-20 min)'
require "$installer" '"VS Build Tools install" -Seconds 1800'
require "$installer" 'Build Tools still not detected after the winget attempt'
require "$installer" 'Install the C++ Build Tools manually'
require "$installer" 'Install Python manually'
require "$installer" 'npm install failed'

# JSONC: Windows Terminal and VS Code settings.json legally carry comments
# and trailing commas; the installer must parse them tolerantly.
require "$installer" 'function ConvertFrom-JsonC'
require "$installer" 'Could not parse VS Code settings.json even as JSONC'
# Dotted keys (font, files.exclude members) must be probed via
# PSObject.Properties, never dotted into (StrictMode rejects the navigation -
# confirmed live).
require "$installer" '$vsJson.PSObject.Properties[$k]'

finish
