#!/usr/bin/env bash
set -euo pipefail

# Installer hygiene contracts, each born from a 2026-09-20 live incident:
#   1. Single-flight: two concurrent dotups multiplied every choco/npm lock
#      into a night-long incident (double runs at 22:57+23:12). A second
#      instance must exit 1 BEFORE any work - chezmoi then records nothing
#      and the next dotup re-fires fully (the 1.0.3 contract).
#   2. lib-bkp\opencode cleanup: every choco upgrade while an opencode
#      session holds the binary abandons the old copy there (seen twice).
#   3. GoogleChrome handover advisory: choco-managed GoogleChrome fails
#      `choco upgrade all` on checksum lag while the installer's direct-MSI
#      Chrome block self-updates - advise the one-time uninstall.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"

. "$repo_root/tests/lib.sh"

# 1. Single-flight guard: named mutex, zero-wait, exit 1 when held.
grep -Fq 'dotfiles-install' "$ps1_installer" ||
    fail "$ps1_installer: no single-flight mutex (concurrent dotups caused the 2026-09-20 incident)"
grep -Fq 'Global\dotfiles-install' "$ps1_installer" ||
    fail "$ps1_installer: mutex must be Global (machine-wide, across elevation levels)"
grep -Pzq 'WaitOne\(0\)[\s\S]{0,400}exit 1' "$ps1_installer" ||
    fail "$ps1_installer: single-flight guard must exit 1 without doing work (re-fire contract)"

# 2. lib-bkp opencode cleanup, gated on nothing running.
grep -Fq 'lib-bkp' "$ps1_installer" ||
    fail "$ps1_installer: no lib-bkp opencode cleanup"

# 3. GoogleChrome handover advisory keyed on the batched inventory.
grep -Fq 'choco still manages GoogleChrome' "$ps1_installer" ||
    fail "$ps1_installer: no GoogleChrome handover advisory"

# 4. The installer NEVER upgrades: upgrades moved to `dot upgrade`
#    (tests/dot_cli_contract.sh pins the split). Assert the upgrade
#    literals are ABSENT here.
! grep -Fq '@openai/codex@latest' "$ps1_installer" ||
    fail "$ps1_installer: must not upgrade codex (dot upgrade owns it)"
! grep -Fq 'uv tool upgrade' "$ps1_installer" ||
    fail "$ps1_installer: must not upgrade serena (dot upgrade owns it)"
! grep -Fq 'Upgrading graft' "$ps1_installer" ||
    fail "$ps1_installer: must not upgrade graft (dot upgrade owns it)"

# 5. Guardrail installation (binary, Defender exclusion #132/#146, PATH,
#    plane wiring) lives in the agent-guardrails installer: this file only
#    runs the pinned install.ps1 and never touches Defender. The bare literal
#    'install.ps1' also matches the Chocolatey bootstrap URL
#    (community.chocolatey.org/install.ps1), so assert the function name
#    instead - a real signal that the guardrail caller is wired up.
forbid "$ps1_installer" 'Add-MpPreference'
require "$ps1_installer" 'Invoke-GuardrailInstaller'

finish
