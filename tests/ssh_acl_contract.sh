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

# --- EXECUTED (v2, #135): the ACL pass really produces an owner-only key, an
# inheritable directory rule, and un-orphaned children. Windows-only (Get-Acl/
# Set-Acl do not exist on pwsh/Linux - the greps above remain the CI gate, the
# execution adds the behaviour on a Windows host). The ACL region is extracted
# from a rendered template and run against a fixture ~/.ssh.
if command -v pwsh >/dev/null 2>&1 && command -v chezmoi >/dev/null 2>&1; then
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32)
            atmp="$(mktemp -d)"
            trap '[ -n "${KEEP_TMP:-}" ] || rm -rf "$atmp"' EXIT
            scratch="$atmp/repo"
            mkdir -p "$scratch"
            cp "$repo_root/.chezmoidata.yaml" "$scratch/"
            cp -r "$repo_root/.chezmoidata" "$scratch/"
            : >"$atmp/empty.toml"
            rendered="$atmp/identities.ps1"
            if chezmoi execute-template --config "$atmp/empty.toml" --source "$scratch" \
                --override-data '{"chezmoi":{"os":"windows"},"accounts":[{"name":"Test User","email":"t@example.com","username":"test","key":"id_test"}]}' \
                <"$tmpl" >"$rendered" 2>"$atmp/render.err" && [ -s "$rendered" ]; then
                region_start="$(grep -nF '$sshDirForSigners = Join-Path' "$rendered" | head -1 | cut -d: -f1)"
                region_end="$(grep -nF '$signersPath = Join-Path' "$rendered" | head -1 | cut -d: -f1)"
                region_end=$((region_end - 1))
                if [ -n "$region_start" ] && [ -n "$region_end" ]; then
                    fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"
                    cat >"$fixture" <<'PSEOF'
$ErrorActionPreference = 'Stop'
$rendered, $start, $end = $args
$lines = [IO.File]::ReadAllLines($rendered)
function Slice([object[]]$All, [int]$From, [int]$To) { ($All[($From - 1)..($To - 1)] -join "`n") + "`n" }
$fixtureHome = Join-Path ([IO.Path]::GetTempPath()) ('ssh-acl-' + [guid]::NewGuid().ToString('N'))
$env:USERPROFILE = $fixtureHome
$ssh = Join-Path $fixtureHome '.ssh'
$nested = Join-Path $ssh 'nested'
New-Item -ItemType Directory -Force -Path $ssh, $nested | Out-Null
foreach ($f in 'id_test', 'id_test.pub', 'config', 'authorized_keys', 'known_hosts') {
    [IO.File]::WriteAllText((Join-Path $ssh $f), 'fixture')
}
[IO.File]::WriteAllText((Join-Path $nested 'inner'), 'fixture')
function Fail([string]$m) { Write-Host "FAIL: $m"; exit 1 }
try {
    Invoke-Expression (Slice $lines $start $end)
} catch {
    Fail "ACL region threw: $_"
}
$acl = Get-Acl $ssh
if (-not $acl.AreAccessRulesProtected) { Fail 'directory rule lost protection' }
$dirInherit = $false
foreach ($r in $acl.Access) { if ($r.InheritanceFlags -band 3) { $dirInherit = $true } }
if (-not $dirInherit) { Fail 'directory rule lost ContainerInherit/ObjectInherit' }
# Children must still be reachable (the orphaned-DACL incident).
$child = Get-Acl (Join-Path $nested 'inner')
$inherited = @($child.Access | Where-Object { $_.IsInherited })
if ($inherited.Count -eq 0) { Fail 'children lost their inherited ACEs (empty-DACL incident regression)' }
$owner = [Security.Principal.WindowsIdentity]::GetCurrent().Name
foreach ($f in 'id_test', 'config', 'authorized_keys') {
    $fa = Get-Acl (Join-Path $ssh $f)
    if (-not $fa.AreAccessRulesProtected) { Fail "$f must be protected from inheritance" }
    $explicit = @($fa.Access | Where-Object { -not $_.IsInherited })
    if ($explicit.Count -ne 1) { Fail "$f must carry exactly one explicit ACE; got $($explicit.Count)" }
}
# .pub and known_hosts ride the inheritable directory rule - deliberately NOT
# in the strict per-file pass.
foreach ($f in 'id_test.pub', 'known_hosts') {
    $fa = Get-Acl (Join-Path $ssh $f)
    if ($fa.AreAccessRulesProtected) { Fail "$f must stay outside the strict per-file pass" }
}
Write-Host '  ok: owner-only keys, inheritable dir, children reachable, .pub excluded'
Remove-Item -Recurse -Force $fixtureHome
PSEOF
                    pwsh -NoProfile -File "$fixture" "$rendered" "$region_start" "$region_end" ||
                        fail "ssh ACL execution failed"
                    rm -f "$fixture"
                else
                    fail "rendered template: ACL region anchors not found"
                fi
            else
                fail "identities template did not render: $(cat "$atmp/render.err")"
            fi
            ;;
        *)
            : # Linux CI: Get-Acl/Set-Acl do not exist here; greps above are the contract.
            ;;
    esac
fi

finish
