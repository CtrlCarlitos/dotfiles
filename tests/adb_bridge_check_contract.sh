#!/usr/bin/env bash
# shellcheck disable=SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# "mobile_dev: scrcpy and ADB 12s" in every `dot up` (2026-10-12) was not scrcpy: it was the check of the
# WSL ADB-bridge firewall rule, done with the slow CIM cmdlets (Get-NetAdapter 2.1 s, Get-NetIPAddress
# 1.6 s, Get-NetFirewallRule 2.9 s, Get-NetFirewallAddressFilter 0.5 s) to learn that nothing changed.
# The facts now come from .NET (0.13 s) and netsh (0.11 s); the rule is still created and updated with
# the NetSecurity cmdlets, and whenever the cheap read cannot positively say "already current" (netsh
# labels are localised, a duplicate display name, no rule). Executed here against fakes.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
lib="$repo_root/scripts/lib/ps-adb-bridge.ps1"

# --- wiring (works without pwsh) -----------------------------------------------------------------
[ -f "$lib" ] || fail "scripts/lib/ps-adb-bridge.ps1 must exist"
grep -Fq 'include "scripts/lib/ps-adb-bridge.ps1"' "$tmpl" || fail "the installer must include scripts/lib/ps-adb-bridge.ps1"
grep -Fq 'Get-DotWslSubnet' "$tmpl" || fail "the installer must find the WSL subnet through Get-DotWslSubnet"
grep -Fq "Get-DotFirewallRuleRemoteIp -DisplayName 'mobile_dev: ADB bridge (WSL only)'" "$tmpl" || fail "the installer must read the rule through netsh first"
if grep -Fq 'Get-NetAdapter' "$tmpl"; then fail "the installer must not call Get-NetAdapter (2 s) - use Get-DotWslSubnet"; fi
if grep -Fq 'Get-NetIPAddress' "$tmpl"; then fail "the installer must not call Get-NetIPAddress (1.6 s) - use Get-DotWslSubnet"; fi
# the write path stays on the real cmdlets, and runs only when the cheap read did not match
for cmdlet in 'New-NetFirewallRule' 'Set-NetFirewallRule' 'Get-NetFirewallAddressFilter'; do
    grep -Fq "$cmdlet" "$tmpl" || fail "the installer must keep $cmdlet for creating/updating the rule"
done
read_line="$(grep -n 'Get-DotFirewallRuleRemoteIp -DisplayName' "$tmpl" | head -n 1 | cut -d: -f1)"
write_line="$(grep -n 'New-NetFirewallRule -Name' "$tmpl" | head -n 1 | cut -d: -f1)"
if [ -z "$read_line" ] || [ -z "$write_line" ] || [ "$read_line" -ge "$write_line" ]; then
    fail "the cheap read must come before the rule is written (read '${read_line:-none}', write '${write_line:-none}')"
fi
pass

# --- the helpers, executed ----------------------------------------------------------------------
command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (helpers run under PowerShell): pwsh not installed\n'; finish; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $Lib
function Out($label, $value) { Write-Output ("$label=$value") }

Out 'subnet-20' (Get-DotSubnetText -IpAddress '172.23.96.1' -PrefixLength 20)
Out 'subnet-24' (Get-DotSubnetText -IpAddress '192.168.1.77' -PrefixLength 24)
Out 'subnet-16' (Get-DotSubnetText -IpAddress '10.200.33.4' -PrefixLength 16)
Out 'subnet-12' (Get-DotSubnetText -IpAddress '172.31.255.254' -PrefixLength 12)
Out 'subnet-32' (Get-DotSubnetText -IpAddress '10.1.2.3' -PrefixLength 32)

function New-FakeNic([string]$Name, [string]$Status, $Addresses) {
    $nic = [pscustomobject]@{ Name = $Name; OperationalStatus = $Status; Props = $Addresses }
    $nic | Add-Member -MemberType ScriptMethod -Name GetIPProperties -Value { [pscustomobject]@{ UnicastAddresses = $this.Props } }
    return $nic
}
function New-FakeAddress([string]$Family, [string]$Ip, [int]$Prefix) {
    [pscustomobject]@{ Address = [pscustomobject]@{ AddressFamily = $Family; IPAddressToString = $Ip }; PrefixLength = $Prefix }
}
$v6 = New-FakeAddress 'InterNetworkV6' 'fe80::1' 64
$v4 = New-FakeAddress 'InterNetwork' '172.23.96.1' 20
$other = New-FakeNic 'Ethernet' 'Up' @((New-FakeAddress 'InterNetwork' '192.168.1.5' 24))
$wsl = New-FakeNic 'vEthernet (WSL (Hyper-V firewall))' 'Up' @($v6, $v4)
$down = New-FakeNic 'vEthernet (WSL)' 'Down' @($v4)
$noV4 = New-FakeNic 'vEthernet (WSL)' 'Up' @($v6)

$found = Get-DotWslSubnet -Interface @($other, $wsl)
Out 'wsl-found' $found.Found
Out 'wsl-subnet' $found.Subnet
$none = Get-DotWslSubnet -Interface @($other, $down)
Out 'wsl-down-found' $none.Found
$bare = Get-DotWslSubnet -Interface @($other, $noV4)
Out 'wsl-nov4-found' $bare.Found
Out 'wsl-nov4-subnet' ($null -eq $bare.Subnet)
Out 'wsl-none-at-all' (Get-DotWslSubnet -Interface @()).Found

$english = @(
    '',
    'Rule Name:                            mobile_dev: ADB bridge (WSL only)',
    '----------------------------------------------------------------------',
    'Enabled:                              Yes',
    'LocalPort:                            5037',
    'RemoteIP:                             172.23.96.0/20',
    'Action:                               Allow',
    'Ok.')
Out 'netsh-english' (ConvertFrom-NetshRuleRemoteIp -Text $english)
Out 'netsh-no-rule' ($null -eq (ConvertFrom-NetshRuleRemoteIp -Text @('', 'No rules match the specified criteria.')))
Out 'netsh-two-rules' ($null -eq (ConvertFrom-NetshRuleRemoteIp -Text ($english + $english)))
$german = @('Regelname:                            mobile_dev: ADB bridge (WSL only)', 'Remote-IP:                            172.23.96.0/20')
Out 'netsh-localised' ($null -eq (ConvertFrom-NetshRuleRemoteIp -Text $german))
Out 'netsh-empty' ($null -eq (ConvertFrom-NetshRuleRemoteIp -Text @()))

# the real machine: must not throw, wherever it runs
$live = Get-DotWslSubnet
Out 'live-has-found' ($null -ne $live.Found)
PSEOF

out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$lib")" 2>&1 | tr -d '\r')" || fail "the harness must run: $out"
expect() { case "$out" in *"$1"*) pass ;; *) fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-900))" ;; esac; }
expect 'subnet-20=172.23.96.0/20'
expect 'subnet-24=192.168.1.0/24'
expect 'subnet-16=10.200.0.0/16'
expect 'subnet-12=172.16.0.0/12'
expect 'subnet-32=10.1.2.3/32'
expect 'wsl-found=True'
expect 'wsl-subnet=172.23.96.0/20'
expect 'wsl-down-found=False'
expect 'wsl-nov4-found=True'
expect 'wsl-nov4-subnet=True'
expect 'wsl-none-at-all=False'
expect 'netsh-english=172.23.96.0/20'
expect 'netsh-no-rule=True'
expect 'netsh-two-rules=True'
expect 'netsh-localised=True'
expect 'netsh-empty=True'
expect 'live-has-found=True'

finish
