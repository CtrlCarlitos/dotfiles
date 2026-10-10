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

require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'HypervisorPlatform'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'avdmanager create avd'

require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'Genymobile.scrcpy'

require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'New-NetFirewallRule'
forbid "$repo_root/run_onchange_install_packages.ps1.tmpl" 'New-Service'
require "$repo_root/docs/mobile-development.md" 'adb -a -P 5037 nodaemon server'

# Fix pass (final-review findings, 2026-10-10):
# never flatten expanded %VAR% tokens when extending Machine PATH (raw,
# unexpanded registry read/write - validated live against this machine's
# real Machine PATH, which does carry %...% tokens).
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'DoNotExpandEnvironmentNames'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" "Set-ItemProperty -LiteralPath \$envKey -Name Path"
# JAVA_HOME from the JDK's own reported java.home, not a guessed parent of
# java.exe's path; version re-checked across every output line, not just
# the first - both validated live against representative java output.
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'XshowSettings:properties'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'java\.home'
# winget guarded + Chocolatey fallback for the JDK and scrcpy, matching the
# Global Constraint ("winget first, Chocolatey fallback") this file already
# follows for Install-Node - and never let a missing/failing winget or
# Firewall call abort the rest of the installer.
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'choco install temurin17'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'choco install scrcpy'
# sdkmanager/avdmanager output is captured and $LASTEXITCODE is checked,
# never fully discarded with *>$null - validated live against a fake
# failing and a fake succeeding tool.
forbid "$repo_root/run_onchange_install_packages.ps1.tmpl" '*>$null'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'function Invoke-MobileDevTool'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'LASTEXITCODE'
# the Firewall rule's RemoteAddress is corrected if the WSL subnet changed
# (e.g. after a reboot in NAT mode), not just checked for existing by name.
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'Get-NetFirewallAddressFilter'
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'Set-NetFirewallRule'
# the real re-entry point after declining a prompt (run_onchange only
# re-runs on a rendered-content change, not on every `dot up`) is
# documented and used in the skip messages, not a misleading "just re-run".
require "$repo_root/run_onchange_install_packages.ps1.tmpl" 'chezmoi state delete-bucket --bucket=scriptState'
require "$repo_root/docs/mobile-development.md" 'chezmoi state delete-bucket --bucket=scriptState'
# no scheduled task either - the "no new always-on service" constraint
# covers more than just Windows Services.
forbid "$repo_root/run_onchange_install_packages.ps1.tmpl" 'Register-ScheduledTask'
forbid "$repo_root/run_onchange_install_packages.ps1.tmpl" 'New-ScheduledTask'
forbid "$repo_root/run_onchange_install_packages.ps1.tmpl" 'sc.exe create'
# the Windows Firewall "Allow access" dialog for adb.exe can silently widen
# the scoped rule if clicked through carelessly - documented, not just coded.
require "$repo_root/docs/mobile-development.md" 'Allow access'

finish
