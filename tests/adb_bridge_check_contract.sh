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

installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
tmpl="$repo_root/run_after_mobile-dev-adb-bridge.ps1.tmpl"
lib="$repo_root/scripts/lib/ps-adb-bridge.ps1"

# --- wiring (works without pwsh) -----------------------------------------------------------------
# The rule is kept by a run_after_ script, on EVERY apply. In the run_onchange installer it was skipped on
# a first install (no WSL adapter before the restart) and never retried, because the post-restart
# `dot up` had no content change to rerun the installer for (LAB-DOT-WIN-HOM #434 Run 7, 2026-10-25).
[ -f "$lib" ] || fail "scripts/lib/ps-adb-bridge.ps1 must exist"
[ -f "$tmpl" ] || fail "run_after_mobile-dev-adb-bridge.ps1.tmpl must exist (the every-apply ADB bridge step)"
require "$tmpl" 'include "scripts/lib/ps-adb-bridge.ps1"'
require "$tmpl" 'Sync-DotAdbBridgeRule'
require "$tmpl" '$mobile_dev'
forbid "$installer" 'ps-adb-bridge.ps1"'
forbid "$installer" 'New-NetFirewallRule'
forbid "$installer" 'MobileDevAdbBridge'
for f in "$lib" "$tmpl"; do
    if grep -v '^[[:space:]]*#' "$f" | grep -Fq 'Get-NetAdapter'; then fail "$f must not call Get-NetAdapter (2 s) - use Get-DotWslSubnet"; fi
    if grep -v '^[[:space:]]*#' "$f" | grep -Fq 'Get-NetIPAddress'; then fail "$f must not call Get-NetIPAddress (1.6 s) - use Get-DotWslSubnet"; fi
done
# the write path stays on the real cmdlets, and runs only when the cheap read did not match
for cmdlet in 'New-NetFirewallRule' 'Set-NetFirewallRule' 'Get-NetFirewallAddressFilter'; do
    grep -Fq "$cmdlet" "$lib" || fail "Sync-DotAdbBridgeRule must keep $cmdlet for creating/updating the rule"
done
sync_fn="$(tr -d '\r' <"$lib" | awk '/^function Sync-DotAdbBridgeRule/{f=1} f{print} f&&/^\}$/{exit}')"
read_line="$(printf '%s\n' "$sync_fn" | grep -nF -- '-eq $wslSubnet) { return }' | head -n 1 | cut -d: -f1)"
write_line="$(printf '%s\n' "$sync_fn" | grep -nF 'New-NetFirewallRule -Name' | head -n 1 | cut -d: -f1)"
if [ -z "$read_line" ] || [ -z "$write_line" ] || [ "$read_line" -ge "$write_line" ]; then
    fail "the cheap read must come before the rule is written (read '${read_line:-none}', write '${write_line:-none}')"
fi
pass

# --- the template renders only for mobile_dev ---------------------------------------------------
# An empty --config: --override-data merges into the host's own chezmoi.toml otherwise (invariant 10).
if command -v chezmoi >/dev/null 2>&1; then
    empty_dir="$(mktemp -d)"   # BSD mktemp has no --suffix, and chezmoi picks the format from the extension
    empty_config="$empty_dir/chezmoi.toml"
    : >"$empty_config"
    render() { (cd "$repo_root" && chezmoi --config "$empty_config" execute-template --override-data "$1" <"$tmpl" 2>&1 | tr -d '\r'); }
    on="$(render '{"chezmoi":{"os":"windows"},"packages":{"mobile_dev":true}}')"
    case "$on" in
        *'function Sync-DotAdbBridgeRule'*'Sync-DotAdbBridgeRule'*) pass ;;
        *) fail "mobile_dev=true must render the lib and the call (got: $(printf '%s' "$on" | head -c 400))" ;;
    esac
    for data in '{"chezmoi":{"os":"windows"},"packages":{"mobile_dev":false}}' '{"chezmoi":{"os":"windows"},"packages":{}}'; do
        got="$(render "$data")"
        if [ -z "$(printf '%s' "$got" | tr -d '[:space:]')" ]; then pass; else
            fail "$data must render nothing, so chezmoi skips the script (got: $(printf '%s' "$got" | head -c 200))"
        fi
    done
    rm -rf "$empty_dir"
else
    printf 'note: chezmoi not on PATH - the render checks did not run\n'
fi

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

# --- Sync-DotAdbBridgeRule, executed against stubs ----------------------------------------------
# The readers and the NetSecurity cmdlets are replaced by functions (a function shadows a cmdlet of the
# same name), so every branch runs without touching the real Firewall.
cat >"$tmp/sync.ps1" <<'PSEOF'
param([string]$Lib)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $Lib
$script:Wsl = $null; $script:NetshIp = $null; $script:StubRule = $null; $script:FilterIp = $null; $script:Throw = $false
$script:Calls = New-Object System.Collections.Generic.List[string]
function Get-DotWslSubnet { $script:Wsl }
function Get-DotFirewallRuleRemoteIp { param([string]$DisplayName) $script:NetshIp }
function Get-NetFirewallRule { param([string]$Name, $ErrorAction) $script:Calls.Add('Get'); $script:StubRule }
function Get-NetFirewallAddressFilter { param($AssociatedNetFirewallRule) $script:Calls.Add('Filter'); [pscustomobject]@{ RemoteAddress = @($script:FilterIp) } }
function New-NetFirewallRule {
    param($Name, $DisplayName, $Direction, $Protocol, $LocalPort, $RemoteAddress, $Action)
    if ($script:Throw) { throw 'firewall service is off' }
    $script:Calls.Add("New:$Name|$Direction|$Protocol|$LocalPort|$RemoteAddress|$Action")
}
function Set-NetFirewallRule { param($Name, $RemoteAddress) $script:Calls.Add("Set:$Name|$RemoteAddress") }

function Case($label, $wsl, $netshIp, $rule, $filterIp, [bool]$admin, [bool]$throw = $false) {
    $script:Wsl = $wsl; $script:NetshIp = $netshIp; $script:StubRule = $rule; $script:FilterIp = $filterIp; $script:Throw = $throw
    $script:Calls.Clear()
    $said = (Sync-DotAdbBridgeRule -IsAdmin $admin 6>&1 | ForEach-Object { "$_" }) -join ' '
    Write-Output ("$label calls=[" + ($script:Calls -join ',') + "] said=[$said]")
}
$up = [pscustomobject]@{ Found = $true; Subnet = '172.31.0.0/20' }
$down = [pscustomobject]@{ Found = $false; Subnet = $null }
$noV4 = [pscustomobject]@{ Found = $true; Subnet = $null }
$fakeRule = [pscustomobject]@{ Name = 'MobileDevAdbBridge' }

Case 'down-norule' $down $null $null $null $true
Case 'down-rule' $down '172.25.0.0/20' $fakeRule $null $true
Case 'nov4' $noV4 $null $null $null $true
Case 'current' $up '172.31.0.0/20' $fakeRule '172.31.0.0/20' $true
Case 'missing' $up $null $null $null $true
Case 'moved' $up '172.25.0.0/20' $fakeRule '172.25.0.0/20' $true
Case 'localised' $up $null $fakeRule '172.31.0.0/20' $true
Case 'nonadmin' $up $null $null $null $false
Case 'throws' $up $null $null $null $true $true
Write-Output 'sync-done'
PSEOF

shells=(pwsh)
command -v powershell.exe >/dev/null 2>&1 && shells+=(powershell.exe)
for sh in "${shells[@]}"; do
    out="$("$sh" -NoProfile -NonInteractive -File "$(winpath "$tmp/sync.ps1")" -Lib "$(winpath "$lib")" 2>&1 | tr -d '\r')" || fail "$sh: the sync harness must run: $out"
    line() { printf '%s\n' "$out" | grep "^$1 " || true; }
    # check LABEL CALLS [SAID]: the exact cmdlet calls, and a fixed substring of what it printed (none
    # given: it must print nothing)
    check() {
        local got want="$1 calls=[$2] said=["
        got="$(line "$1")"
        case "$got" in
            "$want"*) ;;
            *) fail "$sh $1: expected calls [$2] (got: $got)"; return ;;
        esac
        if [ "$#" -lt 3 ]; then
            [ "$got" = "${want}]" ] && pass || fail "$sh $1: expected no output (got: $got)"
        else
            case "$got" in *"$3"*) pass ;; *) fail "$sh $1: expected output containing '$3' (got: $got)" ;; esac
        fi
    }
    # WSL not running and no rule yet: say how to get one, touch nothing
    check down-norule '' 'Start WSL, then run dot up'
    # WSL not running, a rule from an earlier apply: silent, untouched
    check down-rule ''
    check nov4 '' 'no IPv4 address'
    # the cheap read says current: no NetSecurity cmdlet at all
    check current ''
    # no rule: created inbound TCP 5037, scoped to the WSL subnet only
    check missing 'Get,New:MobileDevAdbBridge|Inbound|TCP|5037|172.31.0.0/20|Allow' 'added: TCP 5037 from 172.31.0.0/20'
    # WSL came back on another subnet: re-scoped, not duplicated
    check moved 'Get,Filter,Set:MobileDevAdbBridge|172.31.0.0/20' 're-scoped to 172.31.0.0/20'
    # netsh unreadable (non-English labels) but the rule is current: slow path, no write
    check localised 'Get,Filter'
    # not elevated: warn, never try a write that would fail
    check nonadmin '' 'Administrator terminal'
    # a Firewall that refuses: warn, never throw out of the apply
    check throws 'Get' 'could not create/update'
    case "$out" in *sync-done*) pass ;; *) fail "$sh: Sync-DotAdbBridgeRule must not throw (got: $out)" ;; esac
done

finish
