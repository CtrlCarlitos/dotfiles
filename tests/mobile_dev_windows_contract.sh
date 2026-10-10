#!/usr/bin/env bash
set -euo pipefail

# mobile_dev's Windows installer logic: Install-MobileDev in
# run_onchange_install_packages.ps1.tmpl, inserted at the shared plan's
# marked dispatch point (design doc section 3.9a), building the Android/Expo
# toolchain task by task (JDK, SDK tools, WHPX/AVD, scrcpy, the ADB bridge).
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'function Install-MobileDev'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'EclipseAdoptium.Temurin.17.JDK'

require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'commandlinetools'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'ANDROID_HOME'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'sdkmanager'

finish
