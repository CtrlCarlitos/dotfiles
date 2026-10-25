# scripts/lib/ps-adb-bridge.ps1 - find out, cheaply, whether the WSL ADB-bridge firewall rule is current.
#
# The Windows installer keeps one inbound rule open for the ADB server, scoped to the WSL vEthernet
# subnet. Checking it went through the NetTCPIP and NetSecurity CIM cmdlets, which are slow whatever the
# answer (measured 2026-10-12, non-elevated, warm): Get-NetAdapter 2.1 s, Get-NetIPAddress 1.6 s,
# Get-NetFirewallRule 2.9 s, Get-NetFirewallAddressFilter 0.5 s - about 12 s of every `dot up` ("mobile_dev:
# scrcpy and ADB 12s"), nearly always to learn that nothing had changed. The same facts come from
# .NET's NetworkInterface (0.13 s) and `netsh advfirewall` (0.11 s).
#
# Inlined with {{ include }} into run_after_mobile-dev-adb-bridge.ps1.tmpl (it never loads
# ps-common.ps1). The readers below only READ; Sync-DotAdbBridgeRule creates or updates the rule with the
# NetSecurity cmdlets, and does so whenever the fast check cannot positively say "already current" (netsh
# prints localised labels, so a non-English Windows simply takes the slow path). Nothing here may depend
# on anything else in ps-common.ps1.

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

# The ADB bridge Firewall rule (design doc section 3.3). The ADB server itself
# (`adb -a -P 5037 nodaemon server`) stays a manual, per-session command the user runs - nothing here
# starts or registers it as a service. This only scopes the Firewall rule `adb -a` needs to the WSL
# vEthernet subnet, never a LAN-wide opening (#336's explicit caution). It never throws: a Firewall
# service that is off, or managed by Group Policy, only warns. -IsAdmin is for tests.
function Sync-DotAdbBridgeRule {
    param([bool]$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    $wslNet = Get-DotWslSubnet
    if (-not $wslNet.Found) {
        # The adapter exists only while WSL's VM runs: it starts with a distro or Docker Desktop and stops
        # when idle, and a first install has none until after the restart. A rule an earlier apply added
        # is left alone; with none yet, say how to get one.
        if ($null -eq (Get-DotFirewallRuleRemoteIp -DisplayName 'mobile_dev: ADB bridge (WSL only)')) {
            Write-Host "  ADB bridge Firewall rule not added yet: WSL is not running, so the vEthernet adapter it is scoped to does not exist. Start WSL, then run dot up." -ForegroundColor Yellow
        }
        return
    }
    if (-not $wslNet.Subnet) {
        Write-Host "  Warning: found the WSL vEthernet adapter but no IPv4 address on it - skipping the ADB bridge Firewall rule." -ForegroundColor Red
        return
    }
    $wslSubnet = $wslNet.Subnet
    if ((Get-DotFirewallRuleRemoteIp -DisplayName 'mobile_dev: ADB bridge (WSL only)') -eq $wslSubnet) { return }
    if (-not $IsAdmin) {
        Write-Host "  Warning: the ADB bridge Firewall rule needs $wslSubnet - run dot up from an Administrator terminal to add it." -ForegroundColor Red
        return
    }
    try {
        $existingRule = Get-NetFirewallRule -Name 'MobileDevAdbBridge' -ErrorAction SilentlyContinue
        if (-not $existingRule) {
            New-NetFirewallRule -Name 'MobileDevAdbBridge' -DisplayName 'mobile_dev: ADB bridge (WSL only)' `
                -Direction Inbound -Protocol TCP -LocalPort 5037 `
                -RemoteAddress $wslSubnet -Action Allow | Out-Null
            Write-Host "  ADB bridge Firewall rule added: TCP 5037 from $wslSubnet only" -ForegroundColor Green
        } else {
            # WSL's subnet can change across a reboot (NAT mode especially) - a rule left pointing at
            # the old subnet is exactly the "silently half-working bridge" Review Focus item 5 warns about.
            $existingFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $existingRule
            if (($existingFilter.RemoteAddress -join ',') -ne $wslSubnet) {
                Set-NetFirewallRule -Name 'MobileDevAdbBridge' -RemoteAddress $wslSubnet
                Write-Host "  ADB bridge Firewall rule re-scoped to $wslSubnet" -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "  Warning: could not create/update the ADB bridge Firewall rule - $_" -ForegroundColor Red
    }
}
