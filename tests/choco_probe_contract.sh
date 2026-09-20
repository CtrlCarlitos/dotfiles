#!/usr/bin/env bash
set -euo pipefail

# Choco probe resilience contract, born from the 2026-09-20 live incident:
# one uncapped `choco list --exact <pkg>` probe wedged pre-resolution for 77
# minutes at ~1 core (no timeout, because only installs were capped), and
# Stop-Job could not kill it - choco.exe survived its own 600s cap as an
# orphan holding Chocolatey's global mutex. Contracts:
#   1. Package inventory is ONE batched local `choco list --limit-output`
#      call (single process spawn), never a per-package probe.
#   2. The batched call is timeout-capped like every network/install step.
#   3. A failed/timed-out batch degrades to nupkg-presence checks (imperfect:
#      broken packages keep their nupkg - wiztree, live - but the registry
#      fuzzy-skip catches those apps anyway).
#   4. Invoke-WithTimeout hard-kills the job's process TREE on timeout
#      (Stop-Job leaves native children orphaned) and can collect output
#      for callers that need the result, not just the side effect.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. Batched inventory, no per-package probes.
grep -Fq 'choco list --limit-output' "$ps1_installer" ||
    fail "$ps1_installer: no batched choco list inventory"
! grep -Fq 'choco list --exact $pkg' "$ps1_installer" ||
    fail "$ps1_installer: per-package choco list probes are forbidden (2026-09-20 wedge class)"

# 2. The batch is capped. (Literal from the Invoke-WithTimeout call that
# wraps the inventory: a description string only that call site uses.)
grep -Fq 'batched choco list' "$ps1_installer" ||
    fail "$ps1_installer: batched inventory must be wrapped in Invoke-WithTimeout"

# 3. nupkg fallback when the batch is unavailable.
grep -Fq '.nupkg' "$ps1_installer" ||
    fail "$ps1_installer: no nupkg-presence fallback for a failed inventory"

# 4. Hard tree-kill on timeout + collectable output.
grep -Fq 'taskkill /PID' "$ps1_installer" ||
    fail "$ps1_installer: Invoke-WithTimeout must hard-kill the job process tree on timeout"
grep -Fq '/T /F' "$ps1_installer" ||
    fail "$ps1_installer: tree kill must be /T (children) and /F (force)"
grep -Fq 'NoStream' "$ps1_installer" ||
    fail "$ps1_installer: Invoke-WithTimeout needs an output-collecting mode for callers that use the result"

# 5. Registry fuzzy-skip anchors the package name at PREFIX. Substring
# matching let package `tree` (directory-listing CLI) match DisplayName
# "WizTree v4.32" (disk analyzer) - tree was silently never installed
# (2026-09-20, confirmed via `choco upgrade all` listing). Prefix keeps the
# legitimate catches: "wiztree" -> "WizTree v4.32", "handy" -> "Handy".
grep -Fq -- '-like "$normalizedPkg*"' "$ps1_installer" ||
    fail "$ps1_installer: registry skip must anchor the package name at prefix"
! grep -Fq -- '-like "*$normalizedPkg*"' "$ps1_installer" ||
    fail "$ps1_installer: substring fuzzy-skip is forbidden (tree/WizTree false positive)"

grep -Fq -- 'bash tests/choco_probe_contract.sh' "$repo_root/.github/workflows/ci.yml" || {
    printf 'FAIL: ci.yml: choco probe contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: choco probe resilience contracts\n'
