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
# anywhere matches token-shaped material. Runs on pwsh 7 AND Windows
# PowerShell 5.1 (5.1-only syntax throughout, no skip exits - the Windows
# CI block runs this file under powershell.exe).

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
$script:RdpDenyTSConnections = 0
$script:WslStatusOk = $true
$script:WslSshProbe = 'active'
$script:WslIpLine = '172.28.120.45'
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
    $global:LASTEXITCODE = 1
    return $null
}

function Get-Service {
    # The sshd seam: the twin asks Get-Service about sshd; the harness
    # answers with canned state so the real cmdlet never runs.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the override IS the seam - the twin must be probed, not the host')]
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -eq 'sshd') {
        if ([string]::IsNullOrEmpty($script:SshdServiceStatus)) { return $null }
        return New-Object -TypeName PSObject -Property @{ Name = 'sshd'; Status = $script:SshdServiceStatus }
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

function wsl.exe {
    $global:LASTEXITCODE = 0
    $call = $args -join ' '
    if ($call -eq '--status') {
        if (-not $script:WslStatusOk) {
            $global:LASTEXITCODE = 1
            return $null
        }
        return 'wsl available'
    }
    if ($call -like '-e sh -c *') { return $script:WslSshProbe }
    if ($call -eq 'hostname -I') { return ($script:WslIpLine + ' ') }
    $global:LASTEXITCODE = 1
    return $null
}

function netsh {
    $global:LASTEXITCODE = 0
    $call = $args -join ' '
    if ($call -eq 'interface portproxy show v4tov4') { return $script:PortproxyTable }
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

try {
    $env:HOME = $Home_
    $env:USERPROFILE = $Home_

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
} finally {
    $env:HOME = $savedHome
    $env:USERPROFILE = $savedProfile
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

if ($script:Failed.Count -gt 0) {
    Write-Host "FAIL: remote_access.ps1 ($($script:Failed.Count) assertion(s)): $($script:Failed -join '; ')"
    exit 1
}
Write-Host "PASS: remote_access.ps1 ($script:PassCount assertions)"
exit 0
