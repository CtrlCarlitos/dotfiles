#Requires -Version 5.1
# scripts/remote-access.ps1 - `dot remote` Windows twin: the machine-local
# plumbing for private remote access (Tailscale as the primary path, SSH/RDP
# as the transport, tmux/psmux as session persistence, Cloudflare Tunnel +
# Access as the optional browser path). Runs natively on the Windows host
# and orchestrates WSL from outside via wsl.exe; Linux and macOS are driven
# by scripts/remote-access.sh. Called by the `dot` dispatchers (`dot remote
# <subcommand>`) or directly from scripts/. Configuration comes from
# `chezmoi data` ([data.remote_access], machine-local, never committed);
# provider-side steps (tailnet enrollment, `cloudflared tunnel login`,
# Access policies) stay manual and are never automated here.
#
# This file is pure ASCII on purpose: Windows PowerShell 5.1 reads a BOM-less
# UTF-8 script in the system ANSI codepage, and the UTF-8 bytes of the
# doctor's literal glyphs end in 0x93 - cp1252's right curly quote - which
# unbalances string parsing before a single statement runs. The markers are
# built from codepoints instead (see the status section below).
#
# `status` is the read-only doctor (spec section 7 Windows columns): one
# section per area - Tailscale, SSH, RDP, WSL, Tailscale Serve, Cloudflare,
# Applications, tmux - with check / warn / fail marker lines, exit 0 always.
# FAIL lines name what `fix` would repair; WARN lines
# name the manual action. Never prints secrets: probe stderr is discarded
# and only verdicts are printed. `setup` idempotently configures the Windows
# arm (sshd, the Tailscale-scoped firewall rules, RDP, and the WSL arm:
# sshd inside the distro, the wsl-target login keys, the :2222 portproxy
# reconcile with its rule, the logon reconcile task) behind the same
# recorded-call seams the bash twin's tests pin; the remaining subcommands
# (fix, harden-ssh, tunnel, serve) are skeleton stubs that throw with their
# landing task (Task 11 fills them in behind the same surface the bash twin
# implements). `wsl-reconcile` is the reconcile arm the logon task re-runs:
# it re-syncs the managed :2222 portproxy to the current WSL IP and reports
# PASS/WARN/FAIL lines, degrading every broken probe (wsl.exe, the WSL IP,
# the tailscale listenaddress) to a WARN naming the manual action.

param() # arguments stay in $args for the main guard's splat; the test
        # harness dot-sources this file with REMOTE_ACCESS_NO_MAIN=1 instead

$ErrorActionPreference = 'Stop'

function Write-RemoteUsage {
    # usage goes to stderr: a wrong subcommand must not pollute stdout.
    [Console]::Error.WriteLine(@"
usage: remote-access.ps1 <subcommand> [args]

dot remote - personal remote access plumbing (#165). Tailscale provides
connectivity; SSH/RDP provide remote access; tmux/psmux provide session
persistence. Cloudflare Tunnel is the optional browser path, only behind
Cloudflare Access.

subcommands:
  setup             idempotently configure this host's remote-access plumbing
  status            read-only doctor: report the current state
  fix               repair deterministic machine-local state only
  harden-ssh        flip sshd to key-only (guarded; needs -Confirmed)
  wsl-reconcile     re-sync the :2222 portproxy to the current WSL IP
  tunnel render     write the machine-local cloudflared config.yml
  tunnel validate   validate the local cloudflared config.yml

Config: [data.remote_access] in your machine-local chezmoi config.
Manual provider steps are never automated by this script.
"@)
}

# ---------------------------------------------------------------------------
# config - [data.remote_access] from `chezmoi data` (spec section 5). An unreadable
# or absent key resolves to $null; status/setup/fix degrade from there.
# ---------------------------------------------------------------------------

function Get-RemoteHome {
    # The operator home for machine-local state (~/.cloudflared): $env:HOME
    # where it exists, USERPROFILE otherwise - the bash twin's ${HOME}.
    # Tests repoint both at a scratch dir, so nothing resolves ambient state.
    if (-not [string]::IsNullOrEmpty($env:HOME)) { return $env:HOME }
    return $env:USERPROFILE
}

function Get-RemoteQuietOutput {
    # Get-RemoteQuietOutput SCRIPTBLOCK: stdout of a probe whose stderr is
    # discarded, $null when the command cannot run at all. Every native
    # probe goes through here. Two 5.1 facts make the easing mandatory:
    # native stderr becomes an error record, and with
    # $ErrorActionPreference = 'Stop' the record is terminating even for a
    # 2>$null redirect - a chatty CLI would crash the doctor, which exits 0
    # in every case.
    param([Parameter(Mandatory = $true)][scriptblock]$Command)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = @(& $Command 2>$null)
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $saved
    }
    return (($raw -join "`n").Trim())
}

function Get-RemoteAccessConfig {
    # The [data.remote_access] object from `chezmoi data --format json`, or
    # $null when the key is absent or the data cannot be read - the
    # ra_data_json twin. chezmoi's stderr is discarded: its output is
    # configuration, and the doctor never prints configuration content.
    $raw = (Get-RemoteQuietOutput { & chezmoi data --format json })
    if ([string]::IsNullOrEmpty($raw)) { return $null }
    $doc = $null
    try {
        $doc = $raw | ConvertFrom-Json
    } catch {
        return $null
    }
    if ($null -eq $doc) { return $null }
    $remote = $doc.remote_access
    if ($null -eq $remote) { return $null }
    return $remote
}

function Get-RemoteConfigValue {
    # Get-RemoteConfigValue CONFIG PATH [DEFAULT]: read a dotted path out of
    # the [data.remote_access] object, DEFAULT when the path is absent -
    # the ra_cfg twin. Missing segments and missing properties both resolve
    # to the default; values keep their JSON types (booleans stay booleans).
    param(
        [Parameter(Position = 0)]$Config,
        [Parameter(Position = 1)][string]$Path,
        [Parameter(Position = 2)]$Default = $null
    )
    $current = $Config
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $Default }
        $current = $property.Value
    }
    if ($null -eq $current) { return $Default }
    return $current
}

# ---------------------------------------------------------------------------
# checks - the probe layer status reads (and setup will gate on). Each one
# degrades to a state word or $null instead of throwing: a missing tool or
# an unreadable table is a verdict for the doctor to render, never a crash.
# ---------------------------------------------------------------------------

function Get-TailscaleStatusJson {
    # The parsed `tailscale status --json` document, $null when the CLI
    # answers nothing usable. stderr is discarded (output is configuration).
    $raw = (Get-RemoteQuietOutput { & tailscale status --json })
    if ([string]::IsNullOrEmpty($raw)) { return $null }
    try {
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-TailscaleState {
    # Resolves the tailscale CLI into absent | unauth | ok - the
    # ra_tailscale_state twin. unauth covers everything short of a Running
    # backend; the doctor renders it as the authenticate WARN, never a crash.
    if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) { return 'absent' }
    $doc = Get-TailscaleStatusJson
    if ($null -eq $doc) { return 'unauth' }
    if ($doc.BackendState -eq 'Running') { return 'ok' }
    return 'unauth'
}

function Get-TailscaleIpv4 {
    # The first IPv4 of `tailscale ip -4` - the portproxy listenaddress, so
    # the :2222 mapping listens on the Windows tailscale address only and
    # never internet-wide (spec section 9). $null when the CLI answers
    # nothing IPv4-shaped; the reconcile arm degrades that to the
    # manual-action WARN instead of writing a blind rule.
    $raw = (Get-RemoteQuietOutput { & tailscale ip -4 })
    if ([string]::IsNullOrEmpty($raw)) { return $null }
    $first = (($raw -split "`r?`n")[0] -split '\s+')[0]
    if ($first -match '^\d{1,3}(\.\d{1,3}){3}$') { return $first }
    return $null
}

function Get-SshdState {
    # Windows sshd state: absent (no service), stopped, running - the
    # ra_sshd_state twin for the Windows column. Read-only: nothing here
    # starts or configures the service.
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return 'absent' }
    # String compare, not the ServiceControllerStatus enum: 5.1 resolves
    # that type only after the REAL Get-Service has loaded its assembly,
    # and the twin never forces it (the tests override the cmdlet).
    if ([string]$svc.Status -eq 'Running') { return 'running' }
    return 'stopped'
}

function Test-WslAvailable {
    # True when wsl.exe resolves AND answers `--status` (best-effort: a
    # broken WSL install reports not-available rather than crashing - the
    # plan's Review Focus #1 shape).
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    $null = Get-RemoteQuietOutput { & wsl.exe --status }
    return ($LASTEXITCODE -eq 0)
}

function Get-WslIp {
    # The current WSL IPv4 (first token of `hostname -I` inside WSL), $null
    # when the channel fails. Never cached: the address changes on every
    # WSL reboot, which is exactly what wsl-reconcile re-syncs.
    $line = (Get-RemoteQuietOutput { & wsl.exe hostname -I })
    if ([string]::IsNullOrEmpty($line)) { return $null }
    $first = ($line -split '\s+')[0]
    if ($first -match '^\d{1,3}(\.\d{1,3}){3}$') { return $first }
    return $null
}

function Get-PortproxyRow {
    # The full v4tov4 row listening on <Port> - the managed :2222 rule is
    # identified by its listenport in the `netsh interface portproxy show
    # v4tov4` table - as a ListenAddress/ListenPort/ConnectAddress/
    # ConnectPort object, $null when netsh fails or no row matches. The
    # delete half of a stale repair needs the row's own listenaddress, so
    # the doctor's connect-only read sits on top of this
    # (Get-PortproxyConnectAddress).
    param([Parameter(Position = 0)][int]$Port)
    $table = (Get-RemoteQuietOutput { & netsh interface portproxy show v4tov4 })
    if ([string]::IsNullOrEmpty($table)) { return $null }
    foreach ($line in ($table -split "`r?`n")) {
        if ($line -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s*$') {
            if ([int]$Matches[2] -eq $Port) {
                return New-Object -TypeName PSObject -Property @{ ListenAddress = $Matches[1]; ListenPort = [int]$Matches[2]; ConnectAddress = $Matches[3]; ConnectPort = [int]$Matches[4] }
            }
        }
    }
    return $null
}

function Get-PortproxyConnectAddress {
    # The connectaddress of the listenport <Port> row in the v4tov4
    # portproxy table, $null when netsh fails or no row matches - the
    # :2222 -> WSL :22 mapping the reconcile arm owns.
    param([Parameter(Position = 0)][int]$Port)
    $row = Get-PortproxyRow -Port $Port
    if ($null -eq $row) { return $null }
    return $row.ConnectAddress
}

function Test-RemoteTcpPort {
    # Best-effort loopback TCP connect with a short async timeout - the
    # ra_tcp_probe twin. [Net.Sockets.TcpClient] instead of
    # Test-NetConnection: the cmdlet's full probe takes seconds per port,
    # which is doctor-hostile. rc $true = something accepted the connect.
    param(
        [Parameter(Position = 0)][string]$TargetHost,
        [Parameter(Position = 1)][int]$Port,
        [Parameter(Position = 2)][int]$TimeoutMs = 1000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ---------------------------------------------------------------------------
# status - the read-only doctor (spec section 7 Windows columns). One section
# per area, check / warn / fail marker lines, exit 0 always. FAIL lines name
# what `fix` would repair; WARN lines name the manual action. Never prints
# secrets: probes that could echo configuration (cloudflared validate,
# chezmoi data) run quietly and only the verdict is printed.
# ---------------------------------------------------------------------------

# The doctor's markers - verified, absent / skipped / WARN (the line names
# the manual action), FAIL - built from codepoints so this source stays
# ASCII (see the header: 5.1 misreads BOM-less UTF-8, and one marker byte
# is a quote in cp1252). Runtime strings are real Unicode on every host.
$script:MarkOk = [string][char]0x2713   # check mark
$script:MarkWarn = [string][char]0x25CB # open circle
$script:MarkFail = [string][char]0x2717 # ballot X
function Write-RemoteStatusOk([string]$line)   { Write-Host ($script:MarkOk + " " + $line) }
function Write-RemoteStatusWarn([string]$line) { Write-Host ($script:MarkWarn + " " + $line) }
function Write-RemoteStatusFail([string]$line) { Write-Host ($script:MarkFail + " " + $line) }

function Get-RemoteStatusTailscale {
    Write-Host 'Tailscale:'
    switch (Get-TailscaleState) {
        'absent' {
            Write-RemoteStatusWarn 'tailscale: not installed (manual: install Tailscale, then run: tailscale up)'
        }
        'unauth' {
            Write-RemoteStatusWarn 'tailscale: not authenticated - manual action required: authenticate (run: tailscale up, then log in)'
        }
        'ok' {
            $doc = Get-TailscaleStatusJson
            $name = $doc.CurrentTailnet.Name
            if (-not $name) { $name = 'unknown tailnet' }
            $address = 'none'
            if (($null -ne $doc.Self.TailscaleIPs) -and ($doc.Self.TailscaleIPs.Count -gt 0)) {
                $address = $doc.Self.TailscaleIPs[0]
            }
            Write-RemoteStatusOk ("tailscale: connected (tailnet: $name, address: $address)")
        }
    }
}

function Get-RemoteStatusSsh {
    # The Windows column of the SSH section: the OpenSSH Server capability's
    # sshd service. Screen Sharing-style macOS checks live in the bash twin.
    param($Config)
    Write-Host 'SSH:'
    if ((Get-RemoteConfigValue $Config 'windows.ssh' $false) -ne $true) {
        Write-RemoteStatusWarn 'ssh: not configured for this host (windows.ssh)'
        return
    }
    switch (Get-SshdState) {
        'running' { Write-RemoteStatusOk 'ssh: sshd active' }
        'stopped' {
            Write-RemoteStatusFail 'ssh: sshd not active (fix: Set-Service -Name sshd -StartupType Automatic; Start-Service sshd)'
        }
        'absent' {
            Write-RemoteStatusWarn 'ssh: sshd not installed (manual: install the OpenSSH Server optional capability)'
        }
    }
}

function Get-RemoteStatusRdp {
    # The Windows column of the RDP section: the Remote Desktop toggle in
    # the registry (fDenyTSConnections). Screen Sharing is not applicable on
    # Windows - it is the macOS recovery path.
    param($Config)
    Write-Host 'RDP:'
    if ((Get-RemoteConfigValue $Config 'windows.rdp' $false) -ne $true) {
        Write-RemoteStatusWarn 'rdp: not configured for this host (windows.rdp)'
        return
    }
    $deny = $null
    $props = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
        -Name fDenyTSConnections -ErrorAction SilentlyContinue
    if ($null -ne $props) { $deny = $props.fDenyTSConnections }
    if ($null -eq $deny) {
        Write-RemoteStatusWarn 'rdp: Remote Desktop state unavailable (check manually: System Properties > Remote)'
    } elseif ($deny -eq 0) {
        Write-RemoteStatusOk 'rdp: Remote Desktop enabled'
    } else {
        Write-RemoteStatusFail 'rdp: Remote Desktop disabled (fix: enable Remote Desktop)'
    }
}

function Get-RemoteStatusWsl {
    # The WSL rows (spec section 7): availability, sshd inside WSL through the
    # wsl.exe channel, and the :2222 portproxy compared against the current
    # WSL IP. Everything is best-effort - a broken WSL degrades to WARNs.
    param($Config)
    Write-Host 'WSL:'
    if ((Get-RemoteConfigValue $Config 'wsl.enabled' $false) -ne $true) {
        Write-RemoteStatusWarn 'wsl: not configured for this host (wsl.enabled)'
        return
    }
    if (-not (Test-WslAvailable)) {
        Write-RemoteStatusWarn 'wsl: not available (manual: install WSL2, then re-run: dot remote status)'
        return
    }
    # sshd inside WSL: systemd first, then the SysV script, then a bare
    # sshd process - the probe must survive distros without systemd.
    $probe = 'if systemctl is-active ssh >/dev/null 2>&1; then echo active; elif service ssh status >/dev/null 2>&1; then echo active; elif pidof sshd >/dev/null 2>&1; then echo active; else echo inactive; fi'
    $wslSshd = (Get-RemoteQuietOutput { & wsl.exe -e sh -c $probe })
    switch ($wslSshd) {
        'active'   { Write-RemoteStatusOk 'wsl: sshd active' }
        'inactive' { Write-RemoteStatusFail 'wsl: sshd not active (fix: enable sshd inside WSL)' }
        default    { Write-RemoteStatusWarn 'wsl: sshd state unavailable (check manually: wsl.exe -e sh -c "systemctl is-active ssh")' }
    }
    # The :2222 portproxy, compared against the current WSL IP (best-effort).
    $port = [int](Get-RemoteConfigValue $Config 'wsl.ssh_port' 2222)
    $row = Get-PortproxyConnectAddress -Port $port
    $current = Get-WslIp
    if (($null -eq $row) -and ($null -eq $current)) {
        Write-RemoteStatusWarn 'wsl: portproxy state unavailable (check manually: netsh interface portproxy show v4tov4)'
    } elseif ($null -eq $row) {
        Write-RemoteStatusFail ("wsl: no :${port} portproxy (fix: dot remote wsl-reconcile)")
    } elseif ($null -eq $current) {
        Write-RemoteStatusWarn ("wsl: portproxy :${port} -> ${row}:22, current WSL IP unavailable (check manually: wsl.exe hostname -I)")
    } elseif ($row -eq $current) {
        Write-RemoteStatusOk ("wsl: portproxy :${port} -> ${current}:22 in sync")
    } else {
        Write-RemoteStatusFail ("wsl: portproxy :${port} -> ${row}:22 is stale, WSL is now ${current} (fix: dot remote wsl-reconcile)")
    }
}

function Get-RemoteStatusServe {
    Write-Host 'Tailscale Serve:'
    switch (Get-TailscaleState) {
        'absent' {
            Write-RemoteStatusWarn 'serve: skipped (tailscale not installed)'
            return
        }
        'unauth' {
            Write-RemoteStatusWarn 'serve: skipped (tailscale not authenticated)'
            return
        }
    }
    $status = (Get-RemoteQuietOutput { & tailscale serve status })
    if ([string]::IsNullOrEmpty($status) -or ($status -match 'no serve configuration')) {
        Write-RemoteStatusWarn 'serve: none active (dot remote setup re-applies the configured mappings)'
        return
    }
    Write-RemoteStatusOk 'serve: active mappings'
    foreach ($line in ($status -split "`r?`n")) {
        Write-Host ("  " + $line)
    }
}

function Get-RemoteStatusCloudflare {
    Write-Host 'Cloudflare:'
    if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
        Write-RemoteStatusWarn 'cloudflared: not installed'
        return
    }
    $cfgPath = Join-Path (Get-RemoteHome) '.cloudflared/config.yml'
    if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) {
        Write-RemoteStatusWarn ("cloudflared: no local tunnel config at ${cfgPath} (dot remote tunnel render writes it)")
        return
    }
    # Validate quietly: cloudflared's errors can echo config lines, and the
    # doctor never prints configuration content - verdict only.
    $null = Get-RemoteQuietOutput { & cloudflared tunnel ingress validate --config $cfgPath }
    if ($LASTEXITCODE -eq 0) {
        Write-RemoteStatusOk ("cloudflared: tunnel config valid (${cfgPath})")
    } else {
        Write-RemoteStatusFail ("cloudflared: tunnel config invalid (${cfgPath}) (fix: dot remote tunnel render)")
    }
}

function Get-RemoteStatusService {
    # One row per configured service (spec section 7, Applications): loopback
    # targets only - a non-127.0.0.1 host is a FAIL naming the problem, a
    # live listener is verified through a short TCP connect.
    param($Config)
    Write-Host 'Applications:'
    $services = Get-RemoteConfigValue $Config 'services'
    if ($null -eq $services) {
        Write-RemoteStatusWarn 'applications: none configured'
        return
    }
    foreach ($entry in $services.PSObject.Properties) {
        $name = $entry.Name
        $svc = $entry.Value
        if ((Get-RemoteConfigValue $svc 'enabled' $false) -ne $true) {
            Write-RemoteStatusWarn "${name}: disabled"
            continue
        }
        $targetHost = Get-RemoteConfigValue $svc 'host' '127.0.0.1'
        $port = Get-RemoteConfigValue $svc 'port' $null
        $environment = Get-RemoteConfigValue $svc 'environment' 'unknown'
        if ($targetHost -ne '127.0.0.1') {
            Write-RemoteStatusFail "${name}: target ${targetHost}:${port} is not loopback (fix: bind the app to 127.0.0.1)"
            continue
        }
        if (-not $port) {
            Write-RemoteStatusWarn "${name}: no port configured (${environment})"
            continue
        }
        if (Test-RemoteTcpPort -TargetHost $targetHost -Port ([int]$port)) {
            Write-RemoteStatusOk "${name}: listening on 127.0.0.1:${port} (${environment})"
        } else {
            Write-RemoteStatusFail "${name}: not listening on 127.0.0.1:${port} (${environment}; start the app or fix its bind)"
        }
    }
}

function Get-RemoteStatusTmux {
    # `tmux` resolves to psmux on Windows; session persistence is read-only
    # here (fix never touches tmux). Unresolved -> one WARN circle line.
    Write-Host 'tmux:'
    if (-not (Get-Command tmux -ErrorAction SilentlyContinue)) {
        Write-RemoteStatusWarn 'tmux: not installed (session persistence unavailable here)'
        return
    }
    $sessions = (Get-RemoteQuietOutput { & tmux ls })
    if ([string]::IsNullOrEmpty($sessions)) {
        Write-RemoteStatusWarn 'tmux: no active sessions'
        return
    }
    Write-RemoteStatusOk 'tmux: active sessions'
    foreach ($line in ($sessions -split "`r?`n")) {
        Write-Host ("  " + $line)
    }
}

function Get-RemoteStatus {
    # The doctor (spec section 7 Windows columns). Read-only; with
    # [data.remote_access] absent or disabled there is nothing to doctor.
    # Sections run best-effort: a probe failing inside one section degrades
    # that section, never the doctor - exit 0 in every case.
    $config = Get-RemoteAccessConfig
    if (($null -eq $config) -or ((Get-RemoteConfigValue $config 'enabled' $false) -ne $true)) {
        Write-Host 'not configured'
        return
    }
    foreach ($section in @(
            { Get-RemoteStatusTailscale }
            { Get-RemoteStatusSsh $config }
            { Get-RemoteStatusRdp $config }
            { Get-RemoteStatusWsl $config }
            { Get-RemoteStatusServe }
            { Get-RemoteStatusCloudflare }
            { Get-RemoteStatusService $config }
            { Get-RemoteStatusTmux }
        )) {
        try {
            & $section
        } catch {
            $sectionName = (($section.ToString().Trim()) -split '\s+')[0]
            Write-RemoteStatusFail ("section probe failed: ${sectionName}")
        }
    }
}

# ---------------------------------------------------------------------------
# writers - the setup-era writes, each idempotent (verify-don't-rewrite) and
# seam-recorded in the tests. The stubs that remain throw with their landing
# task so an arm reached too early fails loudly at the dispatcher instead of
# silently doing nothing; Task 10 landed the WSL arm behind these seams and
# Task 11 fills the rest in the same way.
# ---------------------------------------------------------------------------

function Set-SshdServiceDesired {
    # sshd -> StartupType Automatic + running, idempotent: each half is
    # written only when the read state differs, so an already-correct host
    # records no service calls at all. A missing service is the capability
    # presence verdict - setup checks prerequisites, never installs (the
    # installers own the OpenSSH Server optional capability) - reported as
    # the manual action, never a crash. No ShouldProcess on purpose: the
    # setup subcommand is the operator's explicit intent and a
    # non-interactive run must never prompt (the bash twin's sshd enable
    # carries no confirm gate either). The tests pin the writes through
    # Get-Service / Set-Service / Start-Service overrides.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'the setup subcommand is the explicit intent carrier and a non-interactive run must never prompt; the bash twin carries no confirm gate either (twin parity, invariant #10)')]
    param()
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-RemoteStatusWarn 'ssh: sshd not installed (manual: install the OpenSSH Server optional capability)'
        return
    }
    # String compares, not the enums: 5.1 resolves ServiceControllerStatus
    # (and the StartType enum) only after the REAL cmdlets have loaded their
    # assemblies, and the tests override the cmdlets - the same string
    # compare the doctor's Get-SshdState uses.
    $changed = $false
    if ([string]$svc.StartType -ne 'Automatic') {
        Set-Service -Name sshd -StartupType Automatic
        $changed = $true
    }
    if ([string]$svc.Status -ne 'Running') {
        Start-Service -Name sshd
        $changed = $true
    }
    if ($changed) {
        Write-RemoteStatusOk 'ssh: sshd enabled and started (StartupType Automatic)'
    } else {
        Write-RemoteStatusOk 'ssh: sshd already active (Automatic + running)'
    }
}

function Ensure-TailscaleFirewallRule {
    # Ensure-TailscaleFirewallRule -Name <rule> -Port <port>: the generic
    # writer behind the three Tailscale-scoped rules (:22 OpenSSH-Tailscale,
    # :2222 WSL-SSH-Tailscale, :3389 RemoteDesktop-Tailscale). Inbound TCP on
    # the Tailscale interface only, remote address the CGNAT tailnet address
    # space - never internet-wide. An already-present rule is verified, not
    # rewritten (zero calls); a generic internet-wide OpenSSH rule (what the
    # Windows capability creates) is constrained - a restriction, so allowed
    # in setup (spec section 6) - and the constraint is said so, once: a rule
    # already disabled records no call at all. Seams:
    # Get-NetFirewallRule / New-NetFirewallRule / Set-NetFirewallRule (the
    # tests override all three).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Ensure- is the plan-mandated surface name; kept for twin parity (invariant #10)')]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Port
    )
    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $rule) {
        New-NetFirewallRule -Name $Name -DisplayName $Name -Direction Inbound -Protocol TCP `
            -LocalPort $Port -Action Allow -InterfaceAlias 'Tailscale' -RemoteAddress '100.64.0.0/10' | Out-Null
        Write-RemoteStatusOk ("firewall: rule ${Name} created (TCP :${Port}, Tailscale-scoped)")
    } else {
        Write-RemoteStatusOk ("firewall: rule ${Name} already present (TCP :${Port}, Tailscale-scoped)")
    }
    # The generic internet-wide OpenSSH rule: constrain it in favor of the
    # scoped rule. Verify-first: already disabled means already constrained -
    # no call, no repeat warning (idempotency, executed on reruns).
    $generic = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if (($null -ne $generic) -and ([string]$generic.Enabled -eq 'True')) {
        Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled False
        Write-RemoteStatusWarn ("firewall: generic OpenSSH-Server-In-TCP rule constrained (disabled) in favor of ${Name} - the Tailscale-scoped rule replaces it")
    }
}

function Set-RdpEnabled {
    # RDP on, only when windows.rdp = true - the config owns the intent, this
    # function owns the two writes: the fDenyTSConnections registry flip
    # (0 = allow Terminal Services connections; verify-first, so an already-0
    # value records no write) and the Tailscale-scoped :3389 rule through the
    # generic firewall writer. The registry write goes through the
    # Set-ItemProperty seam. No ShouldProcess for the same reason as
    # Set-SshdServiceDesired above.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'the setup subcommand is the explicit intent carrier and a non-interactive run must never prompt; the bash twin carries no confirm gate either (twin parity, invariant #10)')]
    param($Config)
    if ((Get-RemoteConfigValue $Config 'windows.rdp' $false) -ne $true) { return }
    $deny = $null
    $props = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
        -Name fDenyTSConnections -ErrorAction SilentlyContinue
    if ($null -ne $props) { $deny = $props.fDenyTSConnections }
    if ($deny -ne 0) {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
            -Name fDenyTSConnections -Value 0
        Write-RemoteStatusOk 'rdp: Remote Desktop enabled (fDenyTSConnections 0)'
    } else {
        Write-RemoteStatusOk 'rdp: Remote Desktop already enabled'
    }
    Ensure-TailscaleFirewallRule -Name 'RemoteDesktop-Tailscale' -Port 3389
}

function Add-PortproxyRow {
    # netsh interface portproxy add for the managed mapping. The listener is
    # the Windows tailscale address (never 0.0.0.0 - tailnet side only,
    # spec section 9); netsh output is discarded and the caller verifies
    # through a fresh read, so a failed add surfaces as the verify FAIL.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'the wsl-reconcile subcommand is the explicit intent carrier and a non-interactive run must never prompt (twin parity, invariant #10)')]
    param(
        [Parameter(Mandatory = $true)][string]$ListenAddress,
        [Parameter(Mandatory = $true)][int]$ListenPort,
        [Parameter(Mandatory = $true)][string]$ConnectAddress,
        [Parameter(Mandatory = $true)][int]$ConnectPort
    )
    $netshArgs = @('interface', 'portproxy', 'add', 'v4tov4', "listenaddress=$ListenAddress", "listenport=$ListenPort", "connectaddress=$ConnectAddress", "connectport=$ConnectPort")
    $null = Get-RemoteQuietOutput { & netsh @netshArgs }
}

function Remove-PortproxyRow {
    # netsh interface portproxy delete for exactly one row, addressed by its
    # own listenaddress + listenport - a stale repair never touches other
    # rows.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'the wsl-reconcile subcommand is the explicit intent carrier and a non-interactive run must never prompt (twin parity, invariant #10)')]
    param(
        [Parameter(Mandatory = $true)][string]$ListenAddress,
        [Parameter(Mandatory = $true)][int]$ListenPort
    )
    $netshArgs = @('interface', 'portproxy', 'delete', 'v4tov4', "listenaddress=$ListenAddress", "listenport=$ListenPort")
    $null = Get-RemoteQuietOutput { & netsh @netshArgs }
}

function Enable-WslSsh {
    # Best-effort sshd enable inside WSL through the wsl.exe -u root channel
    # (systemd first, the SysV script as fallback, non-fatal inside the
    # distro). Spec section 9 keeps the sshd configuration manual; setup
    # only issues the enable. A failed channel is the manual-action WARN,
    # never a crash.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'the setup subcommand is the explicit intent carrier and a non-interactive run must never prompt (twin parity, invariant #10)')]
    param()
    $enable = 'systemctl enable --now ssh >/dev/null 2>&1 || service ssh start >/dev/null 2>&1 || true; echo wsl-ssh-enabled'
    $out = (Get-RemoteQuietOutput { & wsl.exe -u root -e sh -c $enable })
    if (($LASTEXITCODE -eq 0) -and ($out -eq 'wsl-ssh-enabled')) {
        Write-RemoteStatusOk 'wsl: sshd enable issued inside WSL (best-effort)'
    } else {
        Write-RemoteStatusWarn 'wsl: sshd enable inside WSL failed (manual: wsl.exe -u root -e sh -c "systemctl enable --now ssh")'
    }
}

function Invoke-WslReconcile {
    # The wsl-reconcile arm (spec section 9): re-sync the managed :2222
    # portproxy to the current WSL IP (first token of `wsl.exe hostname -I`,
    # never cached - the address changes on every WSL reboot). The managed
    # row is the v4tov4 row whose listenport is the configured ssh port;
    # the listenaddress comes from `tailscale ip -4` and a missing address
    # blocks the repair with the manual-action WARN instead of writing a
    # blind rule. Output is PASS/WARN/FAIL lines: a missing or stale row
    # prints its FAIL, repairs with exactly one delete (the stale row's own
    # listenaddress) plus one add, verifies with a fresh read and only then
    # prints PASS; a matching row prints PASS with zero netsh mutations.
    # Every degraded probe - wsl.exe, the WSL IP, the tailscale address -
    # is a WARN naming the manual action, never a crash (plan Review Focus
    # #1). No ShouldProcess: the subcommand IS the explicit repair intent
    # and a non-interactive run must never prompt.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'the wsl-reconcile subcommand is the explicit intent carrier and a non-interactive run must never prompt (twin parity, invariant #10)')]
    param()
    $config = Get-RemoteAccessConfig
    $port = [int](Get-RemoteConfigValue $config 'wsl.ssh_port' 2222)
    if (-not (Test-WslAvailable)) {
        Write-Host 'WARN wsl: not available (manual: install WSL2, then re-run: dot remote wsl-reconcile)'
        return
    }
    $wslIp = Get-WslIp
    if ([string]::IsNullOrEmpty($wslIp)) {
        Write-Host 'WARN wsl: current WSL IP unavailable (manual: check wsl.exe hostname -I, then re-run: dot remote wsl-reconcile)'
        return
    }
    $row = Get-PortproxyRow -Port $port
    if (($null -ne $row) -and ($row.ConnectAddress -eq $wslIp)) {
        Write-Host "PASS wsl: portproxy :${port} -> ${wslIp}:22 in sync"
        return
    }
    if ($null -eq $row) {
        Write-Host "FAIL wsl: no :${port} portproxy (repairing: add ${wslIp}:22)"
    } else {
        Write-Host "FAIL wsl: portproxy :${port} -> $($row.ConnectAddress):22 is stale, WSL is now ${wslIp} (repairing: delete + add)"
    }
    $tsIp = Get-TailscaleIpv4
    if ([string]::IsNullOrEmpty($tsIp)) {
        Write-Host "WARN wsl: tailscale address unavailable (manual: tailscale ip -4, then: netsh interface portproxy add v4tov4 listenaddress=<tailscale-ip> listenport=${port} connectaddress=${wslIp} connectport=22)"
        return
    }
    if ($null -ne $row) {
        Remove-PortproxyRow -ListenAddress $row.ListenAddress -ListenPort $port
    }
    Add-PortproxyRow -ListenAddress $tsIp -ListenPort $port -ConnectAddress $wslIp -ConnectPort 22
    $check = Get-PortproxyRow -Port $port
    if (($null -ne $check) -and ($check.ConnectAddress -eq $wslIp)) {
        Write-Host "PASS wsl: portproxy :${port} -> ${wslIp}:22 in sync"
    } else {
        Write-Host "FAIL wsl: portproxy :${port} repair did not verify (check manually: netsh interface portproxy show v4tov4)"
    }
}

function Register-WslReconcileTask {
    # The dotfiles-wsl-reconcile logon Scheduled Task: at logon, highest run
    # level (the netsh portproxy writes need it), re-running this script's
    # wsl-reconcile arm. Idempotent: a present task is refreshed through
    # Set-ScheduledTask (the update path), never registered twice. Seams:
    # Get-ScheduledTask / New-ScheduledTaskAction / New-ScheduledTaskTrigger
    # / Register-ScheduledTask / Set-ScheduledTask - the tests override all
    # five, so none of them ever runs for real in a test host.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'the setup subcommand is the explicit intent carrier and a non-interactive run must never prompt (twin parity, invariant #10)')]
    param()
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" wsl-reconcile")
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    if ($null -eq (Get-ScheduledTask -TaskName 'dotfiles-wsl-reconcile' -ErrorAction SilentlyContinue)) {
        Register-ScheduledTask -TaskName 'dotfiles-wsl-reconcile' -Action $action -Trigger $trigger -RunLevel Highest | Out-Null
        Write-RemoteStatusOk 'wsl: reconcile task installed (dotfiles-wsl-reconcile, logon trigger, RunLevel Highest)'
    } else {
        Set-ScheduledTask -TaskName 'dotfiles-wsl-reconcile' -Action $action -Trigger $trigger | Out-Null
        Write-RemoteStatusOk 'wsl: reconcile task refreshed (dotfiles-wsl-reconcile)'
    }
}

function Publish-LoginKey {
    # Publish-LoginKey -Name <key> -Target <target>: authorize the PUBLIC
    # half (~/.ssh/<name>.pub) for <target>. The private half is never
    # read, never moved, never printed. The wsl target rides the
    # wsl.exe -u root channel with an append-only heredoc: grep -Fxq guards
    # the exact line, existing authorized_keys lines are never rewritten,
    # and a second run is already-authorized (Review Focus #2; the
    # ra_authorized_keys_install twin). The windows target (the
    # administrators_authorized_keys + admins-only ACL arm) is Task 11;
    # anything else is the unknown-target WARN skip. No prompt anywhere: a
    # declared-but-missing key degrades to the no-public-half WARN.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'the setup subcommand is the explicit intent carrier and a non-interactive run must never prompt (twin parity, invariant #10)')]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Target
    )
    if ($Target -eq 'windows') {
        throw 'Publish-LoginKey: target windows: not implemented until Task 11 (ps1 fix/harden-ssh/keys/tunnel/serve)'
    }
    if ($Target -ne 'wsl') {
        Write-RemoteStatusWarn "login key ${Name}: unknown target ${Target} - skipped"
        return
    }
    $pub = Join-Path (Get-RemoteHome) ".ssh/${Name}.pub"
    if (-not (Test-Path -LiteralPath $pub -PathType Leaf)) {
        Write-RemoteStatusWarn "login key ${Name}: no public half at ${pub} - nothing to authorize into wsl"
        return
    }
    $line = $null
    foreach ($candidate in ((Get-Content -Raw -LiteralPath $pub) -split "`r?`n")) {
        $trimmed = $candidate.Trim()
        if (-not [string]::IsNullOrEmpty($trimmed)) { $line = $trimmed; break }
    }
    if ([string]::IsNullOrEmpty($line)) {
        Write-RemoteStatusWarn "login key ${Name}: ${pub} is empty - nothing to authorize into wsl"
        return
    }
    if ($line -match "'") {
        # A single quote would break the sh single-quoted guard: refuse the
        # publish instead of writing a mangled authorized_keys line.
        Write-RemoteStatusWarn "login key ${Name}: unexpected character in the public half - skipped (verify ${pub})"
        return
    }
    # Append-only heredoc through the wsl.exe channel: umask + mkdir first
    # so a fresh authorized_keys lands 600, grep -Fxq makes the exact line
    # idempotent, the quoted RAKEY delimiter keeps the key verbatim.
    $sh = "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -Fxq '${line}' ~/.ssh/authorized_keys || cat >> ~/.ssh/authorized_keys <<'RAKEY'`n${line}`nRAKEY"
    $out = (Get-RemoteQuietOutput { & wsl.exe -u root -e sh -c $sh })
    if (($LASTEXITCODE -ne 0) -or [string]::IsNullOrEmpty($out)) {
        Write-RemoteStatusWarn "login key ${Name}: wsl channel failed (manual: check WSL, then authorize ${pub} inside the distro)"
        return
    }
    if ($out -eq 'present') {
        Write-RemoteStatusOk "login key ${Name}: already authorized (wsl)"
    } else {
        Write-RemoteStatusOk "login key ${Name}: authorized (wsl)"
    }
}

function Publish-WslLoginKeys {
    # Drive Publish-LoginKey for every [[data.remote_access.login_keys]]
    # entry whose targets contain `wsl` - this arm's install (the
    # ra_setup_login_keys twin, inverted). Key materialization is not this
    # arm's job: a declared-but-missing key degrades to the no-public-half
    # WARN inside Publish-LoginKey, never a prompt (Review Focus #5's
    # non-interactive shape).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'the plural names the [data.remote_access.login_keys] collection the loop drives, one Publish-LoginKey call per entry; kept for twin parity with ra_setup_login_keys (invariant #10)')]
    param($Config)
    $keys = Get-RemoteConfigValue $Config 'login_keys' $null
    if ($null -eq $keys) { return }
    foreach ($entry in @($keys)) {
        $name = Get-RemoteConfigValue $entry 'name' ''
        $targets = Get-RemoteConfigValue $entry 'targets' $null
        if ((-not [string]::IsNullOrEmpty($name)) -and ($null -ne $targets) -and (@($targets) -contains 'wsl')) {
            Publish-LoginKey -Name $name -Target 'wsl'
        }
    }
}

function Invoke-SshHardening {
    # Task 11: the key-only flip behind the -Confirmed guard + an
    # authorized-keys presence check (the cmd_harden_ssh twin).
    throw 'Invoke-SshHardening: not implemented until Task 11 (ps1 fix/harden-ssh/keys/tunnel/serve)'
}

function Write-TunnelConfig {
    # Task 11: render ~/.cloudflared/config.yml from
    # [data.remote_access.tunnel]; terminal http_status:404 always appended.
    throw 'Write-TunnelConfig: not implemented until Task 11 (ps1 fix/harden-ssh/keys/tunnel/serve)'
}

function Test-TunnelConfig {
    # Task 11: line-scan the local config - loopback origins + terminal 404;
    # named findings, never echoing the config's own lines.
    throw 'Test-TunnelConfig: not implemented until Task 11 (ps1 fix/harden-ssh/keys/tunnel/serve)'
}

# ---------------------------------------------------------------------------
# setup - the Windows arm of `dot remote setup` (spec section 6). Prerequisites
# are checked, never installed (the installer groups own installation); an
# unauthenticated Tailscale prints the issue's ACTION REQUIRED block and
# stops only the Tailscale-dependent paths (the tailnet-scoped firewall rules
# and RDP, whose rule half is one of them); every write verifies current
# state first, so an already-correct host records no mutations, and setup
# exits non-zero only on hard failure. The WSL arm (spec section 9) runs
# behind its [data.remote_access.wsl] gate: sshd inside the distro, the
# wsl-target login keys, the :2222 portproxy reconcile with its rule, and
# the logon reconcile task; serve mappings, tunnel render, and the
# windows-target login keys land with Task 11 behind this orchestration.
# ---------------------------------------------------------------------------

function Invoke-RemoteSetup {
    # Not configured: a no-op, never a crash, never a mutation (the bash
    # cmd_setup parity).
    $config = Get-RemoteAccessConfig
    if (($null -eq $config) -or ((Get-RemoteConfigValue $config 'enabled' $false) -ne $true)) {
        Write-Host 'not configured'
        return
    }
    # Gate first: the state every Tailscale-dependent path below branches on.
    $tsState = Get-TailscaleState
    switch ($tsState) {
        'ok' {
            Write-RemoteStatusOk 'tailscale: connected'
        }
        'unauth' {
            Write-RemoteStatusWarn 'tailscale: not authenticated'
            Write-Host 'ACTION REQUIRED:'
            Write-Host 'Authenticate this host with Tailscale, then rerun:'
            Write-Host '    dot remote setup'
        }
        'absent' {
            Write-RemoteStatusWarn 'tailscale: not installed (manual: install Tailscale, then run: tailscale up)'
        }
    }
    # Prerequisites: presence checks only (spec section 6). cloudflared's
    # service registration stays a printed elevated manual step.
    if (Get-Command cloudflared -ErrorAction SilentlyContinue) {
        Write-RemoteStatusOk 'cloudflared: present (service registration stays manual: cloudflared service install)'
    } else {
        Write-RemoteStatusWarn 'cloudflared: not installed (manual: install cloudflared before using the browser path)'
    }
    # Windows transport write independent of Tailscale: sshd (the
    # missing-service case inside is the capability presence check - never an
    # install from here).
    if ((Get-RemoteConfigValue $config 'windows.ssh' $false) -eq $true) {
        Set-SshdServiceDesired
    }
    # Tailscale-dependent paths: the tailnet-scoped firewall rules and RDP
    # (whose rule half is one of them - Set-RdpEnabled is one atomic unit per
    # the plan's surface table) run only behind the authenticated gate - the
    # bash twin's cmd_setup shape, where only `ok` proceeds.
    if ($tsState -eq 'ok') {
        if ((Get-RemoteConfigValue $config 'windows.ssh' $false) -eq $true) {
            Ensure-TailscaleFirewallRule -Name 'OpenSSH-Tailscale' -Port 22
        }
        Set-RdpEnabled -Config $config
    } else {
        Write-RemoteStatusWarn "firewall: held while tailscale is ${tsState} (dependent paths held)"
        if ((Get-RemoteConfigValue $config 'windows.rdp' $false) -eq $true) {
            Write-RemoteStatusWarn "rdp: held while tailscale is ${tsState} (dependent paths held)"
        }
    }
    # WSL arm (spec section 9), gated on [data.remote_access.wsl] enabled =
    # true. A broken WSL degrades to the availability WARN naming the manual
    # action - never a crash (plan Review Focus #1). The sshd enable, the
    # login-key publication, and the reconcile task are machine-local writes
    # independent of Tailscale; the portproxy + its :2222 rule are
    # Tailscale-dependent (the listenaddress IS the Windows tailscale
    # address) and stay held behind the same authenticated gate as the
    # Windows rules. The task install sits behind its own presence check so
    # an already-correct host records no calls (Register-WslReconcileTask's
    # refresh path stays reachable for direct calls).
    if ((Get-RemoteConfigValue $config 'wsl.enabled' $false) -eq $true) {
        if (-not (Test-WslAvailable)) {
            Write-RemoteStatusWarn 'wsl: not available (manual: install WSL2, then re-run: dot remote setup)'
        } else {
            Enable-WslSsh
            Publish-WslLoginKeys -Config $config
            if ($null -eq (Get-ScheduledTask -TaskName 'dotfiles-wsl-reconcile' -ErrorAction SilentlyContinue)) {
                Register-WslReconcileTask
            } else {
                Write-RemoteStatusOk 'wsl: reconcile task already installed (dotfiles-wsl-reconcile)'
            }
            if ($tsState -eq 'ok') {
                Invoke-WslReconcile
                Ensure-TailscaleFirewallRule -Name 'WSL-SSH-Tailscale' -Port ([int](Get-RemoteConfigValue $config 'wsl.ssh_port' 2222))
            } else {
                Write-RemoteStatusWarn "wsl: portproxy held while tailscale is ${tsState} (dependent paths held)"
            }
        }
    }
    # Serve mappings, tunnel render, and the windows-target login keys land
    # with Task 11; the dispatcher's remaining arms still throw until then.
    Write-Host 'next: verify key login from another device, then run: dot remote harden-ssh'
}

# ---------------------------------------------------------------------------
# dispatch - the same subcommand surface the bash twin's main() resolves.
# An unknown (or missing) subcommand prints usage on stderr and exits 2.
# ---------------------------------------------------------------------------

function Invoke-RemoteAccess {
    param(
        [Parameter(Position = 0)][string]$Sub = '',
        [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @()
    )
    switch ($Sub) {
        'setup' {
            Invoke-RemoteSetup
        }
        'status' {
            Get-RemoteStatus
        }
        'fix' {
            throw 'fix: not implemented until Task 11 (ps1 fix/harden-ssh/keys/tunnel/serve)'
        }
        'harden-ssh' {
            Invoke-SshHardening @Rest
        }
        'wsl-reconcile' {
            Invoke-WslReconcile @Rest
        }
        'tunnel' {
            $mode = ''
            if ($Rest.Count -gt 0) { $mode = [string]$Rest[0] }
            switch ($mode) {
                'render'   { Write-TunnelConfig }
                'validate' { Test-TunnelConfig }
                default    { Write-RemoteUsage; exit 2 }
            }
        }
        default {
            Write-RemoteUsage
            exit 2
        }
    }
}

# REMOTE_ACCESS_NO_MAIN=1 keeps dispatch off: the test harness dot-sources
# this file and drives the functions level (the bash twin's RA_NO_MAIN
# mirror). Every direct caller goes through the guard below.
if (-not $env:REMOTE_ACCESS_NO_MAIN) { Invoke-RemoteAccess @args }
