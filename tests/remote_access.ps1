#Requires -Version 5.1
# remote_access contract (pwsh twin): the `dot remote` Windows twin skeleton
# and its `status` doctor. The harness dot-sources scripts/remote-access.ps1
# with REMOTE_ACCESS_NO_MAIN=1 (the seam that keeps its dispatch off - the
# ps1 mirror of the bash suite's RA_NO_MAIN subshell) and drives the
# functions through scope overrides: a `chezmoi` FUNCTION defined AFTER the
# dot-source serves the scenario fixture (`data --format json` cats it -
# config never comes from PATH or the host's real chezmoi), and every probe
# the doctor makes (tailscale, wsl.exe, netsh, cloudflared, tmux,
# Get-Service, Get-ItemProperty) is a function override, so no real
# invocation happens on any host. Asserted: an unknown subcommand (and a
# bare invocation) prints usage and exits 2 - via a child process, since
# `exit` IS the dispatch contract; an unreadable or disabled config
# (off.json / enabled=false) prints `not configured`; a full-win config
# prints the spec section 7 Windows sections IN ORDER (Tailscale, SSH, RDP,
# WSL, Tailscale Serve, Cloudflare, Applications, tmux) with the twin's
# marker lines reflecting
# the seams (sshd running, RDP enabled, wsl sshd active with the
# :2222 portproxy in sync against the current WSL IP - stale and unresolved
# portproxy states FAIL/WARN - serve mappings active, tunnel config valid,
# a live loopback listener answering on the configured service port); an
# unauthenticated tailscale is a WARN naming `authenticate`; a service whose
# target is not 127.0.0.1 FAILs naming `loopback`; and no captured output
# anywhere matches token-shaped material. The Task 9 setup arm adds the
# call-log seams: Set-Service / Start-Service / Get-NetFirewallRule /
# New-NetFirewallRule / Set-NetFirewallRule / Set-ItemProperty recording
# overrides (every mutating call lands in a scenario call log, and the stub
# state moves with it, so a second setup pass is provably call-free);
# asserted: Set-SshdServiceDesired records startup+start for a stopped+manual
# service and nothing for an already Automatic+Running one,
# Ensure-TailscaleFirewallRule records the exact Tailscale-scoped
# New-NetFirewallRule arguments, constrains a present generic
# OpenSSH-Server-In-TCP rule with a warning line, and rewrites nothing when
# the rule exists; Set-RdpEnabled records the registry write + the :3389 rule
# call only when windows.rdp=true; Invoke-RemoteSetup prints `not configured`
# for an absent config, the verbatim ACTION REQUIRED block on unauthenticated
# tailscale while only the dependent paths stay held, and runs idempotently.
# The Task 10 wsl arm adds the wsl.exe channel seams: the stub now dispatches
# any `sh -c <script>` call by the script's own shape (an authorized_keys
# heredoc is interpreted append-only against a canned line list, recording
# the call only on the append; a `systemctl enable` script flips the canned
# sshd probe state and records only the flip), the netsh stub records
# delete/add calls and moves the portproxy table with them, and a
# scheduled-task seam family (New-ScheduledTaskAction / New-ScheduledTaskTrigger
# / Get-ScheduledTask / Register-ScheduledTask / Set-ScheduledTask) records
# the dotfiles-wsl-reconcile install. Asserted: Invoke-WslReconcile repairs a
# missing row with one add and a FAIL -> PASS output sequence, a stale row
# (fixture WSL IP 172.20.1.5, current 172.20.9.9 from the wsl.exe stub) with
# EXACTLY delete + add, a matching row with zero netsh mutations (PASS), a
# broken wsl.exe channel with a WARN naming the manual action and no crash,
# a missing tailscale listenaddress with a WARN and no blind add;
# Register-WslReconcileTask records the logon-triggered RunLevel-Highest
# registration and takes the update path (no duplicate) on the second call;
# Publish-LoginKey -Target wsl appends the .pub content into the simulated
# authorized_keys append-only (pre-seeded lines intact, already-authorized
# second call, no-public-half and unknown-target WARNs, windows still the
# loud Task 11 stub); and the setup arm wires the whole WSL branch behind
# wsl.enabled (sshd enable inside WSL, key publication, reconcile task,
# portproxy + :2222 rule held while tailscale is unauth, broken-WSL WARN).
# The Task 11 arms complete the twin: fix is repair-only (a stopped sshd is
# restarted and its startup mode restored, the declared firewall rules are
# re-ensured behind the auth gate, the wsl portproxy is reconciled, a
# registered-but-stopped cloudflared service restarts - never installed -,
# a healthy host records zero mutations, an unauthenticated backend holds
# serve AND the firewall, and a service whose target is 0.0.0.0 is a FAIL
# with NO serve/exposure call - Review Focus #4); harden-ssh is guarded in the bash twin's order (zero authorized keys
# refuses first, then -Confirmed; a refusal is a terminating error that
# exits 1 through the dispatcher and never writes sshd_config; with both
# guards met the config at RA_SSHD_CONFIG gains exactly one prepended
# `PasswordAuthentication no`, drops the active+commented lines so a second
# run is byte-identical, and sshd restarts through the Restart-Service
# seam); the windows-target login key installs into
# administrators_authorized_keys append-only with the icacls grant recorded
# (inheritance disabled, Administrators:F) behind the Test-LocalAdmin seam,
# or into the user's authorized_keys with no icacls for a non-admin; tunnel
# render/validate mirror the Task 3 assertions exactly (terminal
# http_status:404 always appended, byte-identical re-render, validate exit
# 0/1 with named findings - loopback, http_status:404 - never echoing the
# config's own lines, RA_TUNNEL_CONFIG pinning the file under test); serve
# apply maps one path per tailscale=true service with 127.0.0.1 targets
# (the tailscale stub derives serve status from the recorded calls, so the
# second apply verifies in place and records zero calls); and setup wires
# the declared login-key targets (windows + wsl), the serve mappings and
# the tunnel render into the orchestration idempotently. The final-review
# wave closes three gaps: the dispatcher's wsl-reconcile arm parses
# --install-task (all spellings, register-first-then-reconcile, unknown
# arguments refused at dispatcher level - the gap that hid the silent
# @Rest splat); the ps1 materialize half of the login keys lands
# (Initialize-LoginKey/Initialize-LoginKeys: the bash suite's blocks 16-22
# mirrored - non-interactive never generates, the RA_CONFIRM_MATERIALIZE
# seam records `ssh-keygen -t ed25519 -f <key> -N ''` with the strict ACL
# grant riding the creation, Pattern B uses a dropped .pub as-is,
# generate=false warns `drop the public half`, and setup drives
# materialize-then-publish idempotently); and fix's cloudflared arm is
# presence-gated (absent = quiet skip).
# Runs on pwsh 7 AND Windows PowerShell 5.1 (5.1-only syntax throughout, no
# skip exits - the Windows CI block runs this file under powershell.exe).

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Twin = Join-Path $RepoRoot 'scripts/remote-access.ps1'

if (-not (Test-Path -LiteralPath $Twin)) {
    Write-Host "FAIL: scripts/remote-access.ps1 missing (the twin is not implemented yet)"
    exit 1
}

$script:PassCount = 0
$script:Failed = @()
function Ok([string]$name) {
    $script:PassCount++
    Write-Host "  ok: $name"
}
function Fail([string]$name, [string]$detail) {
    $script:Failed += $name
    Write-Host "FAIL: $name"
    if ($detail) { Write-Host $detail }
}

# The twin's markers, from codepoints: this source stays ASCII (the twin's
# header explains why - 5.1 misreads BOM-less UTF-8, and one marker byte is
# a quote in cp1252). Expected output and actual output are the same
# Unicode on every host.
$MarkOk = [string][char]0x2713   # check mark
$MarkWarn = [string][char]0x25CB # open circle
$MarkFail = [string][char]0x2717 # ballot X

# --- scenario state: every seam starts at its full-win healthy value ---------

$script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/off.json'
$script:TailscaleStatusJson = '{"BackendState": "Running", "CurrentTailnet": {"Name": "example.net"}, "Self": {"TailscaleIPs": ["100.64.0.1"]}}'
$script:TailscaleServeStatus = 'https://machine.example.net:443 path / --> http://127.0.0.1:4096'
$script:SshdServiceStatus = 'Running'
$script:SshdServiceStartType = 'Automatic'
$script:CloudflaredServiceStatus = $null
$script:RdpDenyTSConnections = 0
# The setup call log: every mutating seam override appends one line per call
# (the bash suite's $scratch/calls twin), and the stub state moves with the
# write, so a second pass sees the already-correct state and records nothing.
$script:FirewallRules = @{}
$script:Calls = @()
$script:WslStatusOk = $true
$script:WslSshProbe = 'active'
$script:WslIpLine = '172.28.120.45'
$script:WslIpOk = $true
$script:TailscaleIp = '100.64.0.1'
$script:TailscaleIpOk = $true
$script:WslAuthorizedKeys = @()
$script:ReconcileTaskInstalled = $false
$script:ReconcileTaskAction = $null
$script:LocalAdmin = $true
$script:PortproxyTable = @'

Listen on ipv4:             Connect to ipv4:

Address         Port        Address         Port
--------------- ----------  --------------- ----------
172.28.112.1    2222        172.28.120.45   22
'@
$script:CloudflaredValidateOk = $true
$script:TmuxLs = 'main: 1 windows (created Sun Sep 27 10:00:00 2026)'

# Dot-source the twin with its main guard off. Every override below is
# defined AFTER this line (the config seam contract): functions resolve at
# call time through the scope chain, so the twin's functions see them.
$env:REMOTE_ACCESS_NO_MAIN = '1'
. $Twin
Remove-Item Env:REMOTE_ACCESS_NO_MAIN

# The config seam: `data --format json` cats the scenario fixture - the same
# harness shape as the bash suite's stub chezmoi, reached by function
# override instead of PATH. Nothing here touches a real chezmoi.
function chezmoi {
    $global:LASTEXITCODE = 0
    $raw = Get-Content -Raw -LiteralPath $script:ConfigFixture -ErrorAction SilentlyContinue
    if ($null -eq $raw) {
        $global:LASTEXITCODE = 1
        return $null
    }
    return $raw
}

function tailscale {
    $global:LASTEXITCODE = 0
    $call = $args -join ' '
    if ($call -eq 'status --json') { return $script:TailscaleStatusJson }
    if ($call -eq 'serve status') { return $script:TailscaleServeStatus }
    if ($call -like 'serve --bg*') {
        # The serve-write seam: records the exact mapping call and appends
        # the mapping into the stub status, so a second apply pass reads the
        # mapped target back and verifies in place (the derive-from-log stub
        # shape the bash suite uses for its tailscale stub).
        $argList = @($args)
        $setPath = '/'
        $idx = [array]::IndexOf($argList, '--set-path')
        if (($idx -ge 0) -and ($idx -lt ($argList.Count - 1))) { $setPath = [string]$argList[$idx + 1] }
        $target = [string]$argList[$argList.Count - 1]
        $script:TailscaleServeStatus = ($script:TailscaleServeStatus + "`n" + ("https://machine.example.net:443 path {0} --> {1}" -f $setPath, $target))
        $script:Calls += ("tailscale " + $call)
        return $null
    }
    if ($call -eq 'ip -4') {
        # The reconcile arm's listenaddress probe: gated by TailscaleIpOk so
        # the address-unavailable WARN path is reachable.
        if (-not $script:TailscaleIpOk) {
            $global:LASTEXITCODE = 1
            return $null
        }
        return ($script:TailscaleIp + "`n")
    }
    $global:LASTEXITCODE = 1
    return $null
}

function Get-Service {
    # The sshd seam: the twin asks Get-Service about sshd; the harness
    # answers with canned state (Status for the doctor, StartType for the
    # setup writer) so the real cmdlet never runs. String values, not the
    # enums: 5.1 cannot resolve ServiceControllerStatus when the real
    # Get-Service never loaded (the twin compares strings for that reason).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -eq 'sshd') {
        if ([string]::IsNullOrEmpty($script:SshdServiceStatus)) { return $null }
        return New-Object -TypeName PSObject -Property @{ Name = 'sshd'; Status = $script:SshdServiceStatus; StartType = $script:SshdServiceStartType }
    }
    if ($Name -eq 'cloudflared') {
        # The cloudflared service seam (fix's restart arm): $null answers
        # "not registered" - the quiet no-repair skip.
        if ([string]::IsNullOrEmpty($script:CloudflaredServiceStatus)) { return $null }
        return New-Object -TypeName PSObject -Property @{ Name = 'cloudflared'; Status = $script:CloudflaredServiceStatus; StartType = 'Automatic' }
    }
    return $null
}

function Get-ItemProperty {
    # The RDP registry seam: fDenyTSConnections answered from scenario state.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [CmdletBinding()]
    param([string]$Path, [string]$Name)
    if ($Path -like '*Terminal Server' -and $Name -eq 'fDenyTSConnections') {
        if ($null -eq $script:RdpDenyTSConnections) { return $null }
        return New-Object -TypeName PSObject -Property @{ fDenyTSConnections = $script:RdpDenyTSConnections }
    }
    return $null
}

function Invoke-WslKeysStub {
    # The append-only authorize simulation (Review Focus #2): the twin's
    # heredoc script carries the key line between <<'RAKEY' and RAKEY, and
    # the REAL script echoes its verdict - `echo present` on the
    # already-present path, `echo authorized` on the append path - so this
    # stub returns exactly those strings: it greps the canned
    # authorized_keys list (present, no mutation, no recorded call) or
    # appends the line verbatim (authorized, call recorded). The pre-seeded
    # lines are never rewritten.
    param([string]$ScriptBody)
    $key = $null
    if ($ScriptBody -match "<<'RAKEY'\r?\n(.+?)\r?\nRAKEY") { $key = $Matches[1] }
    if ([string]::IsNullOrEmpty($key)) {
        $global:LASTEXITCODE = 1
        return $null
    }
    if (@($script:WslAuthorizedKeys) -contains $key) { return 'present' }
    $script:WslAuthorizedKeys = @($script:WslAuthorizedKeys) + $key
    $script:Calls += 'wsl.exe -u root authorize login key (inside WSL)'
    return 'authorized'
}

function wsl.exe {
    # The wsl.exe channel seam: --status answers availability, hostname -I
    # answers the current WSL IP (gated by WslIpOk for the reconcile failure
    # case), and any `sh -c <script>` call is dispatched by the script's own
    # shape - the doctor's probe returns the canned probe state, a
    # `systemctl enable` script flips that state and records only the flip,
    # and an authorized_keys script is interpreted by Invoke-WslKeysStub.
    # No real wsl.exe anywhere.
    $global:LASTEXITCODE = 0
    $argList = @($args)
    $joined = ($argList -join ' ')
    if ($joined -eq '--status') {
        if (-not $script:WslStatusOk) {
            $global:LASTEXITCODE = 1
            return $null
        }
        return 'wsl available'
    }
    if ($joined -eq 'hostname -I') {
        if (-not $script:WslIpOk) {
            $global:LASTEXITCODE = 1
            return $null
        }
        return ($script:WslIpLine + ' ')
    }
    $scriptBody = $null
    if (($argList.Count -ge 2) -and ($argList[$argList.Count - 2] -eq '-c')) {
        $scriptBody = [string]$argList[$argList.Count - 1]
    }
    if ($null -ne $scriptBody) {
        if ($scriptBody -like '*authorized_keys*') { return (Invoke-WslKeysStub -ScriptBody $scriptBody) }
        if ($scriptBody -like '*systemctl enable*') {
            if ($script:WslSshProbe -ne 'active') {
                $script:WslSshProbe = 'active'
                $script:Calls += 'wsl.exe -u root enable ssh (inside WSL)'
            }
            return 'wsl-ssh-enabled'
        }
        return $script:WslSshProbe
    }
    $global:LASTEXITCODE = 1
    return $null
}

function Get-PortproxyStubRows {
    # The stub table's rows, parsed with the same shape the twin's
    # Get-PortproxyRow expects.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'the plural names the parsed row list - the same misread Assert-FileEqual documents in tests/select_packages.ps1')]
    param([string]$Table)
    $rows = @()
    foreach ($line in ($Table -split "`r?`n")) {
        if ($line -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s*$') {
            $rows += New-Object -TypeName PSObject -Property @{ ListenAddress = $Matches[1]; ListenPort = [int]$Matches[2]; ConnectAddress = $Matches[3]; ConnectPort = [int]$Matches[4] }
        }
    }
    return @($rows)
}

function Format-PortproxyStubTable {
    # Render rows back into the netsh show layout the doctor and the
    # reconcile arm parse (also used to seed the scenario table).
    param([object[]]$Rows)
    $lines = @('', 'Listen on ipv4:             Connect to ipv4:', '', 'Address         Port        Address         Port', '--------------- ----------  --------------- ----------')
    foreach ($r in @($Rows)) {
        $lines += ('{0,-16}{1,-12}{2,-16}{3}' -f $r.ListenAddress, $r.ListenPort, $r.ConnectAddress, $r.ConnectPort)
    }
    return ($lines -join "`r`n")
}

function netsh {
    # The netsh seam: show returns the canned table; delete/add record the
    # exact call and move the table with it (the derive-from-log stub shape,
    # so a second reconcile pass is provably call-free). The managed :2222
    # row is replaced on add, exactly one row is removed on delete.
    $global:LASTEXITCODE = 0
    $call = $args -join ' '
    if ($call -eq 'interface portproxy show v4tov4') { return $script:PortproxyTable }
    if ($call -like 'interface portproxy delete v4tov4*') {
        $la = $null
        $lp = $null
        if ($call -match 'listenaddress=(\d{1,3}(?:\.\d{1,3}){3})') { $la = $Matches[1] }
        if ($call -match 'listenport=(\d+)') { $lp = [int]$Matches[1] }
        $rows = @(Get-PortproxyStubRows -Table $script:PortproxyTable | Where-Object { -not (($_.ListenAddress -eq $la) -and ($_.ListenPort -eq $lp)) })
        $script:PortproxyTable = Format-PortproxyStubTable -Rows $rows
        $script:Calls += ("netsh " + $call)
        return $null
    }
    if ($call -like 'interface portproxy add v4tov4*') {
        $la = $null
        $lp = $null
        $ca = $null
        $cp = $null
        if ($call -match 'listenaddress=(\d{1,3}(?:\.\d{1,3}){3})') { $la = $Matches[1] }
        if ($call -match 'listenport=(\d+)') { $lp = [int]$Matches[1] }
        if ($call -match 'connectaddress=(\d{1,3}(?:\.\d{1,3}){3})') { $ca = $Matches[1] }
        if ($call -match 'connectport=(\d+)') { $cp = [int]$Matches[1] }
        $rows = @(Get-PortproxyStubRows -Table $script:PortproxyTable | Where-Object { $_.ListenPort -ne $lp })
        $rows += New-Object -TypeName PSObject -Property @{ ListenAddress = $la; ListenPort = $lp; ConnectAddress = $ca; ConnectPort = $cp }
        $script:PortproxyTable = Format-PortproxyStubTable -Rows $rows
        $script:Calls += ("netsh " + $call)
        return $null
    }
    $global:LASTEXITCODE = 1
    return $null
}

function cloudflared {
    $global:LASTEXITCODE = 0
    $call = $args -join ' '
    if ($call -like 'tunnel ingress validate*') {
        if (-not $script:CloudflaredValidateOk) {
            $global:LASTEXITCODE = 1
            return $null
        }
        return $null
    }
    $global:LASTEXITCODE = 1
    return $null
}

function tmux {
    $global:LASTEXITCODE = 0
    $call = $args -join ' '
    if ($call -eq 'ls') {
        if ([string]::IsNullOrEmpty($script:TmuxLs)) {
            $global:LASTEXITCODE = 1
            return $null
        }
        return $script:TmuxLs
    }
    $global:LASTEXITCODE = 1
    return $null
}

function Set-Service {
    # The sshd startup-mode seam: records the call and moves the stub state,
    # so a second setup pass sees the already-correct service (the bash
    # suite's derive-from-log stub shape).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'recording seam - the stub changes scenario state only')]
    [CmdletBinding()]
    param([string]$Name, [string]$StartupType)
    if ($Name -eq 'sshd') { $script:SshdServiceStartType = $StartupType }
    $script:Calls += ("Set-Service -Name {0} -StartupType {1}" -f $Name, $StartupType)
}

function Start-Service {
    # The sshd start seam: records the call and moves the stub state to
    # Running.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'recording seam - the stub changes scenario state only')]
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -eq 'sshd') { $script:SshdServiceStatus = 'Running' }
    $script:Calls += ("Start-Service -Name {0}" -f $Name)
}

function Restart-Service {
    # The service restart seam (Task 11): fix's sshd restart, fix's
    # cloudflared restart, and harden-ssh's key-only bounce all land here;
    # records the call and moves the stub state to Running.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'recording seam - the stub changes scenario state only')]
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -eq 'sshd') { $script:SshdServiceStatus = 'Running' }
    if ($Name -eq 'cloudflared') { $script:CloudflaredServiceStatus = 'Running' }
    $script:Calls += ("Restart-Service -Name {0}" -f $Name)
}

function Test-LocalAdmin {
    # The group-check seam (Task 11): the twin's windows-target key install
    # asks whether the account is in the local Administrators group; the
    # harness answers from scenario state, so no real group lookup ever runs
    # in a test host.
    param()
    return $script:LocalAdmin
}

function Get-LoginKeyAclUser {
    # The ACL-user seam (the materialize twin): the twin grants the strict
    # private-key ACL to the current Windows identity; the harness answers
    # a fixed account so the recorded icacls call is deterministic and no
    # real identity lookup ever runs (WindowsIdentity is not supported on
    # the Linux runners).
    param()
    return 'TESTDOM\testuser'
}

function icacls {
    # The ACL seam (Task 11): the administrators_authorized_keys grant is
    # recorded, never applied - a test host has no real ACL stake here, and
    # the assertion reads the call log.
    $global:LASTEXITCODE = 0
    $script:Calls += ("icacls " + ($args -join ' '))
    return $null
}

function ssh-keygen {
    # The key-generation seam (the bash suite's faithful ssh-keygen stub):
    # records the argv and materializes an empty private half + a .pub, so
    # the creation and the ACL grant riding it are observable. The empty
    # passphrase (`-N ''`) never appears here except when the twin's
    # RA_CONFIRM_MATERIALIZE seam asked for it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'the override IS the seam - the native command name must stay verbatim')]
    param()
    $global:LASTEXITCODE = 0
    $argList = @($args)
    $script:Calls += ("ssh-keygen " + (($argList | ForEach-Object { "'{0}'" -f $_ }) -join ' '))
    $keyFile = $null
    for ($i = 0; $i -lt $argList.Count; $i++) {
        if (($argList[$i] -ceq '-f') -and ($i -lt ($argList.Count - 1))) { $keyFile = [string]$argList[$i + 1] }
    }
    if ($keyFile) {
        [IO.File]::WriteAllText($keyFile, '')
        [IO.File]::WriteAllText(($keyFile + '.pub'), "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4bGmSPbKDIX6g9uAAaf7UNuYF8b2TmXLamtGpiI6Cd stub@local`n")
    }
    return $null
}

function Get-NetFirewallRule {
    # The firewall rule seam: the stub table answers presence + enabled state
    # ('True'/'False' strings, not the GpoBoolean enum - the same 5.1
    # enum-loading constraint as the service seam).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [CmdletBinding()]
    param([string]$Name)
    if ($script:FirewallRules.ContainsKey($Name)) {
        return New-Object -TypeName PSObject -Property @{ Name = $Name; Enabled = $script:FirewallRules[$Name] }
    }
    return $null
}

function New-NetFirewallRule {
    # The firewall write seam: records the exact bound arguments (the brief
    # asserts the literal rule name/port plus the Tailscale interface and
    # tailnet address space) and materializes the rule in the stub table.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'recording seam - the stub changes scenario state only')]
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$DisplayName,
        [string]$Direction,
        [string]$Protocol,
        [int]$LocalPort,
        [string]$Action,
        [string]$InterfaceAlias,
        [string[]]$RemoteAddress
    )
    $script:FirewallRules[$Name] = 'True'
    $script:Calls += ("New-NetFirewallRule -Name {0} -LocalPort {1} -InterfaceAlias {2} -RemoteAddress {3} -Direction {4} -Protocol {5} -Action {6} -DisplayName {7}" -f `
            $Name, $LocalPort, $InterfaceAlias, ($RemoteAddress -join ','), $Direction, $Protocol, $Action, $DisplayName)
}

function Set-NetFirewallRule {
    # The firewall constraint seam: records the constraint call and flips the
    # stub rule's enabled state (a second pass sees it already constrained).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'recording seam - the stub changes scenario state only')]
    [CmdletBinding()]
    param([string]$Name, $Enabled)
    $script:FirewallRules[$Name] = [string]$Enabled
    $script:Calls += ("Set-NetFirewallRule -Name {0} -Enabled {1}" -f $Name, [string]$Enabled)
}

function Set-ItemProperty {
    # The RDP registry write seam: records the call and flips the stub value
    # (a second pass sees fDenyTSConnections already 0).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'recording seam - the stub changes scenario state only')]
    [CmdletBinding()]
    param([string]$Path, [string]$Name, $Value)
    if ($Path -like '*Terminal Server' -and $Name -eq 'fDenyTSConnections') {
        $script:RdpDenyTSConnections = $Value
    }
    $script:Calls += ("Set-ItemProperty -Path {0} -Name {1} -Value {2}" -f $Path, $Name, $Value)
}

function New-ScheduledTaskAction {
    # The reconcile task's action seam: stringified so the recorded call
    # shows what would execute.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'recording seam - the stub changes scenario state only')]
    param([string]$Execute, [string]$Argument)
    return ("action:{0} {1}" -f $Execute, $Argument)
}

function New-ScheduledTaskTrigger {
    # The trigger seam: the twin asks for -AtLogOn; the stub echoes the
    # trigger kind so the registration record pins it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'recording seam - the stub changes scenario state only')]
    param([switch]$AtLogOn)
    if (-not $AtLogOn) { return 'unsupported-trigger' }
    return 'AtLogOn'
}

function Get-ScheduledTask {
    # The task-presence seam: dotfiles-wsl-reconcile exists only after the
    # stub's Register ran (or ReconcileTaskInstalled was pre-seeded).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [CmdletBinding()]
    param([string]$TaskName)
    if (($TaskName -eq 'dotfiles-wsl-reconcile') -and $script:ReconcileTaskInstalled) {
        return New-Object -TypeName PSObject -Property @{ TaskName = $TaskName }
    }
    return $null
}

function Register-ScheduledTask {
    # The task-install seam: records the exact registration arguments
    # (task name, logon trigger, run level) and materializes the task in
    # the stub state.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'recording seam - the stub changes scenario state only')]
    [CmdletBinding()]
    param([string]$TaskName, $Action, $Trigger, [string]$RunLevel)
    $script:ReconcileTaskInstalled = $true
    $script:ReconcileTaskAction = $Action
    $script:Calls += ("Register-ScheduledTask -TaskName {0} -Trigger {1} -RunLevel {2}" -f $TaskName, $Trigger, $RunLevel)
}

function Set-ScheduledTask {
    # The task-update seam: the idempotent second-call path (a refresh,
    # never a duplicate registration).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'recording seam - the stub changes scenario state only')]
    [CmdletBinding()]
    param([string]$TaskName, $Action, $Trigger)
    $script:ReconcileTaskAction = $Action
    $script:Calls += ("Set-ScheduledTask -TaskName {0} -Trigger {1}" -f $TaskName, $Trigger)
}

# --- capture + assertion helpers ---------------------------------------------

function Get-StatusOutput {
    # Function-level capture: the doctor prints through Write-Host, which
    # lands on the information stream on both 5.1 and pwsh 7.
    return ((Get-RemoteStatus *>&1) -join "`n")
}

function Invoke-TwinChild([string[]]$Arguments) {
    # The script under test in a child of THIS host's executable (pwsh 7 on
    # the Linux runners, powershell.exe 5.1 on the Windows one) - the only
    # way to observe the dispatcher's `exit 2` without ending this harness.
    # The preference is eased around the child: 5.1 turns its stderr (the
    # usage line) into error records, and EAP=Stop makes the first one
    # terminating.
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $Twin @Arguments 2>&1
    } finally {
        $ErrorActionPreference = $saved
    }
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    return New-Object -TypeName PSObject -Property @{ Exit = $LASTEXITCODE; Output = $text }
}

# "Has", not "Contains": PSUseSingularNouns misreads the trailing s as a
# plural noun (the same misread Assert-FileEqual documents in
# tests/select_packages.ps1).
function Assert-OutputHas([string]$output, [string]$expected, [string]$label) {
    if ($output -match [regex]::Escape($expected)) { Ok $label } else { Fail $label ("expected: $expected`n---got---`n$output") }
}

function Assert-NoTokenMaterial([string]$output, [string]$label) {
    if ($output -match 'ey[A-Za-z0-9_-]{20,}') { Fail $label $output } else { Ok $label }
}

function Get-SetupOutput {
    # Function-level capture of the setup arm (same mechanism as the
    # doctor's capture above: Write-Host lands on the information stream).
    return ((Invoke-RemoteSetup *>&1) -join "`n")
}

function Assert-RecordedCall([string]$pattern, [string]$label) {
    # A recorded mutating call matching PATTERN (-like wildcards): the seam
    # assertions read the call log, never real host state.
    $hit = $false
    foreach ($c in $script:Calls) { if ($c -like $pattern) { $hit = $true; break } }
    if ($hit) { Ok $label } else { Fail $label ("expected call like: $pattern`n---calls---`n" + ($script:Calls -join "`n")) }
}

function Assert-NoRecordedCall([string]$pattern, [string]$label) {
    $hit = $false
    foreach ($c in $script:Calls) { if ($c -like $pattern) { $hit = $true; break } }
    if (-not $hit) { Ok $label } else { Fail $label ("unexpected call like: $pattern`n---calls---`n" + ($script:Calls -join "`n")) }
}

function Get-SectionLine([string]$text, [string]$header) {
    # Line number of the first line equal to HEADER (0 when absent) - the
    # ra_section_line twin, and how the section-order assertion works.
    $lines = @($text -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq $header) { return ($i + 1) }
    }
    return 0
}

# --- scenarios ----------------------------------------------------------------

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('remote-access-ps1-' + [IO.Path]::GetRandomFileName())
$Home_ = Join-Path $Tmp 'home'
New-Item -ItemType Directory -Force -Path $Home_ | Out-Null
$savedHome = $env:HOME
$savedProfile = $env:USERPROFILE
$savedProgramData = $env:ProgramData

try {
    $env:HOME = $Home_
    $env:USERPROFILE = $Home_
    # The windows-target key install resolves %ProgramData% for
    # administrators_authorized_keys: repointed at the scratch dir so the
    # arm never touches the host's real OpenSSH state.
    $ProgramData_ = Join-Path $Tmp 'programdata'
    New-Item -ItemType Directory -Force -Path $ProgramData_ | Out-Null
    $env:ProgramData = $ProgramData_

    # 1. Unknown subcommand: usage on stderr, exit 2.
    $r = Invoke-TwinChild @('definitely-not-a-subcommand')
    if ($r.Exit -eq 2) { Ok 'unknown subcommand exits 2' } else { Fail 'unknown subcommand exits 2' ("exit=$($r.Exit) out=$($r.Output)") }
    Assert-OutputHas $r.Output 'usage:' 'unknown subcommand prints usage'

    # 2. Bare invocation (zero args): usage, exit 2 - the argless path the
    #    dispatcher must not crash on.
    $r = Invoke-TwinChild @()
    if ($r.Exit -eq 2) { Ok 'bare invocation exits 2' } else { Fail 'bare invocation exits 2' ("exit=$($r.Exit) out=$($r.Output)") }
    Assert-OutputHas $r.Output 'usage:' 'bare invocation prints usage'

    # 3. status with [data.remote_access] absent (off.json): the config
    #    resolver degrades to $null and the doctor prints `not configured`.
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/off.json'
    $cfg = Get-RemoteAccessConfig
    if ($null -eq $cfg) { Ok 'off.json resolves to a $null config' } else { Fail 'off.json resolves to a $null config' ($cfg | Out-String) }
    $out = Get-StatusOutput
    Assert-OutputHas $out 'not configured' 'absent config prints not configured'
    Assert-NoTokenMaterial $out 'absent-config output carries no token material'

    # 4. status with enabled=false: still `not configured` - only a real
    #    `enabled = true` configures the doctor.
    $enabledFalse = Join-Path $Tmp 'enabled-false.json'
    [IO.File]::WriteAllText($enabledFalse, '{"remote_access": {"enabled": false}}')
    $script:ConfigFixture = $enabledFalse
    $out = Get-StatusOutput
    Assert-OutputHas $out 'not configured' 'enabled=false prints not configured'

    # 5. full-win.json on a healthy host: the spec section 7 Windows sections
    #    in order, marker lines reflecting the seams - including a live
    #    loopback
    #    listener answering on the configured service port 4096 - exit-0
    #    behavior (no throw), and no token-shaped material anywhere.
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/full-win.json'
    $cfg = Get-RemoteAccessConfig
    if ($null -ne $cfg -and $cfg.enabled -eq $true) { Ok 'full-win.json resolves to the config object' } else { Fail 'full-win.json resolves to the config object' ($cfg | Out-String) }
    New-Item -ItemType Directory -Force -Path (Join-Path $Home_ '.cloudflared') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Home_ '.cloudflared/config.yml'), "tunnel: 00000000-0000-0000-0000-000000000000`n")
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 4096)
    $listener.Start()
    try {
        $out = Get-StatusOutput
    } finally {
        $listener.Stop()
    }
    foreach ($section in @('Tailscale:', 'SSH:', 'RDP:', 'WSL:', 'Tailscale Serve:', 'Cloudflare:', 'Applications:', 'tmux:')) {
        if ((Get-SectionLine $out $section) -gt 0) { Ok "status prints a $section section" } else { Fail "status prints a $section section" $out }
    }
    $lineTailscale = Get-SectionLine $out 'Tailscale:'
    $lineSsh = Get-SectionLine $out 'SSH:'
    $lineRdp = Get-SectionLine $out 'RDP:'
    $lineWsl = Get-SectionLine $out 'WSL:'
    $lineServe = Get-SectionLine $out 'Tailscale Serve:'
    $lineCloudflare = Get-SectionLine $out 'Cloudflare:'
    $lineApps = Get-SectionLine $out 'Applications:'
    $lineTmux = Get-SectionLine $out 'tmux:'
    if (($lineTailscale -lt $lineSsh) -and ($lineSsh -lt $lineRdp) -and ($lineRdp -lt $lineWsl) -and
        ($lineWsl -lt $lineServe) -and ($lineServe -lt $lineCloudflare) -and ($lineCloudflare -lt $lineApps) -and
        ($lineApps -lt $lineTmux)) {
        Ok 'status sections appear in spec section 7 order'
    } else {
        Fail 'status sections appear in spec section 7 order' $out
    }
    Assert-OutputHas $out ($MarkOk + ' tailscale: connected (tailnet: example.net, address: 100.64.0.1)') 'tailscale section reports the connected state'
    Assert-OutputHas $out ($MarkOk + ' ssh: sshd active') 'ssh section reports the stubbed sshd state'
    Assert-OutputHas $out ($MarkOk + ' rdp: Remote Desktop enabled') 'rdp section reports the registry state'
    Assert-OutputHas $out ($MarkOk + ' wsl: sshd active') 'wsl section reports the stubbed wsl sshd state'
    Assert-OutputHas $out ($MarkOk + ' wsl: portproxy :2222 -> 172.28.120.45:22 in sync') 'portproxy row matches the current WSL IP'
    Assert-OutputHas $out ($MarkOk + ' serve: active mappings') 'serve section reports the stubbed mappings'
    Assert-OutputHas $out 'http://127.0.0.1:4096' 'serve section passes through the mapping target'
    Assert-OutputHas $out ($MarkOk + ' cloudflared: tunnel config valid') 'cloudflare section validates the existing config'
    Assert-OutputHas $out ($MarkOk + ' opencode_windows: listening on 127.0.0.1:4096 (windows)') 'applications section reports the listening service'
    Assert-OutputHas $out ($MarkOk + ' tmux: active sessions') 'tmux section reports the stubbed session'
    Assert-NoTokenMaterial $out 'status output carries no token material'

    # 6. Unauthenticated Tailscale: a WARN line naming the manual action
    #    (authenticate), serve held, and the doctor does not crash.
    $script:TailscaleStatusJson = '{"BackendState": "NeedsLogin"}'
    $out = Get-StatusOutput
    Assert-OutputHas $out ($MarkWarn + ' tailscale: not authenticated') 'unauth tailscale prints the WARN line'
    Assert-OutputHas $out 'authenticate' 'the unauth WARN names the manual action: authenticate'
    Assert-OutputHas $out ($MarkWarn + ' serve: skipped (tailscale not authenticated)') 'unauth tailscale holds the serve section'
    $script:TailscaleStatusJson = '{"BackendState": "Running", "CurrentTailnet": {"Name": "example.net"}, "Self": {"TailscaleIPs": ["100.64.0.1"]}}'

    # 7. A service whose configured target host is not 127.0.0.1: a FAIL
    #    line mentioning loopback (the doctor reports, never crashes).
    $nonLoopback = Join-Path $Tmp 'nonloopback.json'
    $fullText = Get-Content -Raw -LiteralPath $script:ConfigFixture
    [IO.File]::WriteAllText($nonLoopback, $fullText.Replace('"opencode_windows": {', '"opencode_windows": { "host": "0.0.0.0",'))
    $script:ConfigFixture = $nonLoopback
    $out = Get-StatusOutput
    Assert-OutputHas $out ($MarkFail + ' opencode_windows: target 0.0.0.0:4096 is not loopback') 'a non-loopback target FAILs with a loopback mention'
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/full-win.json'

    # 8. A stale portproxy (the row still points at the old WSL IP): FAIL
    #    naming the reconcile fix.
    $script:PortproxyTable = $script:PortproxyTable.Replace('172.28.120.45   22', '172.28.1.1       22')
    $out = Get-StatusOutput
    Assert-OutputHas $out ($MarkFail + ' wsl: portproxy :2222 -> 172.28.1.1:22 is stale') 'a stale portproxy FAILs against the current WSL IP'
    Assert-OutputHas $out 'wsl-reconcile' 'the stale-portproxy FAIL names the reconcile fix'
    $script:PortproxyTable = $script:PortproxyTable.Replace('172.28.1.1       22', '172.28.120.45   22')

    # 9. WSL broken (wsl.exe --status fails): the availability WARN, and the
    #    sshd/portproxy probes never run.
    $script:WslStatusOk = $false
    $out = Get-StatusOutput
    Assert-OutputHas $out ($MarkWarn + ' wsl: not available') 'a broken wsl.exe prints the availability WARN'
    $script:WslStatusOk = $true

    # 10. setup with [data.remote_access] absent: a `not configured` no-op -
    #     zero recorded calls, no crash (the bash cmd_setup parity).
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/off.json'
    $script:Calls = @()
    $out = Get-SetupOutput
    Assert-OutputHas $out 'not configured' 'setup with an absent config prints not configured'
    if ($script:Calls.Count -eq 0) { Ok 'setup with an absent config records zero calls' } else { Fail 'setup with an absent config records zero calls' ($script:Calls -join '; ') }
    Assert-NoTokenMaterial $out 'setup absent-config output carries no token material'

    # 11. setup with unauthenticated Tailscale: the verbatim ACTION REQUIRED
    #     block; the Tailscale-independent path (sshd) still runs; the
    #     Tailscale-dependent paths (firewall rules, RDP) record nothing.
    #     Exit behavior is no-crash - an auth gate is not a hard failure.
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/full-win.json'
    $script:TailscaleStatusJson = '{"BackendState": "NeedsLogin"}'
    $script:SshdServiceStatus = 'Stopped'
    $script:SshdServiceStartType = 'Manual'
    $script:FirewallRules = @{}
    $script:RdpDenyTSConnections = 1
    $script:Calls = @()
    $out = Get-SetupOutput
    Assert-OutputHas $out 'ACTION REQUIRED:' 'setup prints the ACTION REQUIRED block verbatim'
    Assert-OutputHas $out 'Authenticate this host with Tailscale, then rerun:' 'the ACTION REQUIRED block names the authenticate action'
    Assert-OutputHas $out '    dot remote setup' 'the ACTION REQUIRED block ends with the 4-space rerun line'
    Assert-RecordedCall 'Set-Service -Name sshd -StartupType Automatic' 'unauth setup still runs the independent sshd path (startup)'
    Assert-RecordedCall 'Start-Service -Name sshd' 'unauth setup still runs the independent sshd path (start)'
    Assert-NoRecordedCall 'New-NetFirewallRule*' 'unauth setup holds the firewall rules (dependent path)'
    Assert-NoRecordedCall 'Set-ItemProperty*' 'unauth setup holds the RDP write (dependent path)'
    Assert-OutputHas $out 'wsl: portproxy held while tailscale is unauth' 'unauth setup holds the wsl portproxy (dependent path)'
    Assert-NoTokenMaterial $out 'unauth setup output carries no token material'
    $script:TailscaleStatusJson = '{"BackendState": "Running", "CurrentTailnet": {"Name": "example.net"}, "Self": {"TailscaleIPs": ["100.64.0.1"]}}'

    # 12. setup first pass on a wrong-state host (tailscale ok): every
    #     mutation recorded with its exact seam arguments - sshd startup +
    #     start, the :22 rule created with the Tailscale interface + tailnet
    #     address space, the generic internet-wide rule constrained + a
    #     warning line naming it, the RDP registry write, the :3389 rule.
    $script:SshdServiceStatus = 'Stopped'
    $script:SshdServiceStartType = 'Manual'
    $script:FirewallRules = @{ 'OpenSSH-Server-In-TCP' = 'True' }
    $script:RdpDenyTSConnections = 1
    $script:WslSshProbe = 'inactive'
    $script:ReconcileTaskInstalled = $false
    $script:Calls = @()
    $out = Get-SetupOutput
    Assert-RecordedCall 'Set-Service -Name sshd -StartupType Automatic' 'setup drives sshd startup to Automatic'
    Assert-RecordedCall 'Start-Service -Name sshd' 'setup starts sshd'
    Assert-RecordedCall 'New-NetFirewallRule -Name OpenSSH-Tailscale -LocalPort 22 -InterfaceAlias Tailscale -RemoteAddress 100.64.0.0/10*' 'the :22 rule is created Tailscale-scoped (interface + tailnet space)'
    Assert-RecordedCall 'Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Enabled False' 'the generic internet-wide rule is constrained'
    Assert-OutputHas $out 'OpenSSH-Server-In-TCP' 'the constraint prints a warning line naming the generic rule'
    Assert-RecordedCall 'Set-ItemProperty*fDenyTSConnections*Value 0*' 'RDP enable writes fDenyTSConnections 0'
    Assert-RecordedCall 'New-NetFirewallRule -Name RemoteDesktop-Tailscale -LocalPort 3389*' 'the :3389 rule is created for RDP'
    Assert-RecordedCall 'wsl.exe -u root enable ssh (inside WSL)' 'setup enables sshd inside WSL (best-effort wsl.exe -u root)'
    Assert-RecordedCall 'Register-ScheduledTask -TaskName dotfiles-wsl-reconcile -Trigger AtLogOn -RunLevel Highest' 'setup registers the reconcile task (logon trigger, RunLevel Highest)'
    Assert-RecordedCall 'New-NetFirewallRule -Name WSL-SSH-Tailscale -LocalPort 2222*' 'the :2222 WSL rule is created for the wsl arm'
    Assert-NoTokenMaterial $out 'setup output carries no token material'

    # 13. setup second pass against the now-correct stub state: ZERO mutating
    #     calls - idempotency, executed (verify-don't-rewrite).
    $script:Calls = @()
    $out = Get-SetupOutput
    if ($script:Calls.Count -eq 0) { Ok 'setup second pass records zero calls' } else { Fail 'setup second pass records zero calls' ($script:Calls -join '; ') }
    Assert-NoTokenMaterial $out 'second-pass setup output carries no token material'

    # 14. Set-SshdServiceDesired at unit level - the brief's two pinned cases.
    $script:SshdServiceStatus = 'Stopped'
    $script:SshdServiceStartType = 'Manual'
    $script:Calls = @()
    $null = (Set-SshdServiceDesired *>&1)
    Assert-RecordedCall 'Set-Service -Name sshd -StartupType Automatic' 'stopped+manual service gets the startup call'
    Assert-RecordedCall 'Start-Service -Name sshd' 'stopped+manual service gets the start call'
    $script:SshdServiceStatus = 'Running'
    $script:SshdServiceStartType = 'Automatic'
    $script:Calls = @()
    $null = (Set-SshdServiceDesired *>&1)
    if ($script:Calls.Count -eq 0) { Ok 'already Automatic+Running service gets zero calls' } else { Fail 'already Automatic+Running service gets zero calls' ($script:Calls -join '; ') }

    # 15. Ensure-TailscaleFirewallRule at unit level - the brief's three
    #     cases: missing rule, present rule, generic rule present.
    $script:FirewallRules = @{}
    $script:Calls = @()
    $null = (Ensure-TailscaleFirewallRule -Name 'OpenSSH-Tailscale' -Port 22 *>&1)
    Assert-RecordedCall 'New-NetFirewallRule -Name OpenSSH-Tailscale -LocalPort 22 -InterfaceAlias Tailscale -RemoteAddress 100.64.0.0/10*' 'missing rule gets the exact Tailscale-scoped New call'
    $script:FirewallRules = @{ 'OpenSSH-Tailscale' = 'True' }
    $script:Calls = @()
    $null = (Ensure-TailscaleFirewallRule -Name 'OpenSSH-Tailscale' -Port 22 *>&1)
    if ($script:Calls.Count -eq 0) { Ok 'present rule gets zero calls' } else { Fail 'present rule gets zero calls' ($script:Calls -join '; ') }
    $script:FirewallRules = @{ 'OpenSSH-Server-In-TCP' = 'True' }
    $script:Calls = @()
    $out = ((Ensure-TailscaleFirewallRule -Name 'OpenSSH-Tailscale' -Port 22 *>&1) -join "`n")
    Assert-RecordedCall 'Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Enabled False' 'generic rule presence gets the constraint call'
    Assert-OutputHas $out 'constrained' 'the constraint prints the warning line'

    # 16. Set-RdpEnabled at unit level: the registry write + the :3389 rule
    #     call when windows.rdp=true; nothing at all when it is false.
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/full-win.json'
    $cfg = Get-RemoteAccessConfig
    $script:RdpDenyTSConnections = 1
    $script:FirewallRules = @{}
    $script:Calls = @()
    $null = (Set-RdpEnabled -Config $cfg *>&1)
    Assert-RecordedCall 'Set-ItemProperty*fDenyTSConnections*Value 0*' 'rdp=true records the registry write'
    Assert-RecordedCall 'New-NetFirewallRule -Name RemoteDesktop-Tailscale -LocalPort 3389*' 'rdp=true records the :3389 rule call'
    $rdpOff = Join-Path $Tmp 'rdp-off.json'
    [IO.File]::WriteAllText($rdpOff, (Get-Content -Raw -LiteralPath $script:ConfigFixture).Replace('"rdp": true', '"rdp": false'))
    $script:ConfigFixture = $rdpOff
    $cfg = Get-RemoteAccessConfig
    $script:Calls = @()
    $null = (Set-RdpEnabled -Config $cfg *>&1)
    if ($script:Calls.Count -eq 0) { Ok 'rdp=false records zero calls' } else { Fail 'rdp=false records zero calls' ($script:Calls -join '; ') }
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/full-win.json'

    # 17. Invoke-WslReconcile with no :2222 row: the add is recorded with
    #     the exact listenaddress (tailscale ip -4) + connectaddress
    #     (current WSL IP), and the output carries the FAIL -> PASS repair
    #     sequence.
    $script:PortproxyTable = Format-PortproxyStubTable -Rows @()
    $script:WslIpLine = '172.20.9.9'
    $script:TailscaleIp = '100.64.0.1'
    $script:Calls = @()
    $out = ((Invoke-WslReconcile *>&1) -join "`n")
    Assert-RecordedCall 'netsh interface portproxy add v4tov4*listenaddress=100.64.0.1*listenport=2222*connectaddress=172.20.9.9*connectport=22*' 'missing row: reconcile records the exact portproxy add'
    if (($out.IndexOf('FAIL') -ge 0) -and ($out.IndexOf('PASS') -gt $out.IndexOf('FAIL'))) {
        Ok 'missing row: output carries the FAIL -> PASS repair sequence'
    } else {
        Fail 'missing row: output carries the FAIL -> PASS repair sequence' $out
    }

    # 18. Stale connectaddress (fixture WSL IP 172.20.1.5, current from the
    #     wsl.exe stub 172.20.9.9): EXACTLY delete + add recorded (no other
    #     rows touched), output PASS.
    $script:PortproxyTable = Format-PortproxyStubTable -Rows @(@{ ListenAddress = '100.64.0.1'; ListenPort = 2222; ConnectAddress = '172.20.1.5'; ConnectPort = 22 })
    $script:Calls = @()
    $out = ((Invoke-WslReconcile *>&1) -join "`n")
    Assert-RecordedCall 'netsh interface portproxy delete v4tov4*listenaddress=100.64.0.1*listenport=2222*' 'stale row: the managed row is deleted by its own listenaddress'
    Assert-RecordedCall 'netsh interface portproxy add v4tov4*listenaddress=100.64.0.1*listenport=2222*connectaddress=172.20.9.9*connectport=22*' 'stale row: the add re-targets the current WSL IP'
    $netshWrites = @($script:Calls | Where-Object { ($_.StartsWith('netsh interface portproxy delete')) -or ($_.StartsWith('netsh interface portproxy add')) })
    if ($netshWrites.Count -eq 2) { Ok 'stale row: exactly delete + add recorded (no other rows touched)' } else { Fail 'stale row: exactly delete + add recorded (no other rows touched)' ($script:Calls -join '; ') }
    Assert-OutputHas $out 'PASS' 'stale row: output PASS after the repair'

    # 19. Matching row: zero netsh mutations, output PASS - verify, never
    #     rewrite.
    $script:Calls = @()
    $out = ((Invoke-WslReconcile *>&1) -join "`n")
    Assert-NoRecordedCall 'netsh interface portproxy delete*' 'matching row: zero netsh mutations (delete)'
    Assert-NoRecordedCall 'netsh interface portproxy add*' 'matching row: zero netsh mutations (add)'
    Assert-OutputHas $out 'PASS' 'matching row: output PASS'

    # 20. Review Focus #1 - a broken wsl.exe channel is a WARN naming the
    #     manual action, never a crash, never a mutation. Both halves of the
    #     channel: --status failing and hostname -I failing.
    $script:PortproxyTable = Format-PortproxyStubTable -Rows @()
    $script:WslStatusOk = $false
    $script:Calls = @()
    $out = ((Invoke-WslReconcile *>&1) -join "`n")
    Assert-OutputHas $out 'WARN' 'wsl --status failing: WARN, no crash'
    Assert-OutputHas $out 'manual' 'wsl --status failing: the WARN names the manual action'
    Assert-NoRecordedCall 'netsh interface portproxy add*' 'wsl --status failing: no portproxy mutation'
    $script:WslStatusOk = $true
    $script:WslIpOk = $false
    $out = ((Invoke-WslReconcile *>&1) -join "`n")
    Assert-OutputHas $out 'WARN' 'hostname -I failing: WARN, no crash'
    Assert-OutputHas $out 'manual' 'hostname -I failing: the WARN names the manual action'
    Assert-NoRecordedCall 'netsh interface portproxy add*' 'hostname -I failing: no portproxy mutation'
    $script:WslIpOk = $true

    # 21. tailscale ip -4 unavailable with a repair pending: the WARN names
    #     the missing listenaddress and the portproxy is NOT mutated blind.
    $script:PortproxyTable = Format-PortproxyStubTable -Rows @()
    $script:TailscaleIpOk = $false
    $script:Calls = @()
    $out = ((Invoke-WslReconcile *>&1) -join "`n")
    Assert-OutputHas $out 'tailscale address unavailable' 'no tailscale address: the WARN names the missing listenaddress'
    Assert-NoRecordedCall 'netsh interface portproxy add*' 'no tailscale address: no blind portproxy add'
    $script:TailscaleIpOk = $true

    # 22. Register-WslReconcileTask: the install records TaskName + logon
    #     trigger + RunLevel Highest; the second call takes the update path
    #     (refresh recorded, no duplicate registration).
    $script:ReconcileTaskInstalled = $false
    $script:Calls = @()
    $null = (Register-WslReconcileTask *>&1)
    Assert-RecordedCall 'Register-ScheduledTask -TaskName dotfiles-wsl-reconcile -Trigger AtLogOn -RunLevel Highest' 'reconcile task: install recorded with task name, logon trigger, highest run level'
    $script:Calls = @()
    $null = (Register-WslReconcileTask *>&1)
    Assert-NoRecordedCall 'Register-ScheduledTask*' 'reconcile task: second call does not duplicate the registration'
    Assert-RecordedCall 'Set-ScheduledTask -TaskName dotfiles-wsl-reconcile -Trigger AtLogOn' 'reconcile task: second call records the update path'

    # 23. Publish-LoginKey -Target wsl (Review Focus #2): the appended line
    #     IS the .pub content, the pre-seeded lines echo intact, and the
    #     second call is already-authorized (no duplicate).
    $pubLine = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtur3Body9pQrT carlitos@task10-device'
    New-Item -ItemType Directory -Force -Path (Join-Path $Home_ '.ssh') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Home_ '.ssh/id_test.pub'), ($pubLine + "`n"))
    $script:WslAuthorizedKeys = @('ssh-ed25519 AAAApreexisting-one first@host', 'ssh-ed25519 AAAApreexisting-two second@host')
    $script:Calls = @()
    $out = ((Publish-LoginKey -Name 'id_test' -Target 'wsl' *>&1) -join "`n")
    if ((@($script:WslAuthorizedKeys).Count -eq 3) -and (@($script:WslAuthorizedKeys)[2] -ceq $pubLine)) {
        Ok 'wsl login key: the appended line is the .pub content'
    } else {
        Fail 'wsl login key: the appended line is the .pub content' (@($script:WslAuthorizedKeys) -join ' | ')
    }
    if ((@($script:WslAuthorizedKeys)[0] -eq 'ssh-ed25519 AAAApreexisting-one first@host') -and (@($script:WslAuthorizedKeys)[1] -eq 'ssh-ed25519 AAAApreexisting-two second@host')) {
        Ok 'wsl login key: the pre-seeded lines echo intact (append-only)'
    } else {
        Fail 'wsl login key: the pre-seeded lines echo intact (append-only)' (@($script:WslAuthorizedKeys) -join ' | ')
    }
    Assert-RecordedCall 'wsl.exe -u root authorize login key (inside WSL)' 'wsl login key: the append is recorded behind the wsl.exe -u root channel'
    Assert-OutputHas $out 'authorized (wsl)' 'wsl login key: first call reports authorized'
    Assert-NoTokenMaterial $out 'wsl login key: output carries no token material'
    $out = ((Publish-LoginKey -Name 'id_test' -Target 'wsl' *>&1) -join "`n")
    if (@($script:WslAuthorizedKeys).Count -eq 3) { Ok 'wsl login key: second call appends no duplicate' } else { Fail 'wsl login key: second call appends no duplicate' (@($script:WslAuthorizedKeys) -join ' | ') }
    Assert-OutputHas $out 'already authorized (wsl)' 'wsl login key: second call reports already authorized'

    # 24. Publish-LoginKey degraded paths: no public half and an unknown
    #     target are WARNs (never a crash, never a mutation); the windows
    #     arm's own scenarios are block 28 below.
    $out = ((Publish-LoginKey -Name 'id_absent' -Target 'wsl' *>&1) -join "`n")
    Assert-OutputHas $out 'no public half' 'missing .pub: the WARN names the missing half'
    if (@($script:WslAuthorizedKeys).Count -eq 3) { Ok 'missing .pub: authorized_keys untouched' } else { Fail 'missing .pub: authorized_keys untouched' (@($script:WslAuthorizedKeys) -join ' | ') }
    $out = ((Publish-LoginKey -Name 'id_test' -Target 'tablet' *>&1) -join "`n")
    Assert-OutputHas $out 'unknown target' 'unknown target: WARN skipped'

    # 25. The setup arm on a broken WSL (Review Focus #1 at setup level):
    #     the WARN names the manual action and setup still completes.
    $script:WslStatusOk = $false
    $out = Get-SetupOutput
    Assert-OutputHas $out 'wsl: not available' 'broken wsl in setup: the availability WARN'
    Assert-OutputHas $out 'next: verify key login' 'broken wsl in setup: setup still completes'
    Assert-NoTokenMaterial $out 'broken wsl in setup: output carries no token material'
    $script:WslStatusOk = $true

    # 26. fix (the cmd_fix twin): repair-only semantics. A stopped sshd gets
    #     the restart + the startup-mode restore; the declared firewall
    #     rules are re-ensured; the wsl portproxy is reconciled; a
    #     registered-but-stopped cloudflared service restarts; a healthy
    #     host records ZERO mutations (every arm's no-op path included); an
    #     unauthenticated backend holds serve AND the firewall; a broken WSL
    #     degrades to the WARN (Review Focus #1); a service whose target is
    #     0.0.0.0 is a FAIL with NO serve/exposure call (Review Focus #4);
    #     an absent config is a no-op.
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/full-win.json'
    $script:SshdServiceStatus = 'Stopped'
    $script:SshdServiceStartType = 'Manual'
    $script:FirewallRules = @{}
    $script:PortproxyTable = Format-PortproxyStubTable -Rows @()
    $script:WslIpLine = '172.20.9.9'
    $script:CloudflaredServiceStatus = 'Stopped'
    $script:Calls = @()
    $out = ((Invoke-RemoteFix *>&1) -join "`n")
    Assert-RecordedCall 'Restart-Service -Name sshd' 'stopped sshd: fix records the restart'
    Assert-RecordedCall 'Set-Service -Name sshd -StartupType Automatic' 'stopped sshd: fix restores the startup mode'
    Assert-OutputHas $out 'sshd restarted' 'stopped sshd: fix reports the restart'
    Assert-RecordedCall 'New-NetFirewallRule -Name OpenSSH-Tailscale -LocalPort 22*' 'fix re-ensures the :22 rule (windows.ssh)'
    Assert-RecordedCall 'New-NetFirewallRule -Name RemoteDesktop-Tailscale -LocalPort 3389*' 'fix re-ensures the :3389 rule (windows.rdp)'
    Assert-RecordedCall 'New-NetFirewallRule -Name WSL-SSH-Tailscale -LocalPort 2222*' 'fix re-ensures the :2222 rule (wsl.enabled)'
    Assert-RecordedCall 'netsh interface portproxy add v4tov4*listenaddress=100.64.0.1*listenport=2222*connectaddress=172.20.9.9*connectport=22*' 'fix reconciles the missing wsl portproxy'
    Assert-RecordedCall 'Restart-Service -Name cloudflared' 'registered-but-stopped cloudflared: fix restarts it'
    Assert-OutputHas $out 'cloudflared: service restarted' 'stopped cloudflared: fix reports the restart'
    $script:Calls = @()
    $out = ((Invoke-RemoteFix *>&1) -join "`n")
    Assert-OutputHas $out 'PASS wsl: portproxy :2222 -> 172.20.9.9:22 in sync' 'healthy host: the portproxy verifies in sync'
    Assert-OutputHas $out ($MarkOk + ' cloudflared: service running') 'healthy host: the running cloudflared service is verified, not bounced'
    if ($script:Calls.Count -eq 0) { Ok 'healthy host: fix records zero mutations (all arms verify)' } else { Fail 'healthy host: fix records zero mutations (all arms verify)' ($script:Calls -join '; ') }
    Assert-OutputHas $out 'tunnel config written' 'healthy host: fix re-renders the tunnel config (deterministic write)'
    $script:TailscaleStatusJson = '{"BackendState": "NeedsLogin"}'
    $out = ((Invoke-RemoteFix *>&1) -join "`n")
    Assert-OutputHas $out 'serve: skipped while tailscale is unauth' 'unauth tailscale: fix holds the serve path'
    Assert-OutputHas $out 'firewall: held while tailscale is unauth' 'unauth tailscale: fix holds the firewall path'
    Assert-NoRecordedCall 'tailscale serve*' 'unauth tailscale: fix records no serve call'
    Assert-NoRecordedCall 'New-NetFirewallRule*' 'unauth tailscale: fix records no firewall write'
    $script:TailscaleStatusJson = '{"BackendState": "Running", "CurrentTailnet": {"Name": "example.net"}, "Self": {"TailscaleIPs": ["100.64.0.1"]}}'
    $script:WslStatusOk = $false
    $script:Calls = @()
    $out = ((Invoke-RemoteFix *>&1) -join "`n")
    Assert-OutputHas $out 'WARN wsl: not available' 'broken wsl in fix: the availability WARN'
    Assert-NoRecordedCall 'netsh interface portproxy add*' 'broken wsl in fix: no portproxy mutation'
    $script:WslStatusOk = $true
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/nonloopback-service.json'
    $script:Calls = @()
    $out = ((Invoke-RemoteFix *>&1) -join "`n")
    Assert-OutputHas $out ($MarkFail + ' serve opencode_linux: target 0.0.0.0:4098 is not loopback - refused') '0.0.0.0 target: fix prints the FAIL naming the refusal'
    Assert-NoRecordedCall 'tailscale serve*' '0.0.0.0 target: fix records no serve/exposure call (Review Focus #4)'
    if ($script:Calls.Count -eq 0) { Ok '0.0.0.0 target: fix records no exposure mutation' } else { Fail '0.0.0.0 target: fix records no exposure mutation' ($script:Calls -join '; ') }
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/off.json'
    $script:Calls = @()
    $out = ((Invoke-RemoteFix *>&1) -join "`n")
    Assert-OutputHas $out 'not configured - see docs/remote-access.md' 'absent config: fix is the pointing no-op'
    if ($script:Calls.Count -eq 0) { Ok 'absent config: fix records zero calls' } else { Fail 'absent config: fix records zero calls' ($script:Calls -join '; ') }
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/full-win.json'

    # 27. harden-ssh (spec section 4): the guards fire in the bash twin's order -
    #     zero authorized keys first, then -Confirmed - a refusal is a
    #     terminating error and never writes sshd_config; with both guards
    #     met, exactly one prepended `PasswordAuthentication no` replaces
    #     every active+commented line (Match block intact), sshd restarts,
    #     and a second run is byte-identical.
    $ak = Join-Path $Home_ '.ssh/authorized_keys'
    $akLine = 'ssh-ed25519 AAAAharden-key0 operator@device'
    [IO.File]::WriteAllText($ak, ($akLine + "`n"))
    $sshdCfg = Join-Path $Tmp 'sshd_config'
    $sshdOriginal = '# sample sshd_config' + "`n" + '#PasswordAuthentication yes' + "`n" + 'PasswordAuthentication yes' + "`n" + 'PermitRootLogin no' + "`n" + 'Match User bot' + "`n" + '    PasswordAuthentication yes' + "`n"
    [IO.File]::WriteAllText($sshdCfg, $sshdOriginal)
    $env:RA_SSHD_CONFIG = $sshdCfg
    $script:Calls = @()
    $threw = $false
    try { $null = (Invoke-SshHardening *>&1) } catch { $threw = $true }
    if ($threw) { Ok 'no -Confirmed: harden-ssh refuses' } else { Fail 'no -Confirmed: harden-ssh refuses' 'no throw' }
    if ((Get-Content -Raw -LiteralPath $sshdCfg) -ceq $sshdOriginal) { Ok 'no -Confirmed: sshd_config untouched' } else { Fail 'no -Confirmed: sshd_config untouched' (Get-Content -Raw -LiteralPath $sshdCfg) }
    Assert-NoRecordedCall 'Restart-Service*' 'no -Confirmed: no sshd restart'
    Remove-Item -LiteralPath $ak -Force
    $threw = $false
    $refusal = ''
    try { $null = (Invoke-SshHardening -Confirmed *>&1) } catch { $threw = $true; $refusal = "$($_.Exception.Message)" }
    if ($threw -and $refusal -like '*no authorized key*') { Ok 'zero keys: harden-ssh refuses naming the key guard' } else { Fail 'zero keys: harden-ssh refuses naming the key guard' $refusal }
    $threw = $false
    $refusal = ''
    try { $null = (Invoke-SshHardening *>&1) } catch { $threw = $true; $refusal = "$($_.Exception.Message)" }
    if ($threw -and $refusal -like '*no authorized key*' -and $refusal -notlike '*Confirmed*') { Ok 'guard order: zero keys refuses before the -Confirmed guard' } else { Fail 'guard order: zero keys refuses before the -Confirmed guard' $refusal }
    [IO.File]::WriteAllText($ak, ($akLine + "`n"))
    $script:Calls = @()
    $out = ((Invoke-SshHardening -Confirmed *>&1) -join "`n")
    $hardened = (Get-Content -LiteralPath $sshdCfg) -join "`n"
    $hardenedLines = @($hardened -split "`n")
    if ($hardenedLines[0] -ceq 'PasswordAuthentication no') { Ok 'harden-ssh: the no line is prepended (first)' } else { Fail 'harden-ssh: the no line is prepended (first)' ($hardenedLines -join ' | ') }
    if (@($hardenedLines | Where-Object { $_ -like '*PasswordAuthentication*' }).Count -eq 2) { Ok 'harden-ssh: the global active+commented lines are dropped' } else { Fail 'harden-ssh: the global active+commented lines are dropped' ($hardenedLines -join ' | ') }
    if (@($hardenedLines | Where-Object { $_ -ceq '    PasswordAuthentication yes' }).Count -eq 1) { Ok 'harden-ssh: the Match-scoped indented line survives (bash-twin parity: only unindented lines are dropped)' } else { Fail 'harden-ssh: the Match-scoped indented line survives (bash-twin parity: only unindented lines are dropped)' ($hardenedLines -join ' | ') }
    if (($hardened -like '*PermitRootLogin no*') -and ($hardened -like '*Match User bot*')) { Ok 'harden-ssh: the rest of sshd_config is untouched' } else { Fail 'harden-ssh: the rest of sshd_config is untouched' $hardened }
    Assert-RecordedCall 'Restart-Service -Name sshd' 'harden-ssh: sshd restarts (key-only)'
    Assert-OutputHas $out 'PasswordAuthentication no' 'harden-ssh: the verdict names the write'
    $script:Calls = @()
    $null = (Invoke-SshHardening -Confirmed *>&1)
    if ((Get-Content -Raw -LiteralPath $sshdCfg) -ceq ($hardened + "`n")) { Ok 'second harden-ssh: byte-identical' } else { Fail 'second harden-ssh: byte-identical' (Get-Content -Raw -LiteralPath $sshdCfg) }
    Remove-Item -LiteralPath $ak -Force
    Remove-Item Env:RA_SSHD_CONFIG
    $r = Invoke-TwinChild @('harden-ssh', '--wat')
    if ($r.Exit -eq 1) { Ok 'unknown harden-ssh argument exits 1 through the dispatcher' } else { Fail 'unknown harden-ssh argument exits 1 through the dispatcher' ("exit=$($r.Exit) out=$($r.Output)") }
    Assert-OutputHas $r.Output 'unknown argument' 'the unknown-argument refusal names the argument'
    $r = Invoke-TwinChild @('harden-ssh')
    if ($r.Exit -eq 1) { Ok 'zero-keys harden-ssh exits 1 through the dispatcher' } else { Fail 'zero-keys harden-ssh exits 1 through the dispatcher' ("exit=$($r.Exit) out=$($r.Output)") }
    Assert-OutputHas $r.Output 'no authorized key' 'the zero-keys refusal names the key guard'

    # 28. Publish-LoginKey -Target windows (spec section 5.1): an admin account
    #     gets administrators_authorized_keys append-only plus the strict
    #     admins-only ACL grant recorded (inheritance disabled,
    #     Administrators:F); the second call is already-authorized and
    #     records nothing; a non-admin lands in the user's authorized_keys
    #     with no icacls anywhere.
    $script:LocalAdmin = $true
    $winLine = 'ssh-ed25519 AAAAwindows-key0 carlitos@task11-device'
    [IO.File]::WriteAllText((Join-Path $Home_ '.ssh/id_win.pub'), ($winLine + "`n"))
    $aaPath = Join-Path $env:ProgramData 'ssh/administrators_authorized_keys'
    $script:Calls = @()
    $out = ((Publish-LoginKey -Name 'id_win' -Target 'windows' *>&1) -join "`n")
    if ((Get-Content -Raw -LiteralPath $aaPath) -ceq ($winLine + "`n")) { Ok 'windows key: the appended line is the .pub content (file created)' } else { Fail 'windows key: the appended line is the .pub content (file created)' (Get-Content -Raw -LiteralPath $aaPath) }
    Assert-RecordedCall 'icacls * /inheritance:r /grant Administrators:F' 'windows key: the ACL grant is recorded (inheritance disabled, Administrators:F)'
    Assert-OutputHas $out 'authorized (windows)' 'windows key: first call reports authorized'
    Assert-NoTokenMaterial $out 'windows key: output carries no token material'
    $script:Calls = @()
    $out = ((Publish-LoginKey -Name 'id_win' -Target 'windows' *>&1) -join "`n")
    if ((@(Get-Content -LiteralPath $aaPath).Count -eq 1) -and (@($script:Calls).Count -eq 0)) { Ok 'windows key: second call is already-authorized, zero calls' } else { Fail 'windows key: second call is already-authorized, zero calls' (($script:Calls -join '; ') + ' | ' + (Get-Content -Raw -LiteralPath $aaPath)) }
    Assert-OutputHas $out 'already authorized (windows)' 'windows key: second call reports already authorized'
    $winLine2 = 'ssh-ed25519 AAAAwindows-key1 other@device'
    [IO.File]::WriteAllText((Join-Path $Home_ '.ssh/id_win2.pub'), ($winLine2 + "`n"))
    $script:Calls = @()
    $null = (Publish-LoginKey -Name 'id_win2' -Target 'windows' *>&1)
    $aaLines = @(Get-Content -LiteralPath $aaPath)
    if (($aaLines.Count -eq 2) -and ($aaLines[0] -ceq $winLine) -and ($aaLines[1] -ceq $winLine2)) { Ok 'windows key: a second key appends, the first line intact' } else { Fail 'windows key: a second key appends, the first line intact' ($aaLines -join ' | ') }
    Assert-RecordedCall 'icacls * /inheritance:r /grant Administrators:F' 'windows key: the append-riding ACL grant recorded again'
    $script:LocalAdmin = $false
    Remove-Item -LiteralPath (Join-Path $Home_ '.ssh/authorized_keys') -Force -ErrorAction SilentlyContinue
    $script:Calls = @()
    $out = ((Publish-LoginKey -Name 'id_win' -Target 'windows' *>&1) -join "`n")
    if ((Get-Content -Raw -LiteralPath $ak) -ceq ($winLine + "`n")) { Ok 'non-admin key: the user authorized_keys gets the line' } else { Fail 'non-admin key: the user authorized_keys gets the line' (Get-Content -Raw -LiteralPath $ak) }
    Assert-NoRecordedCall 'icacls*' 'non-admin key: no icacls anywhere'
    Assert-OutputHas $out 'authorized (windows)' 'non-admin key: reports authorized'
    $script:LocalAdmin = $true

    # 29. setup drives the declared login-key targets (keys-win-targets.json):
    #     windows into administrators_authorized_keys with its ACL grant,
    #     wsl through its channel, and the second pass records zero calls.
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/keys-win-targets.json'
    $script:LocalAdmin = $true
    $script:WslAuthorizedKeys = @()
    $script:Calls = @()
    $out = Get-SetupOutput
    Assert-RecordedCall 'icacls * /inheritance:r /grant Administrators:F' 'setup keys: the windows target gets the ACL grant'
    Assert-OutputHas $out 'authorized (windows)' 'setup keys: the windows target authorizes'
    Assert-RecordedCall 'wsl.exe -u root authorize login key (inside WSL)' 'setup keys: the wsl target authorizes through its channel'
    Assert-OutputHas $out 'authorized (wsl)' 'setup keys: the wsl target authorizes'
    $script:Calls = @()
    $out = Get-SetupOutput
    if ($script:Calls.Count -eq 0) { Ok 'setup keys: second pass records zero calls' } else { Fail 'setup keys: second pass records zero calls' ($script:Calls -join '; ') }
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/full-win.json'

    # 30. tunnel render/validate (the Task 3 assertions, mirrored): the
    #     render carries the id, credentials by path, every declared
    #     hostname/service pair and the terminal http_status:404 ALWAYS, is
    #     byte-identical on a re-render, and validate exits 0/1 with named
    #     findings (loopback, http_status:404) that never echo the config's
    #     own lines; RA_TUNNEL_CONFIG pins the file under test.
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/tunnel-full.json'
    $tunnelCfg = Join-Path $Tmp 'tunnel-alt/config.yml'
    $env:RA_TUNNEL_CONFIG = $tunnelCfg
    $out = ((Write-TunnelConfig *>&1) -join "`n")
    $rendered = Get-Content -Raw -LiteralPath $tunnelCfg
    foreach ($fragment in @('tunnel: 6ff42ae2-765d-4adf-8684-a115a1b92d95', 'credentials-file: ', '  - hostname: ssh.example.com', '  - hostname: wsl.example.com', '  - hostname: opencode.example.com', '    service: ssh://127.0.0.1:22', '    service: ssh://127.0.0.1:2222', '    service: http://127.0.0.1:4096')) {
        Assert-OutputHas $rendered $fragment "tunnel render carries: $fragment"
    }
    Assert-OutputHas $out 'tunnel config written' 'tunnel render: the verdict names the written path'
    $renderedLines = @($rendered -split "`r?`n")
    if ($renderedLines[$renderedLines.Count - 2] -ceq '  - service: http_status:404') { Ok 'tunnel render: the terminal http_status:404 is last' } else { Fail 'tunnel render: the terminal http_status:404 is last' ($renderedLines -join ' | ') }
    $iOpen = [array]::IndexOf($renderedLines, '  - hostname: opencode.example.com')
    $iSsh = [array]::IndexOf($renderedLines, '  - hostname: ssh.example.com')
    $iWsl = [array]::IndexOf($renderedLines, '  - hostname: wsl.example.com')
    if (($iOpen -lt $iSsh) -and ($iSsh -lt $iWsl) -and ($iOpen -ge 0)) { Ok 'tunnel render: ingress entries are sorted (byte-identical reruns)' } else { Fail 'tunnel render: ingress entries are sorted (byte-identical reruns)' ($renderedLines -join ' | ') }
    $bytes1 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tunnelCfg))
    $null = (Write-TunnelConfig *>&1)
    $bytes2 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tunnelCfg))
    if ($bytes1 -ceq $bytes2) { Ok 'tunnel render: a re-render is byte-identical' } else { Fail 'tunnel render: a re-render is byte-identical' 'bytes differ' }
    $r = Invoke-TwinChild @('tunnel', 'validate')
    if ($r.Exit -eq 0) { Ok 'tunnel validate: exits 0 on the rendered config' } else { Fail 'tunnel validate: exits 0 on the rendered config' ("exit=$($r.Exit) out=$($r.Output)") }
    Assert-OutputHas $r.Output 'tunnel config valid' 'tunnel validate: prints its verdict'
    $loopbackCfg = Join-Path $Tmp 'tunnel-loopback.yml'
    [IO.File]::WriteAllText($loopbackCfg, "tunnel: 6ff42ae2-765d-4adf-8684-a115a1b92d95`n`ningress:`n  - hostname: bad.example.com`n    service: http://10.0.0.5:8080`n  - service: http_status:404`n")
    $env:RA_TUNNEL_CONFIG = $loopbackCfg
    $r = Invoke-TwinChild @('tunnel', 'validate')
    if ($r.Exit -eq 1) { Ok 'tunnel validate: exits 1 on a non-loopback origin' } else { Fail 'tunnel validate: exits 1 on a non-loopback origin' ("exit=$($r.Exit) out=$($r.Output)") }
    Assert-OutputHas $r.Output 'loopback' 'tunnel validate: the finding is named loopback'
    if ($r.Output -notlike '*10.0.0.5*' -and $r.Output -notlike '*bad.example.com*') { Ok 'tunnel validate: the config lines are never echoed' } else { Fail 'tunnel validate: the config lines are never echoed' $r.Output }
    $noTerminal = Join-Path $Tmp 'tunnel-no-terminal.yml'
    [IO.File]::WriteAllText($noTerminal, (($rendered -split "`r?`n") | Where-Object { $_ -ne '  - service: http_status:404' }) -join "`n")
    $env:RA_TUNNEL_CONFIG = $noTerminal
    $r = Invoke-TwinChild @('tunnel', 'validate')
    if ($r.Exit -eq 1) { Ok 'tunnel validate: exits 1 without the terminal 404' } else { Fail 'tunnel validate: exits 1 without the terminal 404' ("exit=$($r.Exit) out=$($r.Output)") }
    Assert-OutputHas $r.Output 'http_status:404' 'tunnel validate: the finding is named http_status:404'
    $tokenCfg = Join-Path $Tmp 'tunnel-token.yml'
    [IO.File]::WriteAllText($tokenCfg, "tunnel: 6ff42ae2-765d-4adf-8684-a115a1b92d95`n# token eyAAABcGFzc3dvcmQmaterial1234567890`ningress:`n  - service: http://127.0.0.1:9999`n")
    $env:RA_TUNNEL_CONFIG = $tokenCfg
    $r = Invoke-TwinChild @('tunnel', 'validate')
    Assert-NoTokenMaterial $r.Output 'tunnel validate: output never echoes token material'
    $env:RA_TUNNEL_CONFIG = Join-Path $Tmp 'tunnel-absent.yml'
    $threw = $false
    try { $null = (Test-TunnelConfig *>&1) } catch { $threw = $true }
    if ($threw) { Ok 'tunnel validate: a missing config is a loud error' } else { Fail 'tunnel validate: a missing config is a loud error' 'no throw' }
    Remove-Item Env:RA_TUNNEL_CONFIG
    $null = (Write-TunnelConfig *>&1)
    if (Test-Path -LiteralPath (Join-Path $Home_ '.cloudflared/config.yml') -PathType Leaf) { Ok 'tunnel render: the default path is HOME/.cloudflared/config.yml' } else { Fail 'tunnel render: the default path is HOME/.cloudflared/config.yml' 'no file' }
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/full-win.json'

    # 31. Invoke-ServeApply (the ra_serve_apply twin): two tailscale=true
    #     services map as two path-scoped serve calls with 127.0.0.1
    #     targets; the second apply verifies in place and records ZERO
    #     calls.
    $twoSvc = Join-Path $Tmp 'two-services.json'
    [IO.File]::WriteAllText($twoSvc, (Get-Content -Raw -LiteralPath $script:ConfigFixture).Replace('"services": {', '"services": { "opencode_two": { "enabled": true, "environment": "windows", "port": 4097, "tailscale": true, "cloudflare": true },'))
    $script:ConfigFixture = $twoSvc
    $script:TailscaleServeStatus = ''
    $script:Calls = @()
    $out = ((Invoke-ServeApply *>&1) -join "`n")
    Assert-RecordedCall 'tailscale serve --bg --set-path /opencode_windows http://127.0.0.1:4096' 'serve: the first service maps path-scoped with a 127.0.0.1 target'
    Assert-RecordedCall 'tailscale serve --bg --set-path /opencode_two http://127.0.0.1:4097' 'serve: the second service maps path-scoped with a 127.0.0.1 target'
    $serveCalls = @($script:Calls | Where-Object { $_ -like 'tailscale serve --bg*' })
    if ($serveCalls.Count -eq 2) { Ok 'serve: exactly two mappings applied' } else { Fail 'serve: exactly two mappings applied' ($script:Calls -join '; ') }
    Assert-OutputHas $out 'mapped /opencode_windows to http://127.0.0.1:4096' 'serve: the verdict names the mapping'
    $script:Calls = @()
    $null = (Invoke-ServeApply *>&1)
    $serveCalls = @($script:Calls | Where-Object { $_ -like 'tailscale serve --bg*' })
    if ($serveCalls.Count -eq 0) { Ok 'serve: the second apply verifies in place, zero calls' } else { Fail 'serve: the second apply verifies in place, zero calls' ($script:Calls -join '; ') }
    $script:TailscaleServeStatus = 'https://machine.example.net:443 path / --> http://127.0.0.1:4096'
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/full-win.json'

    # 32. The dispatcher's wsl-reconcile arm (spec sections 4/9): the
    #     --install-task flag registers the logon task FIRST and still
    #     reconciles - driven through Invoke-RemoteAccess at dispatcher
    #     level (the seam gap that hid the silent @Rest splat); every flag
    #     spelling matches; an unknown argument is the exit-1 refusal
    #     through the child dispatcher.
    $script:WslIpLine = '172.20.9.9'
    $script:PortproxyTable = Format-PortproxyStubTable -Rows @(@{ ListenAddress = '100.64.0.1'; ListenPort = 2222; ConnectAddress = $script:WslIpLine; ConnectPort = 22 })
    $script:ReconcileTaskInstalled = $false
    $script:Calls = @()
    $out = ((Invoke-RemoteAccess 'wsl-reconcile' '--install-task' *>&1) -join "`n")
    Assert-RecordedCall 'Register-ScheduledTask -TaskName dotfiles-wsl-reconcile -Trigger AtLogOn -RunLevel Highest' 'dispatcher --install-task: the task registration is recorded'
    if (($out.IndexOf('reconcile task installed') -ge 0) -and ($out.IndexOf('PASS') -gt $out.IndexOf('reconcile task installed'))) {
        Ok 'dispatcher --install-task: registration first, then the reconcile (PASS)'
    } else {
        Fail 'dispatcher --install-task: registration first, then the reconcile (PASS)' $out
    }
    $script:ReconcileTaskInstalled = $false
    $script:Calls = @()
    $null = ((Invoke-RemoteAccess 'wsl-reconcile' '-InstallTask' *>&1))
    Assert-RecordedCall 'Register-ScheduledTask -TaskName dotfiles-wsl-reconcile*' 'dispatcher -InstallTask (single dash, mixed case) registers too'
    $script:ReconcileTaskInstalled = $false
    $script:Calls = @()
    $null = ((Invoke-RemoteAccess 'wsl-reconcile' '--InstallTask' *>&1))
    Assert-RecordedCall 'Register-ScheduledTask -TaskName dotfiles-wsl-reconcile*' 'dispatcher --InstallTask (double dash) registers too'
    $r = Invoke-TwinChild @('wsl-reconcile', '--wat')
    if ($r.Exit -eq 1) { Ok 'unknown wsl-reconcile argument exits 1 through the dispatcher' } else { Fail 'unknown wsl-reconcile argument exits 1 through the dispatcher' ("exit=$($r.Exit) out=$($r.Output)") }
    Assert-OutputHas $r.Output 'unknown argument' 'the wsl-reconcile refusal names the argument'

    # 33. fix's cloudflared arm, absent service: nothing to repair - the
    #     quiet skip (zero calls, no crash, never an install).
    $script:CloudflaredServiceStatus = $null
    $script:Calls = @()
    $null = ((Invoke-CloudflaredServiceFix *>&1))
    if ($script:Calls.Count -eq 0) { Ok 'absent cloudflared service: fix skips quietly (zero calls)' } else { Fail 'absent cloudflared service: fix skips quietly (zero calls)' ($script:Calls -join '; ') }
    $script:CloudflaredServiceStatus = 'Running'

    # 34-38. Initialize-LoginKey (the ra_login_key_materialize twin, spec
    #        section 5.1) - the bash suite's blocks 16-22 mirrored: Pattern
    #        A non-interactive, the RA_CONFIRM_MATERIALIZE seam, Pattern B,
    #        generate=false, and the idempotent present path.
    Remove-Item -Recurse -Force (Join-Path $Home_ '.ssh') -ErrorAction SilentlyContinue
    $env:RA_NONINTERACTIVE = '1'
    $script:Calls = @()
    $out = ((Initialize-LoginKey -Name 'id_test' *>&1) -join "`n")
    Assert-OutputHas $out 'not created' 'pattern A non-interactive: WARN not created'
    Assert-NoRecordedCall 'ssh-keygen*' 'pattern A non-interactive: no ssh-keygen recorded'
    if (-not (Test-Path -LiteralPath (Join-Path $Home_ '.ssh/id_test') -PathType Leaf)) { Ok 'pattern A non-interactive: no key files created' } else { Fail 'pattern A non-interactive: no key files created' 'private half exists' }
    Remove-Item -Recurse -Force (Join-Path $Home_ '.ssh') -ErrorAction SilentlyContinue
    $env:RA_CONFIRM_MATERIALIZE = '1'
    $script:Calls = @()
    $out = ((Initialize-LoginKey -Name 'id_test' *>&1) -join "`n")
    Remove-Item Env:RA_CONFIRM_MATERIALIZE
    Remove-Item Env:RA_NONINTERACTIVE
    Assert-OutputHas $out 'created' 'pattern A seam: reports created'
    $expPriv = Join-Path (Join-Path $Home_ '.ssh') 'id_test'
    Assert-RecordedCall "ssh-keygen '-t' 'ed25519' '-f' '$expPriv' '-N' ''" 'pattern A seam: the exact empty-passphrase keygen call (the empty passphrase exists only in the seam)'
    Assert-RecordedCall 'icacls *id_test /inheritance:r /grant *:F' 'pattern A seam: the strict ACL grant rides the creation'
    if (Test-Path -LiteralPath (Join-Path $Home_ '.ssh/id_test') -PathType Leaf) { Ok 'pattern A seam: the private half is materialized' } else { Fail 'pattern A seam: the private half is materialized' 'no file' }
    Remove-Item -Recurse -Force (Join-Path $Home_ '.ssh') -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $Home_ '.ssh') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Home_ '.ssh/id_test.pub'), "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4bGmSPbKDIX6g9uAAaf7UNuYF8b2TmXLamtGpiI6Cd dropped@other-device`n")
    $script:Calls = @()
    $out = ((Initialize-LoginKey -Name 'id_test' *>&1) -join "`n")
    Assert-OutputHas $out 'public half present, inbound-only' 'pattern B: the dropped public half is used as-is'
    if (($out -notlike '*not created*') -and ($out -notlike '*missing*')) { Ok 'pattern B: no not-created / missing-private-key complaint' } else { Fail 'pattern B: no not-created / missing-private-key complaint' $out }
    if ($script:Calls.Count -eq 0) { Ok 'pattern B: zero calls (no generation, no ACL)' } else { Fail 'pattern B: zero calls (no generation, no ACL)' ($script:Calls -join '; ') }
    Remove-Item -Recurse -Force (Join-Path $Home_ '.ssh') -ErrorAction SilentlyContinue
    $script:Calls = @()
    $out = ((Initialize-LoginKey -Name 'id_test' -Generate:$false *>&1) -join "`n")
    Assert-OutputHas $out 'drop the public half' 'generate=false: the WARN names the drop action'
    Assert-NoRecordedCall 'ssh-keygen*' 'generate=false: no ssh-keygen recorded'
    if (-not (Test-Path -LiteralPath (Join-Path $Home_ '.ssh/id_test') -PathType Leaf)) { Ok 'generate=false: no private half created' } else { Fail 'generate=false: no private half created' 'private half exists' }
    New-Item -ItemType Directory -Force -Path (Join-Path $Home_ '.ssh') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Home_ '.ssh/id_test'), 'private-key-placeholder')
    $script:Calls = @()
    $out = ((Initialize-LoginKey -Name 'id_test' *>&1) -join "`n")
    Assert-OutputHas $out 'present' 'existing private half: verified present'
    if ($script:Calls.Count -eq 0) { Ok 'existing private half: zero calls (the ACL grant rides the creation only)' } else { Fail 'existing private half: zero calls (the ACL grant rides the creation only)' ($script:Calls -join '; ') }

    # 39. setup drives materialize-then-publish (spec section 5.1 order):
    #     with a fresh .ssh and the confirm seam, setup creates the key
    #     (empty-passphrase seam call, the strict ACL grant riding it) and
    #     authorizes BOTH declared targets in the same pass; the second
    #     pass records zero calls (the present key verifies, publish
    #     dedups).
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/keys-win-targets.json'
    $script:LocalAdmin = $true
    $script:WslAuthorizedKeys = @()
    Remove-Item -Recurse -Force (Join-Path $Home_ '.ssh') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:ProgramData 'ssh/administrators_authorized_keys') -Force -ErrorAction SilentlyContinue
    $env:RA_NONINTERACTIVE = '1'
    $env:RA_CONFIRM_MATERIALIZE = '1'
    $script:Calls = @()
    $out = Get-SetupOutput
    Remove-Item Env:RA_CONFIRM_MATERIALIZE
    Remove-Item Env:RA_NONINTERACTIVE
    $expPriv = Join-Path (Join-Path $Home_ '.ssh') 'id_test'
    Assert-RecordedCall "ssh-keygen '-t' 'ed25519' '-f' '$expPriv' '-N' ''" 'setup keys: the seam materializes the key (empty passphrase in the seam only)'
    Assert-RecordedCall 'icacls *id_test /inheritance:r /grant *:F' 'setup keys: the strict ACL grant rides the creation'
    Assert-RecordedCall 'wsl.exe -u root authorize login key (inside WSL)' 'setup keys: the wsl target authorizes the new key'
    Assert-OutputHas $out 'login key id_test: created' 'setup keys: materialize runs first and reports created'
    Assert-OutputHas $out 'authorized (windows)' 'setup keys: publish then authorizes (windows)'
    Assert-OutputHas $out 'authorized (wsl)' 'setup keys: publish then authorizes (wsl)'
    $script:Calls = @()
    $out = Get-SetupOutput
    if ($script:Calls.Count -eq 0) { Ok 'setup keys: second pass records zero calls' } else { Fail 'setup keys: second pass records zero calls' ($script:Calls -join '; ') }

    # 40. setup with a generate=false key and no .pub dropped (the bash
    #     suite's block 28): the declared WARN path fires ('drop the public
    #     half'), never the non-interactive one, and no ssh-keygen runs.
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/keys-generate-false.json'
    Remove-Item -Recurse -Force (Join-Path $Home_ '.ssh') -ErrorAction SilentlyContinue
    $env:RA_NONINTERACTIVE = '1'
    $script:Calls = @()
    $out = Get-SetupOutput
    Remove-Item Env:RA_NONINTERACTIVE
    Assert-OutputHas $out 'drop the public half' 'setup generate=false: the declared WARN names the drop action'
    if ($out -notlike '*not created*') { Ok 'setup generate=false: the declared path, not the non-interactive one' } else { Fail 'setup generate=false: the declared path, not the non-interactive one' $out }
    Assert-NoRecordedCall 'ssh-keygen*' 'setup generate=false: no ssh-keygen anywhere'
    $script:ConfigFixture = Join-Path $RepoRoot 'tests/fixtures/remote_access/full-win.json'
} finally {
    $env:HOME = $savedHome
    $env:USERPROFILE = $savedProfile
    $env:ProgramData = $savedProgramData
    Remove-Item Env:RA_SSHD_CONFIG -ErrorAction SilentlyContinue
    Remove-Item Env:RA_TUNNEL_CONFIG -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

if ($script:Failed.Count -gt 0) {
    Write-Host "FAIL: remote_access.ps1 ($($script:Failed.Count) assertion(s)): $($script:Failed -join '; ')"
    exit 1
}
Write-Host "PASS: remote_access.ps1 ($script:PassCount assertions)"
exit 0
