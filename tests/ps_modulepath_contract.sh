#!/usr/bin/env bash
set -euo pipefail

# PSModulePath guard contract: chezmoi runs .ps1 scripts with Windows
# PowerShell 5.1; when an installer/apply was launched from pwsh 7, the
# inherited module path makes 5.1 resolve Core builds of in-box modules and
# fail with "module could not be loaded" (confirmed live on Set-Acl in
# generate_identities during a fresh Windows install). Every Windows chezmoi
# .ps1 template that touches Security/Utility cmdlets must self-sanitize.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ci_workflow="$repo_root/.github/workflows/ci.yml"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

guarded=(
    run_onchange_generate_identities.ps1.tmpl
    run_onchange_install_packages.ps1.tmpl
)
for f in "${guarded[@]}"; do
    path="$repo_root/$f"
    [ -f "$path" ] || fail "$f missing"
    grep -Fq 'PSModulePath' "$path" || fail "$f: no PSModulePath sanitize guard"
    grep -Fq '\\PowerShell\\[67]\\' "$path" || fail "$f: guard does not strip Core module dirs"
    grep -Fq 'PSVersionTable.PSVersion.Major -le 5' "$path" ||
        fail "$f: guard must only rewrite the path under Windows PowerShell 5.1"
done

# run_once_windows_set-executionpolicy deliberately avoids module autoload
# (registry-only writes) - it must NOT gain the guard's Import-Module.
! grep -Fq 'Import-Module' "$repo_root/run_once_windows_set-executionpolicy.ps1.tmpl" ||
    fail "set-executionpolicy template should stay autoload-free (registry-only)"

# Profile sync under OneDrive Documents redirection: the script must exist,
# resolve the REAL Documents folder at runtime (GetFolderPath), carry the
# profile-content hash so chezmoi re-runs it exactly when profiles change,
# and be Windows-gated.
sync_t="$repo_root/run_onchange_sync_pwsh_profiles.ps1.tmpl"
[ -f "$sync_t" ] || fail "run_onchange_sync_pwsh_profiles.ps1.tmpl missing"
grep -Fq "GetFolderPath('MyDocuments')" "$sync_t" ||
    fail "profile sync must resolve the redirected Documents at runtime"
grep -Fq '# Hash: {{ include' "$sync_t" ||
    fail "profile sync must hash-key on profile contents (run_onchange trigger)"
grep -Fq 'chezmoi.os "windows"' "$sync_t" ||
    fail "profile sync must be Windows-gated"

grep -Fq -- 'bash tests/ps_modulepath_contract.sh' "$ci_workflow" || {
    printf 'FAIL: ci.yml: PSModulePath contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: PSModulePath cross-generation guard contract\n'
