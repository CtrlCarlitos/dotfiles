#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the extracted PowerShell runs in its own process
set -euo pipefail

# `devprofile init` decides whether the new SSH key gets a passphrase from, in order of
# strength: an explicit flag (--passphrase / --no-passphrase, -Passphrase / -NoPassphrase),
# then DEVPROFILE_PASSPHRASE, then (on a terminal) a question. The bash script got this
# right and pins it in tests/devprofile_contract.sh ("explicit flags beat
# DEVPROFILE_PASSPHRASE"); devprofile.ps1, its twin (invariant: both twins, or neither),
# applied the environment variable AFTER the flags, so DEVPROFILE_PASSPHRASE=1 silently
# beat -NoPassphrase and =0 beat -Passphrase.
#
# Resolve-PassphraseMode is extracted from devprofile.ps1 and EXECUTED for every
# combination of flag x environment value.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Script)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lines = Get-Content -LiteralPath $Script
$start = ($lines | Select-String -Pattern '^function Resolve-PassphraseMode \{' | Select-Object -First 1)
if ($null -eq $start) { Write-Output 'function-missing=True'; return }
$from = $start.LineNumber - 1
$to = $from
while ($lines[$to] -ne '}') { $to++ }
Invoke-Expression (($lines[$from..$to]) -join "`n")

function Case([string]$Label, [hashtable]$Params, [string]$Expect) {
    $got = Resolve-PassphraseMode @Params
    Write-Output ("{0}={1}" -f $Label, ($got -eq $Expect))
}
Case 'none-none'        @{} 'ask'
Case 'flag-pass'        @{ PassphraseFlag = $true } 'prompt'
Case 'flag-nopass'      @{ NoPassphraseFlag = $true } 'none'
Case 'dash-pass'        @{ ExtraArgs = @('--passphrase') } 'prompt'
Case 'dash-nopass'      @{ ExtraArgs = @('--no-passphrase') } 'none'
# the environment applies only when no flag was given
Case 'env1'             @{ EnvValue = '1' } 'prompt'
Case 'envTrue'          @{ EnvValue = 'True' } 'prompt'
Case 'envYes'           @{ EnvValue = 'yes' } 'prompt'
Case 'env0'             @{ EnvValue = '0' } 'none'
Case 'envFalse'         @{ EnvValue = 'false' } 'none'
Case 'envNo'            @{ EnvValue = 'NO' } 'none'
Case 'env-unknown'      @{ EnvValue = 'maybe' } 'ask'
# explicit flags win over the environment, in both directions
Case 'nopass-beats-env1' @{ NoPassphraseFlag = $true; EnvValue = '1' } 'none'
Case 'pass-beats-env0'   @{ PassphraseFlag = $true; EnvValue = '0' } 'prompt'
Case 'dashnopass-beats-env1' @{ ExtraArgs = @('--no-passphrase'); EnvValue = 'true' } 'none'
Case 'dashpass-beats-env0'   @{ ExtraArgs = @('--passphrase'); EnvValue = 'false' } 'prompt'
PSEOF

out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Script "$(winpath "$repo_root/dot_local/bin/devprofile.ps1")" 2>&1 | tr -d '\r' || true)"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400))"; }

for c in none-none flag-pass flag-nopass dash-pass dash-nopass env1 envTrue envYes env0 envFalse envNo env-unknown \
    nopass-beats-env1 pass-beats-env0 dashnopass-beats-env1 dashpass-beats-env0; do
    expect "$c=True"
done

# and Initialize-Account must use it (not its own copy of the logic)
grep -Fq 'Resolve-PassphraseMode -PassphraseFlag' "$repo_root/dot_local/bin/devprofile.ps1" ||
    fail "Initialize-Account must call Resolve-PassphraseMode"

finish
