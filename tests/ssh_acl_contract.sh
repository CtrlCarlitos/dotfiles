#!/usr/bin/env bash
set -euo pipefail

# SSH ACL contract (Windows): the owner-only lockdown in
# run_onchange_generate_identities.ps1.tmpl must not orphan children of
# ~/.ssh. Confirmed live: a this-folder-only rule made Set-Acl's DACL
# propagation strip every inherited ACE from files that relied on
# inheritance - the *.pub keys, deliberately excluded from the per-file
# owner-only pass - leaving them with an EMPTY DACL (owner's Get-Content
# denied, install aborted). The directory rule must be inheritable so
# children keep working; private keys stay strict via their own protected
# per-file DACLs.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpl="$repo_root/run_onchange_generate_identities.ps1.tmpl"

. "$repo_root/tests/lib.sh"

grep -Fq 'ContainerInherit' "$tmpl" || fail "directory ACL rule lost ContainerInherit"
grep -Fq 'ObjectInherit' "$tmpl" || fail "directory ACL rule lost ObjectInherit"
grep -Fq 'SetAccessRuleProtection($true, $false)' "$tmpl" ||
    fail "ACL must stay protected (inheritance severed from the parent's parent)"
# .pub files must stay OUT of the strict per-file pass (public keys aren't
# secret) - they ride the inheritable directory rule instead.
grep -Fq 'Extension -ne ".pub"' "$tmpl" ||
    fail ".pub exclusion missing from the private-key ACL loop"

finish
