#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# The macOS cask list renders from the package catalog (#83); codexbar must be
# a dev_desktop cask there.
require "$repo_root/.chezmoidata/packages.yaml" 'cask: codexbar'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'Finesssee.Win-CodexBar'
require "$repo_root/docs/tool-parity.md" 'Win-CodexBar'
require "$repo_root/docs/tool-parity.md" 'manual Linux opt-in'
require "$repo_root/docs/package-groups.md" 'CodexBar'

finish
