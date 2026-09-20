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

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

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

# 4. Live-session gates on npm/uv upgrades (agent-guardrails guidance:
#    recreating a package dir under a live agent host breaks in-flight
#    resolution - the 2026-09-20 graft/lib-bkp class). Upgrades defer to a
#    quiet dotup instead of racing sessions.
grep -Fq 'Skipping Codex CLI upgrade' "$ps1_installer" ||
    fail "$ps1_installer: codex upgrade must defer while a codex session is live"
grep -Fq 'Skipping graft upgrade' "$ps1_installer" ||
    fail "$ps1_installer: graft upgrade must defer while agent hosts are live"
grep -Fq 'Skipping Serena upgrade' "$ps1_installer" ||
    fail "$ps1_installer: serena upgrade must defer while a serena process is live"

# 5. Defender exclusion scoping (agent-guardrails #146): exact installed
#    binary FILE path only - never widened to a directory or process name.
grep -Fq '#146' "$ps1_installer" ||
    fail "$ps1_installer: Defender exclusion must document the file-path-only scoping rule (#146)"

grep -Fq -- 'bash tests/installer_hygiene_contract.sh' "$repo_root/.github/workflows/ci.yml" || {
    printf 'FAIL: ci.yml: installer hygiene contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: installer hygiene contracts\n'
