# scripts/lib/ps-adb-bridge.ps1 - find out, cheaply, whether the WSL ADB-bridge firewall rule is current.
#
# The Windows installer keeps one inbound rule open for the ADB server, scoped to the WSL vEthernet
# subnet. Checking it went through the NetTCPIP and NetSecurity CIM cmdlets, which are slow whatever the
# answer (measured 2026-10-12, non-elevated, warm): Get-NetAdapter 2.1 s, Get-NetIPAddress 1.6 s,
# Get-NetFirewallRule 2.9 s, Get-NetFirewallAddressFilter 0.5 s - about 12 s of every `dot up` ("mobile_dev:
# scrcpy and ADB 12s"), nearly always to learn that nothing had changed. The same facts come from
# .NET's NetworkInterface (0.13 s) and `netsh advfirewall` (0.11 s).
#
# Inlined into the installer with {{ include }} (it never loads ps-common.ps1). These only READ; the
# installer still creates or updates the rule with the NetSecurity cmdlets, and does so whenever the
# fast check cannot positively say "already current" (netsh prints localised labels, so a non-English
# Windows simply takes the slow path). Nothing here may depend on anything else in ps-common.ps1.

# "172.23.96.1" + 20 -> "172.23.96.0/20" (the network address, from the adapter's own IP and prefix).
function Get-DotSubnetText {
    param([Parameter(Mandatory)][string]$IpAddress, [Parameter(Mandatory)][int]$PrefixLength)
    $ipBytes = ([System.Net.IPAddress]::Parse($IpAddress)).GetAddressBytes()
    $netBytes = for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $PrefixLength - ($i * 8)))
        [byte]($ipBytes[$i] -band ([byte](0xFF -shl (8 - $bits) -band 0xFF)))
    }
    return ($netBytes -join '.') + "/$PrefixLength"
}

# The live WSL vEthernet adapter and its IPv4 subnet. Found: an adapter that is Up exists;
# Subnet: its IPv4 network, or $null when it has no IPv4 address. -Interface is for tests.
function Get-DotWslSubnet {
    param($Interface)
    if ($null -eq $Interface) { $Interface = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() }
    $adapter = $null
    foreach ($candidate in $Interface) {
        if ($candidate.Name -like 'vEthernet (WSL*' -and "$($candidate.OperationalStatus)" -eq 'Up') { $adapter = $candidate; break }
    }
    if ($null -eq $adapter) { return [pscustomobject]@{ Found = $false; Subnet = $null } }
    foreach ($unicast in $adapter.GetIPProperties().UnicastAddresses) {
        if ("$($unicast.Address.AddressFamily)" -eq 'InterNetwork') {
            return [pscustomobject]@{ Found = $true; Subnet = (Get-DotSubnetText -IpAddress $unicast.Address.IPAddressToString -PrefixLength $unicast.PrefixLength) }
        }
    }
    return [pscustomobject]@{ Found = $true; Subnet = $null }
}

# The RemoteIP of the rule with this display name, from `netsh advfirewall ... show rule` text; $null when
# there is no such rule, more than one, or the label is not the English one.
function ConvertFrom-NetshRuleRemoteIp {
    param([string[]]$Text)
    $joined = (@($Text) -join "`n")
    if ([regex]::Matches($joined, '(?m)^\s*Rule Name:').Count -ne 1) { return $null }
    if ($joined -match '(?m)^\s*RemoteIP:\s*(?<ip>\S+)\s*$') { return $Matches['ip'] }
    return $null
}

function Get-DotFirewallRuleRemoteIp {
    param([Parameter(Mandatory)][string]$DisplayName)
    try { return (ConvertFrom-NetshRuleRemoteIp -Text (netsh advfirewall firewall show rule "name=$DisplayName" verbose 2>$null)) }
    catch { return $null }
}
