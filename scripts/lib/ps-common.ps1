#Requires -Version 5.1
# scripts/lib/ps-common.ps1 - shared PowerShell helpers for the repo's plain
# .ps1 scripts (issue #123). Dot-source relative to the consumer:
#
#     . (Join-Path $PSScriptRoot 'lib\ps-common.ps1')
#
# NOT dot-sourced by:
#   - install.ps1 / install.sh: one-liner bootstraps that download themselves
#     and nothing else - no repo on disk to source from.
#   - the run_onchange/run_once .ps1 templates: chezmoi renders them as
#     self-contained scripts (they inline their own copies at render time;
#     tests/ps_modulepath_contract.sh and tests/windows_elevation_contract.sh
#     pin the literal guard/elevation text in those template files).
#
# A helper without a second consumer today is still worth one definition:
# Update-SessionPath has ten copies across the templates and bootstraps, all
# of which are exactly the files that cannot source this lib - this is the
# canonical shape for the next plain script that needs it.

# Cross-generation PSModulePath guard: chezmoi runs .ps1 scripts with Windows
# PowerShell 5.1; when an apply was launched from pwsh 7, the inherited module
# path makes 5.1 resolve Core builds of in-box modules and fail with "module
# could not be loaded" (confirmed live on Set-Acl in generate_identities
# during a fresh Windows install). Strip the Core module dirs under 5.1 so
# in-box modules resolve. Idempotent; safe on pwsh 7 (no-op there).
# (Renamed from Use-InBoxModules: PSUseSingularNouns wants a singular noun.)
function Repair-InBoxModulePath {
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $env:PSModulePath = (($env:PSModulePath -split ';') |
            Where-Object { $_ -and ($_ -notmatch '\\PowerShell\\[67]\\') }) -join ';'
        Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
    }
}

# True when the current session is elevated. Pure .NET - no module autoload,
# safe before Repair-InBoxModulePath.
function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Rebuild this session's PATH from the Machine + User registry state, so a
# freshly-installed tool's shim resolves without a new terminal. Supports
# -WhatIf/-Confirm (PSUseShouldProcessForStateChangingFunctions): the rewrite
# only happens when ShouldProcess confirms.
function Update-SessionPath {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $machineUserPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ($PSCmdlet.ShouldProcess('$env:Path', "rebuild from Machine+User registry state")) {
        $env:Path = $machineUserPath
    }
}

# The desktop-shortcut helpers live in their own file so the installer template can inline
# them too ({{ include }}): `dot up`, migrate-to-winget and dot upgrade all clean up after the
# installers they run.
. (Join-Path $PSScriptRoot 'ps-desktop-shortcuts.ps1')

# --- dot devtmp (#227) -------------------------------------------------------
# Config reads are plain line scans, like Test-DesktopShortcutsDisabled:
# `chezmoi data` would resolve its own config path (docs/invariants.md #5).

# [data.devtmp] path = "C:/dev/tmp" (basic or literal string) -> the string, or
# $null when the table, the key, or a non-empty value is absent.
function Get-DevTmpPath {
    param([string]$ConfigPath = (Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml'))
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    $inTable = $false
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -match '^\s*\[data\.devtmp\]\s*$') { $inTable = $true; continue }
        if ($inTable -and $line -match '^\s*\[') { $inTable = $false }
        if ($inTable -and $line -match '^\s*path\s*=\s*(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')\s*(#.*)?$') {
            $value = if ($Matches[1]) { $Matches[1] -replace '\\\\', '\' } else { $Matches[2] }
            if ($value) { return $value }
            return $null
        }
    }
    return $null
}

# Every entry of every `dirs = [...]` line inside a [[data.accounts]] block
# (the template emits dirs on ONE line). Home-relative as written.
function Get-AccountDir {
    param([string]$ConfigPath = (Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml'))
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return }
    $inAccount = $false
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -match '^\s*\[\[data\.accounts\]\]\s*$') { $inAccount = $true; continue }
        if ($inAccount -and $line -match '^\s*\[') { $inAccount = $false }
        if ($inAccount -and $line -match '^\s*dirs\s*=\s*\[(.*)\]\s*(#.*)?$') {
            foreach ($m in [regex]::Matches($Matches[1], '"((?:[^"\\]|\\.)*)"')) { $m.Groups[1].Value }
        }
    }
}

# Absolute drive path -> canonical `X:\a\b`; anything else -> $null. Pure string
# logic on purpose: [IO.Path]::GetFullPath treats `C:\x` as relative on Linux,
# and tests/devtmp.ps1 must give the same verdict on every runner.
function ConvertTo-DevTmpNormalPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    $p = $Path.Trim().Trim('"') -replace '/', '\'
    if ($p -notmatch '^[A-Za-z]:\\') { return $null }
    $drive = $p.Substring(0, 2).ToUpperInvariant()
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($seg in $p.Substring(2).Split('\')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') { if ($parts.Count -gt 0) { $parts.RemoveAt($parts.Count - 1) }; continue }
        $parts.Add($seg)
    }
    if ($parts.Count -eq 0) { return "$drive\" }
    return "$drive\" + ($parts -join '\')
}

# $Ancestor equals $Path or contains it. Compared on whole segments, so
# C:\Users\u is NOT an ancestor of C:\Users\u-dev (a bare StartsWith says it is).
function Test-DevTmpAncestor {
    param([string]$Ancestor, [string]$Path)
    $a = if ($Ancestor.EndsWith('\')) { $Ancestor } else { $Ancestor + '\' }
    $p = if ($Path.EndsWith('\')) { $Path } else { $Path + '\' }
    return $p.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)
}

# The refusal rules for a Defender-excluded folder: it must be an absolute drive
# path, and must not be a drive root, the user profile or an ancestor of it,
# %TEMP% / %TMP% or an ancestor of either, or an account directory or an ancestor
# of one. Home is checked before TEMP: TEMP normally lives under the profile, so
# C:\Users must report the profile. An unknown profile or temp refuses.
# -AccountDir entries are home-relative (as in chezmoi.toml) or absolute.
function Test-DevTmpPathSafe {
    param(
        [string]$Path,
        [string]$HomeDir,
        [string[]]$TempDir,
        [string[]]$AccountDir = @()
    )
    $norm = ConvertTo-DevTmpNormalPath -Path $Path
    $refuse = {
        param([string]$why)
        [pscustomobject]@{ Safe = $false; Path = $norm; Reason = $why }
    }
    if (-not $norm) { return & $refuse 'must be an absolute drive path such as C:\dev\tmp' }
    # Defender expands wildcards and environment variables inside -ExclusionPath,
    # so `C:\Users\*` is a blanket exclusion no literal check below could see.
    if ($norm -match '[*?%<>|"]') { return & $refuse 'it contains a wildcard or variable character (* ? % < > | ") that Defender expands' }
    if ($norm.Length -eq 3) { return & $refuse 'a drive root would exclude the whole drive' }
    # A rule that cannot be evaluated refuses; it never silently passes.
    $homeNorm = ConvertTo-DevTmpNormalPath -Path $HomeDir
    if (-not $homeNorm) { return & $refuse 'cannot tell where your user profile is, so a blanket exclusion cannot be ruled out' }
    $tempNorms = @($TempDir | ForEach-Object { ConvertTo-DevTmpNormalPath -Path $_ } | Where-Object { $_ })
    if ($tempNorms.Count -eq 0) { return & $refuse 'cannot tell where %TEMP% is, so a blanket exclusion cannot be ruled out' }
    if (Test-DevTmpAncestor -Ancestor $norm -Path $homeNorm) {
        return & $refuse 'it contains your user profile (a blanket exclusion)'
    }
    foreach ($tempNorm in $tempNorms) {
        if (Test-DevTmpAncestor -Ancestor $norm -Path $tempNorm) {
            return & $refuse 'it contains %TEMP% (a blanket exclusion)'
        }
    }
    foreach ($dir in $AccountDir) {
        $full = if ($dir -match '^[A-Za-z]:[\\/]') { $dir } else { "$homeNorm\$dir" }
        $dirNorm = ConvertTo-DevTmpNormalPath -Path $full
        if ($dirNorm -and (Test-DevTmpAncestor -Ancestor $norm -Path $dirNorm)) {
            return & $refuse "it contains the account directory '$dir' (your source checkouts)"
        }
    }
    [pscustomobject]@{ Safe = $true; Path = $norm; Reason = '' }
}

# --- Live agent sessions (dot upgrade) ---------------------------------------------------
# `dot upgrade` defers upgrades that delete and recreate package directories a running
# agent session resolves from. It used to match process NAMES only, so two things that are
# not sessions kept deferring codex and graft: Codex's shared app-server daemon (it runs
# its OWN release copy under ~\.codex\packages\app-server-daemon\, not the npm-global CLI
# the upgrade replaces) and Claude Desktop (an Electron app, ~10 claude.exe processes under
# AnthropicClaude\; it is not Claude Code). A process whose path cannot be read (an
# elevated process seen from a normal shell) still counts: when in doubt, defer.
$script:NonSessionPathPattern = @{
    claude   = @('\\AnthropicClaude\\')
    codex    = @('\\\.codex\\packages\\app-server-daemon\\', '\\WindowsApps\\OpenAI\.(Codex|ChatGPT)')
    opencode = @('\\@opencode-ai?desktop\\', '\\AppData\\Local\\OpenCode\\')
}

# The agent desktop apps (dot upgrade). Their installers cannot replace a running app, and
# Claude Desktop shares claude.exe with Claude Code, so while any claude.exe runs the winget
# sweep holds it - the stop offer used to list only the CLI sessions, and Claude Desktop held
# itself out after the operator said yes (2026-10-07). Matched by install folder - EVERY
# process running from it, so the background helpers go too (Antigravity's
# language_server.exe, the IDE's language_server_windows_x64.exe, the Store app's
# codex-command-runner) - never by name alone: several share a name with a CLI (claude, codex,
# opencode). Service: a Windows service the app installs (stopped with it when running).
$script:AgentDesktopApp = @(
    [pscustomobject]@{ Label = 'Claude Desktop';   Path = '\\AnthropicClaude\\';                              Service = '' }
    [pscustomobject]@{ Label = 'ChatGPT / Codex';  Path = '\\WindowsApps\\OpenAI\.(Codex|ChatGPT)';            Service = 'CodexSandboxService.OpenAI.Codex' }
    [pscustomobject]@{ Label = 'Antigravity';      Path = '\\Programs\\antigravity\\';                         Service = '' }
    [pscustomobject]@{ Label = 'Antigravity IDE';  Path = '\\Programs\\Antigravity IDE\\';                     Service = '' }
    [pscustomobject]@{ Label = 'OpenCode Desktop'; Path = '\\@opencode-ai?desktop\\|\\AppData\\Local\\OpenCode\\'; Service = '' }
)

# One entry per RUNNING desktop app: its label, all its processes, and its service when that
# runs. A process whose path cannot be read is not claimed by any app.
# Paths come from ONE Win32_Process query. Reading $process.Path walks that process's modules,
# and this read it for every process once per app: 8.7 s of a 9.2 s scan in an elevated shell
# (2026-10-08), where those reads succeed instead of failing fast. .Path is the fallback, at
# most once per process, for one the query gave no path for.
function Get-AgentDesktopApp {
    param([int[]]$ExcludeId = @())
    $all = @(Get-Process -ErrorAction SilentlyContinue)
    $tablePath = @{}
    foreach ($row in @(Get-ProcessTable)) { if ($row.Path) { $tablePath[[int]$row.Id] = $row.Path } }
    $paths = @{}
    foreach ($process in $all) {
        $path = $tablePath[[int]$process.Id]
        if (-not $path) { try { $path = $process.Path } catch { $path = $null } }
        $paths[[int]$process.Id] = $path
    }
    foreach ($app in $script:AgentDesktopApp) {
        $procs = @(foreach ($process in $all) {
            $path = $paths[[int]$process.Id]
            if ($path -and $path -match $app.Path -and $ExcludeId -notcontains $process.Id) { $process }
        })
        $service = ''
        if ($app.Service) {
            $svc = Get-Service -Name $app.Service -ErrorAction SilentlyContinue
            if ($svc -and "$($svc.Status)" -eq 'Running') { $service = $app.Service }
        }
        if ($procs.Count -gt 0 -or $service) { [pscustomobject]@{ Label = $app.Label; Processes = $procs; Service = $service } }
    }
}

# --- Background work an ENDED session left running (dot upgrade) -------------------------------
# A Claude Code background task (the shells `/exit` asks about) and the MCP servers an agent
# starts (graft's `npx @nanonets/graft mcp` chain) are children of their session, so stopping
# the session takes them along. When the session ended WITHOUT them - a background task left
# running, an MCP server orphaned - nothing listed them, and a leftover graft MCP server keeps
# graft's files open while npm replaces them. Found by command line; only those with no live
# agent session above them; only the top of each chain (its tree goes with it).
function Get-ProcessTable {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ Id = [int]$_.ProcessId; ParentId = [int]$_.ParentProcessId; Name = [string]$_.Name; Path = [string]$_.ExecutablePath; CommandLine = [string]$_.CommandLine; Created = $_.CreationDate }
    })
}

# --- A process tree, without PID reuse (dot upgrade) --------------------------------------------
# Windows reuses process ids, and a process keeps the id of the parent that started it after
# that parent exits. `taskkill /T` follows those ids: a Windows Terminal started at 01:14 by a
# long-gone launcher listed a Claude Code session started hours later as its "parent", because
# the session had been given the launcher's old id (2026-10-08) - stopping the session would
# have taken the whole terminal, every tab, with it. A child counts only when it started at or
# after its parent. Returned children first, the root last (the order to stop them in).
function Get-ProcessTreeId {
    param([Parameter(Mandatory)][int]$Id, $Table)
    if ($null -eq $Table) { $Table = @(Get-ProcessTable) }
    $byId = @{}
    $byParent = @{}
    foreach ($row in $Table) {
        $byId[[int]$row.Id] = $row
        if ([int]$row.ParentId -eq [int]$row.Id) { continue }
        if (-not $byParent.ContainsKey([int]$row.ParentId)) { $byParent[[int]$row.ParentId] = New-Object System.Collections.Generic.List[object] }
        $byParent[[int]$row.ParentId].Add($row)
    }
    $order = New-Object System.Collections.Generic.List[int]
    $seen = @{}
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($Id)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($seen.ContainsKey($current)) { continue }
        $seen[$current] = $true
        $order.Add($current)
        if (-not $byParent.ContainsKey($current)) { continue }
        $parentCreated = if ($byId.ContainsKey($current)) { $byId[$current].Created } else { $null }
        foreach ($child in $byParent[$current]) {
            # unknown start times prove nothing: such a "child" is left alone
            if ($null -eq $parentCreated -or $null -eq $child.Created) { continue }
            if ($child.Created -lt $parentCreated) { continue }
            $queue.Enqueue([int]$child.Id)
        }
    }
    $result = @($order)
    [array]::Reverse($result)
    return $result
}

function Stop-ProcessTree {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$Id)
    foreach ($treeId in @(Get-ProcessTreeId -Id $Id)) {
        if ($PSCmdlet.ShouldProcess("pid $treeId", 'Stop process')) {
            Stop-Process -Id $treeId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-AgentHelperKind {
    param([string]$CommandLine)
    if ($CommandLine -match '__claudeCodeScript|CLAUDE_CODE_SHELL') { return 'Claude Code background task' }
    if ($CommandLine -match '@nanonets[\\/]graft|(^|[\\/"\s])graft(\.cmd)?"?\s+mcp\b') {
        if ($CommandLine -match '\bmcp\b') { return 'graft MCP server' }
    }
    return ''
}

function Get-OrphanAgentHelper {
    param([int[]]$ExcludeId = @())
    $table = @(Get-ProcessTable)
    $byId = @{}
    foreach ($row in $table) { $byId[$row.Id] = $row }
    $isSession = {
        param($row)
        if ($row.Name -notmatch '^(claude|codex|opencode|agy|serena)(\.exe)?$') { return $false }
        $stem = ($row.Name -replace '\.exe$', '').ToLower()
        if ($row.Path -and $script:NonSessionPathPattern.ContainsKey($stem)) {
            foreach ($pattern in $script:NonSessionPathPattern[$stem]) { if ($row.Path -match $pattern) { return $false } }
        }
        return $true
    }
    foreach ($row in $table) {
        $kind = Get-AgentHelperKind -CommandLine $row.CommandLine
        if (-not $kind -or $ExcludeId -contains $row.Id) { continue }
        # the top of the chain only: its parent is not the same kind of helper
        if ($byId.ContainsKey($row.ParentId) -and (Get-AgentHelperKind -CommandLine $byId[$row.ParentId].CommandLine) -eq $kind) { continue }
        $owned = $false
        $seen = @{}
        $id = $row.ParentId
        while ($id -gt 0 -and $byId.ContainsKey($id) -and -not $seen.ContainsKey($id)) {
            $seen[$id] = $true
            if (& $isSession $byId[$id]) { $owned = $true; break }
            $id = $byId[$id].ParentId
        }
        if (-not $owned) { [pscustomobject]@{ Kind = $kind; Id = $row.Id; CommandLine = $row.CommandLine } }
    }
}

function Get-LiveAgentProcess {
    param([string[]]$Name)
    foreach ($n in $Name) {
        foreach ($process in @(Get-Process $n -ErrorAction SilentlyContinue)) {
            $path = $null
            try { $path = $process.Path } catch { $path = $null }
            if ($path -and $script:NonSessionPathPattern.ContainsKey($n)) {
                $ignored = $false
                foreach ($pattern in $script:NonSessionPathPattern[$n]) {
                    if ($path -match $pattern) { $ignored = $true }
                }
                if ($ignored) { continue }
            }
            $process
        }
    }
}

function Test-LiveProcess {
    param([string[]]$Names)
    return [bool](@(Get-LiveAgentProcess -Name $Names).Count -gt 0)
}

# Codex's shared app-server daemon keeps running the release it started with, so after a
# Codex CLI upgrade it can stay several versions behind until something restarts it. It is
# not a session (see above) and restarts on demand, so `dot upgrade` stops it before
# replacing the CLI. Only the daemon's own processes are matched, never a CLI session.
function Get-CodexDaemonProcess {
    foreach ($process in @(Get-Process codex -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $process.Path } catch { $path = $null }
        if ($path -and $path -match $script:NonSessionPathPattern['codex'][0]) { $process }
    }
}

# Returns the number of daemon processes it stopped (0 when none was running).
function Stop-CodexDaemon {
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$TimeoutSeconds = 20)
    $running = @(Get-CodexDaemonProcess)
    if ($running.Count -eq 0) { return 0 }
    if (-not $PSCmdlet.ShouldProcess('Codex app-server daemon', 'Stop')) { return 0 }
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if ($codex) {
        try {
            $proc = Start-Process -FilePath $codex.Source -ArgumentList 'app-server', 'daemon', 'stop' -WindowStyle Hidden -PassThru -ErrorAction Stop
            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) { $proc.Kill() }
        } catch { Write-Verbose "codex app-server daemon stop failed: $($_.Exception.Message)" }
    }
    # The polite stop did not take (or the CLI is too old to have it): the daemon is safe to end.
    foreach ($left in @(Get-CodexDaemonProcess)) {
        # The tree: the daemon runs helpers (codex-code-mode-host, codex-command-runner,
        # codex-voice-host) that a plain Stop-Process would leave behind.
        Stop-ProcessTree -Id $left.Id
    }
    return $running.Count
}

# --- Offering to stop live sessions (dot upgrade) ----------------------------------------
# Deferring is the safe default, but it leaves the tool un-upgraded until the operator
# closes things by hand and re-runs. On an interactive console `dot upgrade` instead lists
# what is blocking and asks. The invoker's own ancestry (this shell, the terminal, and the
# agent session that launched `dot upgrade`) is never offered: stopping it would end the
# very command that is asking. Those processes still defer their tools.
# One process-table query, walked in memory (a query per ancestor took ~2 s, and dot upgrade
# asks twice); remembered for the run - this shell's ancestry does not change.
function Get-AncestorProcessId {
    if ($script:AncestorIdCache) { return @($script:AncestorIdCache) }
    $parentOf = @{}
    foreach ($row in @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)) {
        $parentOf[[int]$row.ProcessId] = [int]$row.ParentProcessId
    }
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    $id = $PID
    while ($id -gt 0 -and $ids.Add($id)) {
        if (-not $parentOf.ContainsKey($id)) { break }
        $id = $parentOf[$id]
    }
    $script:AncestorIdCache = @($ids)
    return @($ids)
}

function Get-StoppableAgentProcess {
    param([string[]]$Name, [int[]]$ExcludeId = @())
    return @(Get-LiveAgentProcess -Name $Name | Where-Object { $ExcludeId -notcontains $_.Id })
}

function Test-InteractiveConsole {
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected)
}

# What a terminal UI (Claude Code, Codex, OpenCode) switches on and a taskkill never lets it
# switch off again: mouse reporting (1000/1002/1003/1006), focus reports (1004), bracketed paste
# (2004), the kitty keyboard protocol (CSI < u pops it), modifyOtherKeys, the alternate screen
# (1049); then the cursor back. Left on, the terminal keeps sending those reports into the
# prompt and they print as stray characters.
function Get-TerminalResetSequence {
    $e = [string][char]27
    return ($e + '[?1000l' + $e + '[?1002l' + $e + '[?1003l' + $e + '[?1004l' + $e + '[?1006l' + $e + '[?2004l' +
        $e + '[<99u' + $e + '[>4;0m' + $e + '[?1049l' + $e + '[?25h')
}

# Write the switch-offs to the console of a process that is about to be ended. A throwaway child
# does it (a process has one console; this one must keep its own): FreeConsole, AttachConsole,
# write to CONOUT$. Best effort and bounded: no console, no process, a slow start - all fine.
function Reset-AgentTerminal {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$ProcessId)
    if (-not $PSCmdlet.ShouldProcess("console of pid $ProcessId", 'Switch off terminal modes')) { return $false }
    try {
        $sequence = Get-TerminalResetSequence
        $code = @'
param([uint32]$TargetId, [string]$Text)
Add-Type -Namespace DotTerm -Name Native -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteFile(IntPtr handle, byte[] buffer, uint count, out uint written, IntPtr overlapped);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
"@
[void][DotTerm.Native]::FreeConsole()
if (-not [DotTerm.Native]::AttachConsole($TargetId)) { exit 1 }
$h = [DotTerm.Native]::CreateFileW('CONOUT$', 0x40000000, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
if ($h -eq [IntPtr]::new(-1)) { exit 2 }
$bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
$written = [uint32]0
[void][DotTerm.Native]::WriteFile($h, $bytes, [uint32]$bytes.Length, [ref]$written, [IntPtr]::Zero)
[void][DotTerm.Native]::CloseHandle($h)
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("& { $code } -TargetId $ProcessId -Text '$sequence'"))
        $exe = (Get-Process -Id $PID).Path
        $child = Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WindowStyle Hidden -PassThru
        # ~1.6 s when it works; a console that will not attach is not worth more than 3 s.
        if (-not $child.WaitForExit(3000)) { try { $child.Kill() } catch { Write-Verbose "reset helper still running: $($_.Exception.Message)" } }
        return $true
    }
    catch { Write-Verbose "terminal reset failed: $($_.Exception.Message)"; return $false }
}

# Ask the window to close, then take the whole process tree down (Serena leaves language
# server children behind otherwise). Console agents have no window, so they go straight to
# the tree kill - after -ResetTerminal switched off what their UI left on in the terminal.
function Stop-AgentProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Process, [int]$GraceSeconds = 5, [switch]$ResetTerminal)
    if (-not $PSCmdlet.ShouldProcess("$($Process.ProcessName) (pid $($Process.Id))", 'Stop process tree')) { return $false }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $closing = $false
    try { $closing = [bool]$Process.CloseMainWindow() } catch { $closing = $false }
    if ($closing -and $Process.WaitForExit($GraceSeconds * 1000)) { $script:LastStopDetail = ('closed its window in {0:N1}s' -f $watch.Elapsed.TotalSeconds); return $true }
    $windowSeconds = $watch.Elapsed.TotalSeconds
    if ($ResetTerminal) { $null = Reset-AgentTerminal -ProcessId $Process.Id }
    $resetSeconds = $watch.Elapsed.TotalSeconds - $windowSeconds
    Stop-ProcessTree -Id $Process.Id
    $treeSeconds = $watch.Elapsed.TotalSeconds - $windowSeconds - $resetSeconds
    $script:LastStopDetail = ('window {0:N1}s, terminal reset {1:N1}s, process tree {2:N1}s' -f $windowSeconds, $resetSeconds, $treeSeconds)
    return $true
}

function Format-LiveProcess {
    param($Process)
    $started = ''
    try { $started = ", started $($Process.StartTime.ToString('HH:mm'))" } catch { $started = '' }
    return "$($Process.ProcessName) (pid $($Process.Id)$started)"
}

# Returns the processes it stopped. Nothing is stopped unless the operator says so;
# DOTUPGRADE_NO_PROMPT=1 and a non-interactive console both keep today's defer-and-report.
function Invoke-LiveSessionStop {
    param([string[]]$Name, [int[]]$ExcludeId = @())
    if ($env:DOTUPGRADE_NO_PROMPT -eq '1') { return @() }
    # The scan took 9-15 s on every elevated `dot upgrade` (2026-10-07) and 1.2 s unelevated:
    # say which part, once it is slow.
    $scanWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $procs = @(Get-StoppableAgentProcess -Name $Name -ExcludeId $ExcludeId)
    $sessionSeconds = $scanWatch.Elapsed.TotalSeconds
    $apps = @(Get-AgentDesktopApp -ExcludeId $ExcludeId)
    $appSeconds = $scanWatch.Elapsed.TotalSeconds - $sessionSeconds
    $orphans = @(Get-OrphanAgentHelper -ExcludeId $ExcludeId)
    $helperSeconds = $scanWatch.Elapsed.TotalSeconds - $sessionSeconds - $appSeconds
    if ($scanWatch.Elapsed.TotalSeconds -gt 3) {
        Write-Host ("    session scan took {0:N1}s: sessions {1:N1}s, desktop apps {2:N1}s, helpers {3:N1}s" -f $scanWatch.Elapsed.TotalSeconds, $sessionSeconds, $appSeconds, $helperSeconds) -ForegroundColor DarkGray
    }
    if ($procs.Count -eq 0 -and $apps.Count -eq 0 -and $orphans.Count -eq 0) { return @() }
    if (-not (Test-InteractiveConsole)) { return @() }

    # One list: each session, each desktop app as a whole, each helper an ended session left.
    # `opencode serve` / `opencode web` is OpenCode's server, not an interactive session: say so.
    $commandLines = @{}
    if (@($procs | Where-Object { $_.ProcessName -eq 'opencode' }).Count -gt 0) {
        foreach ($row in @(Get-ProcessTable)) { $commandLines[$row.Id] = $row.CommandLine }
    }
    $items = @()
    foreach ($p in $procs) {
        $label = Format-LiveProcess $p
        if ($p.ProcessName -eq 'opencode' -and "$($commandLines[[int]$p.Id])" -match '\s(serve|web)\b') { $label = "OpenCode server (opencode $($Matches[1])) - $label" }
        $items += [pscustomobject]@{ Label = $label; Processes = @($p); Kind = 'session'; Service = '' }
    }
    foreach ($a in $apps) {
        $what = @("$(@($a.Processes).Count) process(es)")
        if ($a.Service) { $what += "service $($a.Service)" }
        $items += [pscustomobject]@{ Label = "$($a.Label) (desktop app, $($what -join ', '))"; Processes = @($a.Processes); Kind = 'desktop'; Service = $a.Service }
    }
    foreach ($o in $orphans) {
        $p = Get-Process -Id $o.Id -ErrorAction SilentlyContinue
        if ($p) { $items += [pscustomobject]@{ Label = "$($o.Kind) left by an ended session (pid $($o.Id))"; Processes = @($p); Kind = 'orphan'; Service = '' } }
    }
    if (@($items | Where-Object { $_.Kind -eq 'session' }).Count -gt 0) {
        Write-Host "  These sessions block part of the upgrade:" -ForegroundColor Yellow
        foreach ($i in @($items | Where-Object { $_.Kind -eq 'session' })) { Write-Host "    $($i.Label)" }
        Write-Host "  Stopping one ends that session; unsaved context is lost unless it can be resumed." -ForegroundColor Yellow
    }
    if (@($items | Where-Object { $_.Kind -eq 'desktop' }).Count -gt 0) {
        Write-Host "  These desktop apps are running - their updates wait until they are closed:" -ForegroundColor Yellow
        foreach ($i in @($items | Where-Object { $_.Kind -eq 'desktop' })) { Write-Host "    $($i.Label)" }
    }
    if (@($items | Where-Object { $_.Kind -eq 'orphan' }).Count -gt 0) {
        Write-Host "  Background work still running after its session ended:" -ForegroundColor Yellow
        foreach ($i in @($items | Where-Object { $_.Kind -eq 'orphan' })) { Write-Host "    $($i.Label)" }
    }
    if ($items.Count -eq 0) { return @() }
    $answer = (Read-DotAnswer "  Stop them so everything upgrades now? [y] all  [s] choose each  [N] keep and defer").Trim().ToLower()

    $chosen = @()
    if ($answer -eq 'y') {
        $chosen = $items
    } elseif ($answer -eq 's') {
        foreach ($i in $items) {
            $each = (Read-DotAnswer "    Stop $($i.Label)? [y/N]").Trim().ToLower()
            if ($each -eq 'y') { $chosen += $i }
        }
    }
    $stopped = @()
    $closedApps = @()
    foreach ($i in $chosen) {
        if ($i.Service) { Stop-Service -Name $i.Service -Force -ErrorAction SilentlyContinue }
        if ($i.Kind -eq 'desktop') {
            # The window first (a clean shutdown), then whatever of the app is left.
            foreach ($p in @($i.Processes | Sort-Object { try { [int]($_.MainWindowHandle -eq [IntPtr]::Zero) } catch { 1 } })) {
                if (Stop-AgentProcess -Process $p) { $stopped += $p }
            }
            $closedApps += ($i.Label -replace ' \(desktop app, .*$', '')
        } else {
            foreach ($p in $i.Processes) {
                # Already gone: a session's child (Serena under Claude Code) dies with its parent's
                # tree, and stopping it again cost a terminal reset and a taskkill.
                $gone = $false
                try { $p.Refresh(); $gone = [bool]$p.HasExited } catch { $gone = $false }
                if ($gone) { $stopped += $p; continue }
                # The terminal switch-offs are for TUI agents; an MCP server (Serena) has none.
                $tui = @('claude', 'codex', 'opencode', 'agy') -contains $p.ProcessName
                $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
                if (Stop-AgentProcess -Process $p -ResetTerminal:$tui) { $stopped += $p }
                # where a slow stop spends its time (it took 12 s on 2026-10-08, cause unknown)
                if ($stopWatch.Elapsed.TotalSeconds -gt 3) {
                    $detail = Get-Variable -Name LastStopDetail -Scope Script -ValueOnly -ErrorAction SilentlyContinue
                    Write-Host ("    stopping {0} (pid {1}) took {2:N1}s: {3}" -f $p.ProcessName, $p.Id, $stopWatch.Elapsed.TotalSeconds, $detail) -ForegroundColor DarkGray
                }
            }
        }
    }
    if ($stopped.Count -gt 0) {
        Write-Host "  Stopped $($stopped.Count) process(es); re-scanning." -ForegroundColor Green
    }
    if ($closedApps.Count -gt 0) {
        Write-Host "  Closed $($closedApps -join ', ') for the upgrade - reopen when dot upgrade is done." -ForegroundColor Green
    }
    return $stopped
}

# --- Codex's platform binary (dot upgrade) --------------------------------------------------
# Codex ships its native binary as an optional dependency per platform
# (<pkg>-win32-x64 -> npm:<pkg>@<version>-win32-x64), published minutes AFTER
# the main package. npm skips a missing optional dependency silently: a `dot upgrade` in that
# gap removed the old binary, installed none, and every codex command died with "Missing
# optional dependency" (2026-10-07) - while the version check said "codex is current".
function Get-NpmPlatformTag {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    return "win32-$arch"
}

# $false only when <Package>@<Version> names a binary package for this platform that the
# registry does not have yet. Unknown counts as published - the install goes ahead.
function Test-NpmPlatformPublished {
    param([Parameter(Mandatory)][string]$Package, [Parameter(Mandatory)][string]$Version)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $tag = Get-NpmPlatformTag
        $json = (& npm view "$Package@$Version" optionalDependencies --json 2>$null | Out-String).Trim()
        if (-not $json) { return $true }
        $deps = $null
        try { $deps = $json | ConvertFrom-Json } catch { return $true }
        $prop = $deps.PSObject.Properties | Where-Object { $_.Name -eq "$Package-$tag" } | Select-Object -First 1
        if (-not $prop) { return $true }
        $spec = [string]$prop.Value
        $spec = if ($spec -like 'npm:*') { $spec.Substring(4) } else { "$Package-$tag@$spec" }
        $found = (& npm view $spec version 2>$null | Out-String).Trim()
        return [bool]$found
    }
    finally { $ErrorActionPreference = $previous }
}

function Test-CodexWork {
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { return $false }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & codex --version *> $null; return ($LASTEXITCODE -eq 0) }
    catch { return $false }
    finally { $ErrorActionPreference = $previous }
}

# Current AND runnable -> nothing; the latest's binary for this platform not published yet ->
# keep what is installed; otherwise install, then make sure it starts.
function Update-CodexNpm {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Package)
    if ((Test-CodexWork) -and (Test-NpmGlobalCurrent $Package)) {
        Write-Host "  codex is current ($script:NpmCurrentVersion)"
        return
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $want = (& npm view $Package version 2>$null | Out-String).Trim()
    $ErrorActionPreference = $previous
    $tag = Get-NpmPlatformTag
    if ($want -and -not (Test-NpmPlatformPublished -Package $Package -Version $want)) {
        if (Test-CodexWork) {
            Write-Host "  codex $want is out, but its $tag binary is not published yet - keeping the installed one (the next dot upgrade takes it)" -ForegroundColor Yellow
        } else {
            Write-Host "  codex cannot start (its platform binary is missing) and $want's $tag binary is not published yet - re-run dot upgrade in a few minutes" -ForegroundColor Red
        }
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Package, 'npm install -g')) { return }
    $ErrorActionPreference = 'Continue'
    & npm install -g "$($Package)@latest" --loglevel=error --no-progress --fetch-timeout=120000 --fetch-retries=2 2>$null
    $ErrorActionPreference = $previous
    if (-not (Test-CodexWork)) {
        Write-Host "  codex was installed but cannot start (npm skipped its platform binary) - re-run dot upgrade in a few minutes" -ForegroundColor Red
    }
}

# --- "Is it already current?" (dot upgrade) ----------------------------------------------
# `graft upgrade` ran every time (0.21.1 -> 0.21.1 took 41 s on WSL) and the codex
# `npm install -g` another ~9 s. Ask first; anything unknown (empty answers, an unreachable
# registry) means "not current", so the install still happens exactly as before.
$script:NpmCurrentVersion = ''

# True when the globally installed <Package> is already the registry's latest. On True,
# $script:NpmCurrentVersion holds the version.
function Test-NpmGlobalCurrent {
    param([Parameter(Mandatory)][string]$Package)

    $script:NpmCurrentVersion = ''
    $previous = $ErrorActionPreference
    # PS 5.1 promotes native stderr to a terminating error under Stop; the answer is the signal.
    $ErrorActionPreference = 'Continue'
    try {
        $have = ''
        $listing = ((npm ls -g $Package --depth=0 --json 2>$null) | Out-String).Trim()
        if ($listing) {
            $parsed = $listing | ConvertFrom-Json
            $deps = $parsed.PSObject.Properties['dependencies']
            if ($null -ne $deps -and $null -ne $deps.Value -and $null -ne $deps.Value.PSObject.Properties[$Package]) {
                $have = "$($deps.Value.PSObject.Properties[$Package].Value.version)"
            }
        }
        $want = ((npm view $Package version 2>$null) | Out-String).Trim()
        if ($have -and $have -eq $want) {
            $script:NpmCurrentVersion = $have
            return $true
        }
        return $false
    }
    catch { return $false }
    finally { $ErrorActionPreference = $previous }
}

# `graft version` prints "graft <installed>" and "latest: <published>" (or "latest:
# unreachable (offline?)"). Returns the version when both agree, else ''.
function Get-GraftCurrentVersion {
    param([string]$VersionOutput)

    $installed = ''
    $latest = ''
    if ($VersionOutput -match '(?m)^graft (\d[^\s]*)') { $installed = $Matches[1] }
    # Online: "latest on npm: 0.21.1 <check> up to date"; offline: "latest: unreachable (offline?)".
    if ($VersionOutput -match '(?m)^latest(?: on npm)?: (\d[^\s]*)') { $latest = $Matches[1] }
    if ($installed -and $installed -eq $latest) { return $installed }
    return ''
}

# graft's own `graft upgrade` dies on Windows with "spawnSync npm ENOENT" (npm is npm.cmd
# there and the upgrade spawns it without a shell). It only wraps `npm install -g`, so run
# that directly. npm 12 skips install scripts unless allow-listed, so the installer's
# allow-list (agents.yaml) goes into NPM_CONFIG_ALLOW_SCRIPTS for the call only. Returns
# npm's exit code.
function Invoke-GraftNpmInstall {
    param([Parameter(Mandatory)][string]$AllowScripts)

    $previousAllow = $env:NPM_CONFIG_ALLOW_SCRIPTS
    $previousPreference = $ErrorActionPreference
    # PS 5.1 promotes native stderr to a terminating error under Stop; the exit code is the signal.
    $ErrorActionPreference = 'Continue'
    try {
        $env:NPM_CONFIG_ALLOW_SCRIPTS = $AllowScripts
        # Captured, never emitted: PowerShell returns EVERYTHING a function writes, so npm's
        # "changed 44 packages" used to come back as part of the result (("changed ...", 0))
        # and the caller printed "graft install failed (npm exit changed 44 packages in 1m 0)".
        # Its output is shown only when the install actually failed.
        $npmOutput = @(npm install -g '@nanonets/graft@latest' --loglevel=error --no-progress 2>&1)
        $exitCode = [int]$LASTEXITCODE
        if ($exitCode -ne 0) { foreach ($line in $npmOutput) { Write-Host "    $line" } }
        return $exitCode
    }
    finally {
        $ErrorActionPreference = $previousPreference
        if ($null -eq $previousAllow) { Remove-Item Env:NPM_CONFIG_ALLOW_SCRIPTS -ErrorAction SilentlyContinue }
        else { $env:NPM_CONFIG_ALLOW_SCRIPTS = $previousAllow }
    }
}

# The `choco upgrade all` argument list. Chocolatey's `claude` package (Claude Desktop) ends
# its installer with `taskkill /F /IM claude.exe /T`, which kills EVERY claude.exe - and
# Claude Code's CLI has the same image name, so a live Claude Code session dies with it
# (seen in the dot upgrade log: "Terminating Claude process..."). While any claude.exe is
# running that one package is left out of the sweep; the next quiet dot upgrade takes it.
# Only a package Chocolatey actually has is excluded (its lib\<name> folder): once Claude
# Desktop or Docker Desktop moved to winget, the --except made Chocolatey warn "Some packages
# specified in the 'except' list were not found" on every run.
function Get-ChocoUpgradeArgument {
    param([switch]$KeepDockerDesktop, [string]$ChocoLib)
    if (-not $ChocoLib) { $ChocoLib = Join-Path $(if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { 'C:\ProgramData\chocolatey' }) 'lib' }
    $chocoArguments = @('upgrade', 'all', '-y', '--no-progress')
    $except = @()
    if ((Test-Path -LiteralPath (Join-Path $ChocoLib 'claude')) -and @(Get-Process claude -ErrorAction SilentlyContinue).Count -gt 0) { $except += 'claude' }
    # Docker Desktop's installer cannot replace a running app: when the operator kept it running,
    # leave its package out instead of letting the installer fail or hang.
    if ($KeepDockerDesktop -and (Test-Path -LiteralPath (Join-Path $ChocoLib 'docker-desktop'))) { $except += 'docker-desktop' }
    if ($except.Count -gt 0) { $chocoArguments += ('--except=' + ($except -join ',')) }
    return $chocoArguments
}

# --- choco, summarised --------------------------------------------------------------------
# `choco upgrade all` printed ~100 lines of "<package> vX is the latest version available"
# on every run, burying the two or three packages that changed. --limit-output prints one
# machine-readable line per package (name|installed|available|pinned): those are collected
# instead of echoed, everything a package's own installer says still streams live (a hung
# or prompting installer stays visible), the FULL output goes to the log, and the sweep
# ends with a summary. A non-zero exit prints the tail so the failing package is on screen.
function Invoke-ChocoUpgradeAll {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$LogPath)

    if (-not $LogPath) { $LogPath = Join-Path $HOME '.local\state\dotfiles\upgrade.log' }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
        # keep one previous generation instead of growing without bound
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 2MB) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
        }
        Add-Content -LiteralPath $LogPath -Value ("=== {0} choco {1}" -f (Get-Date -Format s), ($Arguments -join ' '))
    }
    catch { $LogPath = $null; Write-Verbose "upgrade log unavailable: $($_.Exception.Message)" }

    $packageLines = New-Object System.Collections.Generic.List[string]
    $footerLines = New-Object System.Collections.Generic.List[string]
    $allLines = New-Object System.Collections.Generic.List[string]
    & choco @Arguments --limit-output 2>&1 | ForEach-Object {
        $line = "$_"
        $allLines.Add($line)
        if ($LogPath) { Add-Content -LiteralPath $LogPath -Value $line }
        if ($line -match '^[^|\s][^|]*\|[^|]*\|[^|]*\|[^|]*$') { $packageLines.Add($line) } else { Write-Host $line }
        if ($line -match '^\s+-\s+\S+\s+v\S+\s*$') { $footerLines.Add($line) }
    }
    $code = [int]$LASTEXITCODE

    $summary = Get-ChocoUpgradeSummary -Lines $packageLines -FooterLines $footerLines
    if ($summary.Upgraded.Count -gt 0) {
        Write-Host ("  Upgraded {0} of {1}: {2}" -f $summary.Upgraded.Count, $summary.Checked, ($summary.Upgraded -join ', ')) -ForegroundColor Green
    }
    elseif ($summary.Checked -gt 0) {
        Write-Host ("  Nothing to upgrade ({0} packages checked)" -f $summary.Checked)
    }
    # 1641 / 3010: success, a restart is needed
    if ($code -eq 1641 -or $code -eq 3010) {
        Write-Host "  A restart is needed to finish one of the upgrades." -ForegroundColor Yellow
    }
    elseif ($code -ne 0) {
        Write-Host "  Warning: choco exited $code - the last lines of its output:" -ForegroundColor Red
        $allLines | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" }
    }
    if ($LogPath) { Write-Host "  (full output: $LogPath)" -ForegroundColor DarkGray }
    return $code
}

# name|installed|available|pinned lines -> how many were checked and which changed.
function Get-ChocoUpgradeSummary {
    # -FooterLines: choco's own closing "Upgraded:" list (` - name vX`). A package pulled in as
    # a DEPENDENCY (cmake.install with cmake) is upgraded without a `name|old|new|pinned` line,
    # so the pipe lines alone undercounted ("4 of 99" while choco said 5/100).
    param([string[]]$Lines, [string[]]$FooterLines = @())

    $upgraded = @()
    $names = @()
    $checked = 0
    foreach ($line in @($Lines)) {
        $parts = $line -split '\|'
        if ($parts.Count -lt 3) { continue }
        $checked++
        if ($parts[1] -and $parts[2] -and $parts[1] -ne $parts[2]) {
            $upgraded += ("{0} ({1} -> {2})" -f $parts[0], $parts[1], $parts[2])
            $names += $parts[0]
        }
    }
    foreach ($line in @($FooterLines)) {
        if ($line -match '^\s+-\s+(?<name>\S+)\s+v(?<version>\S+)\s*$' -and $names -notcontains $Matches['name']) {
            $upgraded += ("{0} (-> {1})" -f $Matches['name'], $Matches['version'])
            $names += $Matches['name']
        }
    }
    if ($checked -lt $upgraded.Count) { $checked = $upgraded.Count }
    return [pscustomobject]@{ Checked = $checked; Upgraded = @($upgraded) }
}

# --- winget sweep (dot upgrade) ----------------------------------------------------------------
# winget prints a human table, not machine output. A row ends with `Id  Version  Available
# Source`, but the Name column is padded to its LONGEST entry, so the longest name sits only one
# space from the Id: columns cannot be split on runs of spaces. Rows are recognised from the
# right instead (a version and an available version, each with a digit, then a source of
# winget or msstore); the header, the dashed rule, the "N upgrades available." footer and any
# prose never end that way and are skipped.
function ConvertFrom-WingetUpgradeTable {
    param([string[]]$Lines)
    $rows = @()
    foreach ($line in @($Lines)) {
        if ("$line" -match '^(?<name>\S.*?)\s+(?<id>\S+)\s+(?<version>[^\s]*\d[^\s]*)\s+(?<available>[^\s]*\d[^\s]*)\s+(?<source>winget|msstore)\s*$') {
            $rows += [pscustomobject]@{
                Name = $Matches['name']; Id = $Matches['id']; Version = $Matches['version']
                Available = $Matches['available']; Source = $Matches['source']
            }
        }
    }
    return @($rows)
}

# What winget still lists as upgradable, plus its "N package(s) have upgrades blocked" note
# (those packages are not named anywhere in winget's output).
function Get-WingetPendingUpgrade {
    # SweepBlocked: winget's "N package(s) have upgrades blocked" line from the `upgrade --all`
    # sweep. Only the sweep prints it; the plain listing below never does (seen live 2026-10-06,
    # which is why keying on the listing found nothing).
    param([string]$SweepBlocked = '')
    $lines = @()
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& winget upgrade --include-unknown --accept-source-agreements 2>&1 | ForEach-Object { "$_" })
    }
    catch { $lines = @() }
    finally { $ErrorActionPreference = $previous }
    $blocked = $SweepBlocked
    foreach ($line in $lines) { if ($line -match '\d+ package\(s\) have upgrades blocked') { $blocked = $line.Trim() } }
    $rows = @(ConvertFrom-WingetUpgradeTable -Lines $lines)
    # winget lists a package it cannot upgrade ("a newer version was found, but the install
    # technology is different": Docker Desktop installed by choco, Edge) as if it could. When it
    # says some are blocked, ask about each by id: those are not "pending", they belong to
    # whoever installed them.
    $other = @()
    if ($blocked -and $rows.Count -gt 0 -and $rows.Count -le 8) {
        $upgradeable = @()
        foreach ($row in $rows) {
            $probe = ''
            try {
                $ErrorActionPreference = 'Continue'
                $probe = (@(& winget upgrade --id $row.Id --accept-source-agreements 2>&1 | ForEach-Object { "$_" }) -join ' ')
            }
            catch { $probe = '' }
            finally { $ErrorActionPreference = $previous }
            if ($probe -match 'install technology is different') { $other += $row } else { $upgradeable += $row }
        }
        $rows = $upgradeable
        if ($other.Count -gt 0) { $blocked = '' }
    }
    return [pscustomobject]@{ Rows = @($rows); Other = @($other); Blocked = $blocked }
}

# The sweep: output streams (minus spinner and progress-bar noise) and is kept whole in the
# upgrade log; the end says what upgraded and, from a second listing, what is STILL pending.
# Before this the raw table was shown and a package that silently did not upgrade (Docker
# Desktop, running) was invisible.
# -HoldId: packages the sweep must leave alone this run (Docker Desktop kept running: its
# installer cannot replace a running app). `upgrade --all` has no --except, so each is pinned
# for the sweep and unpinned afterwards - only pins this run added, never one the operator had
# (twin of the apt-mark hold in scripts/lib/docker-vscode.sh).
function Invoke-WingetUpgradeAll {
    param([string]$LogPath, [string]$RunningNote = '', [string[]]$HoldId = @())

    if (-not $LogPath) { $LogPath = Join-Path $HOME '.local\state\dotfiles\upgrade.log' }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 2MB) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
        }
        Add-Content -LiteralPath $LogPath -Value ("=== {0} winget upgrade --all" -f (Get-Date -Format s))
    }
    catch { $LogPath = $null; Write-Verbose "upgrade log unavailable: $($_.Exception.Message)" }

    $installed = 0
    $allLines = New-Object System.Collections.Generic.List[string]
    $previous = $ErrorActionPreference
    $pinned = @()
    if (@($HoldId).Count -gt 0) {
        $ErrorActionPreference = 'Continue'
        $pinList = (& winget pin list --accept-source-agreements 2>$null | Out-String)
        foreach ($id in $HoldId) {
            if ($pinList -match [regex]::Escape($id)) { continue }
            & winget pin add --id $id --exact --accept-source-agreements *> $null
            if ($LASTEXITCODE -eq 0) { $pinned += $id }
        }
        $ErrorActionPreference = $previous
    }
    try {
        $ErrorActionPreference = 'Continue'
        & winget upgrade --all --include-unknown --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object {
            $line = "$_"
            $allLines.Add($line)
            if ($LogPath) { Add-Content -LiteralPath $LogPath -Value $line }
            if ($line -match 'Successfully installed') { $installed++ }
            # spinner frames, blank lines and download bars carry no information
            if ($line -match '^\s*[-\\|/]?\s*$' -or $line -match '[\u2588\u2592]' -or $line -match '^\s*[\d.]+\s*[KMG]B\s*/\s*[\d.]+\s*[KMG]B') { return }
            # the blocked note is explained (or repeated) by the summary below
            if ($line -match '\d+ package\(s\) have upgrades blocked') { return }
            # winget's wording for "nothing to upgrade"; the summary below says it plainly
            if ($line -match '^\s*No installed package found matching input criteria') { return }
            Write-Host $line
        }
        $code = [int]$LASTEXITCODE
    }
    catch { $code = 1; Write-Host "  Warning: winget upgrade failed - continuing" -ForegroundColor Red }
    finally {
        foreach ($id in $pinned) { & winget pin remove --id $id --exact *> $null }
        $ErrorActionPreference = $previous
    }
    $sweepBlocked = ''
    foreach ($line in $allLines) { if ($line -match '\d+ package\(s\) have upgrades blocked') { $sweepBlocked = $line.Trim() } }

    if ($installed -gt 0) { Write-Host ("  winget upgraded {0} package(s)." -f $installed) -ForegroundColor Green }
    $pending = Get-WingetPendingUpgrade -SweepBlocked $sweepBlocked
    if (@($pending.Rows).Count -gt 0) {
        $names = @($pending.Rows | ForEach-Object { "{0} ({1} -> {2})" -f $_.Name, $_.Version, $_.Available })
        Write-Host ("  Still pending in winget: {0}" -f ($names -join ', ')) -ForegroundColor Yellow
        if ($RunningNote) { Write-Host "  $RunningNote" -ForegroundColor Yellow }
    }
    elseif ($installed -eq 0 -and @($pending.Other).Count -eq 0) {
        Write-Host "  Nothing to upgrade in winget."
    }
    if (@($pending.Other).Count -gt 0) {
        $others = @($pending.Other | ForEach-Object { "{0} ({1} -> {2})" -f $_.Name, $_.Version, $_.Available })
        Write-Host ("  Not upgradeable through winget (installed another way; choco or the app itself updates it): {0}" -f ($others -join ', ')) -ForegroundColor Yellow
    }
    if ($pending.Blocked) { Write-Host "  $($pending.Blocked)" -ForegroundColor Yellow }
    if ($code -ne 0 -and $installed -eq 0 -and @($pending.Rows).Count -eq 0) {
        Write-Host "  Warning: winget exited $code (store apps can require interactive agreement) - continuing" -ForegroundColor Red
    }
    if ($LogPath) { Write-Host "  (full output: $LogPath)" -ForegroundColor DarkGray }
    return $code
}

# --- Docker Desktop ------------------------------------------------------------------------------
# Its installer (choco `docker-desktop` or winget `Docker.DockerDesktop`) cannot replace a
# running app, so an upgrade silently did nothing while Docker Desktop was up. `dot upgrade`
# now offers to stop it first, the same way it offers to stop live agent sessions.
function Get-DockerDesktopProcess {
    return @(Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)
}

# '' when nothing is pending, else the available version. winget is asked first (it tends to
# carry the newer build), then choco; any probe that fails counts as "nothing pending".
# -Owner (from Get-DockerDesktopOwner) skips the manager that does not own it: each probe costs
# 5-10 s and only the owner can upgrade it.
function Get-DockerDesktopUpgrade {
    param([string]$Owner = '')
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($Owner -ne 'choco') {
            $wingetLines = @(& winget upgrade --id Docker.DockerDesktop --accept-source-agreements 2>&1 | ForEach-Object { "$_" })
            $row = @(ConvertFrom-WingetUpgradeTable -Lines $wingetLines | Where-Object { $_.Id -eq 'Docker.DockerDesktop' }) | Select-Object -First 1
            if ($row) { return [string]$row.Available }
            if ($Owner -eq 'winget') { return '' }
        }
        # choco installed it: winget answers "install technology is different" instead of a table
        # and can never upgrade it, so only choco's own list counts.
        foreach ($line in @(& choco outdated --limit-output 2>&1 | ForEach-Object { "$_" })) {
            $parts = $line -split '\|'
            if ($parts.Count -ge 3 -and $parts[0] -eq 'docker-desktop' -and $parts[2]) { return [string]$parts[2] }
        }
    }
    catch { Write-Verbose "docker desktop upgrade probe failed: $($_.Exception.Message)" }
    finally { $ErrorActionPreference = $previous }
    return ''
}

# Graceful first (`docker desktop stop` also stops the engine and the backend), then the
# remaining Docker Desktop processes. True when none is left.
function Stop-DockerDesktop {
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$TimeoutSeconds = 90)
    if (-not $PSCmdlet.ShouldProcess('Docker Desktop', 'Stop')) { return $false }
    try { & docker desktop stop 2>&1 | Out-Null } catch { Write-Verbose "docker desktop stop failed: $($_.Exception.Message)" }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (@(Get-DockerDesktopProcess).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    foreach ($left in @(Get-DockerDesktopProcess)) { $null = Stop-AgentProcess -Process $left }
    return (@(Get-DockerDesktopProcess).Count -eq 0)
}

# VS Code (Code.exe, or Code - Insiders) is closed BEFORE Docker Desktop is stopped. A window
# attached to a dev container loses it the moment Docker stops; closing the window first lets
# VS Code save its state (hot exit) and end the session cleanly instead of dropping the
# connection under an open editor. Only as part of the Docker stop: nothing else in
# `dot upgrade` needs VS Code closed.
function Get-VsCodeProcess {
    return @(Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue)
}

# Ask every window to close, wait (VS Code can take several seconds with many windows), then
# end whatever is left. True when no process of the given set remains.
function Stop-VsCode {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object[]]$Process, [int]$GraceSeconds = 20)
    if (-not $PSCmdlet.ShouldProcess('VS Code', 'Close')) { return $false }
    $ids = @($Process | ForEach-Object { $_.Id })
    foreach ($p in $Process) {
        try { $null = $p.CloseMainWindow() } catch { Write-Verbose "close request failed: $($_.Exception.Message)" }
    }
    $deadline = (Get-Date).AddSeconds($GraceSeconds)
    while (@(Get-Process -Id $ids -ErrorAction SilentlyContinue).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    foreach ($left in @(Get-Process -Id $ids -ErrorAction SilentlyContinue)) { $null = Stop-AgentProcess -Process $left -GraceSeconds 1 }
    return (@(Get-Process -Id $ids -ErrorAction SilentlyContinue).Count -eq 0)
}

# True when Docker Desktop is not running (so its upgrade can proceed); False when it is still
# up. Nothing is stopped unless the operator says so; DOTUPGRADE_NO_PROMPT=1 and a
# non-interactive console keep "leave it running and say so". When the operator accepts and
# VS Code is running, VS Code is closed first (see above); a VS Code that hosts THIS terminal
# (its integrated terminal runs dot upgrade) is never closed, like the agent sessions in the
# invoker's ancestry: that would end this very command. -ExcludeId carries those pids.
function Invoke-DockerDesktopStopOffer {
    param([Parameter(Mandatory)][string]$Version, [int[]]$ExcludeId = @(), [int]$VsCodeGraceSeconds = 20)
    if (@(Get-DockerDesktopProcess).Count -eq 0) { return $true }
    if ($env:DOTUPGRADE_NO_PROMPT -eq '1' -or -not (Test-InteractiveConsole)) {
        Write-Host "  Docker Desktop $Version is available but Docker Desktop is running (its installer cannot replace a running app): left for the next run." -ForegroundColor Yellow
        return $false
    }
    $vsAll = @(Get-VsCodeProcess)
    $vsClosable = @($vsAll | Where-Object { $ExcludeId -notcontains $_.Id })
    $vsHostsThisTerminal = ($vsAll.Count -gt $vsClosable.Count)
    Write-Host "  Docker Desktop $Version is available, but Docker Desktop is running and its installer cannot replace a running app." -ForegroundColor Yellow
    Write-Host "  Stopping it stops every running container; they are not restarted afterwards." -ForegroundColor Yellow
    if ($vsClosable.Count -gt 0) {
        Write-Host "  VS Code is running ($($vsClosable.Count) process(es)) and may be attached to a container: it will be closed first, so nothing disconnects under an open editor." -ForegroundColor Yellow
    }
    if ($vsHostsThisTerminal) {
        Write-Host "  VS Code also hosts THIS terminal, so it is not closed: any of its windows attached to a container will disconnect when Docker stops. Run dot upgrade from another terminal to avoid that." -ForegroundColor Yellow
    }
    $answer = (Read-DotAnswer "  Stop Docker Desktop so it can upgrade now? [y/N]").Trim().ToLower()
    if ($answer -ne 'y') {
        Write-Host "  Docker Desktop left running; its upgrade waits for the next run." -ForegroundColor Yellow
        return $false
    }
    if ($vsClosable.Count -gt 0) {
        if (Stop-VsCode -Process $vsClosable -GraceSeconds $VsCodeGraceSeconds) {
            Write-Host "  VS Code closed; reopen it when you need it (a dev container reconnects once Docker is up)." -ForegroundColor Green
        } else {
            Write-Host "  Warning: VS Code did not close - continuing; windows attached to a container will disconnect." -ForegroundColor Red
        }
    }
    if (Stop-DockerDesktop) {
        Write-Host "  Docker Desktop stopped for the upgrade; start it again when you need it." -ForegroundColor Green
        return $true
    }
    Write-Host "  Warning: Docker Desktop did not stop - its upgrade is left for the next run." -ForegroundColor Red
    return $false
}

# --- Docker Desktop: who owns it ------------------------------------------------------------------
# Chocolatey's docker-desktop package installs Docker's MSI; winget's Docker.DockerDesktop is
# Docker's EXE installer. To Windows those are two install technologies, so `winget upgrade`
# refuses a Chocolatey copy ("install technology is different"), and Chocolatey's package lags
# Docker's releases (4.93.0 while 4.94.0 was out, 2026-10-06). Docker Desktop is winget's now;
# a machine that still has the Chocolatey copy is told how to move it (docs/windows.md).

# 'choco', 'winget' or '' (not installed). winget lists every installed app, Chocolatey's
# MSI copy included, so Chocolatey is asked first.
# Chocolatey's ownership from its lib\docker-desktop folder (instant), not `choco list`
# (~1.9 s of a 3.2 s probe, on every dot upgrade).
function Get-DockerDesktopOwner {
    param([string]$ChocoLib)
    if (-not $ChocoLib) { $ChocoLib = Join-Path $(if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { 'C:\ProgramData\chocolatey' }) 'lib' }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if (Test-Path -LiteralPath (Join-Path $ChocoLib 'docker-desktop')) { return 'choco' }
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            $wingetList = (winget list --id Docker.DockerDesktop --exact --accept-source-agreements 2>$null | Out-String)
            if ($wingetList -match 'Docker\.DockerDesktop') { return 'winget' }
        }
    }
    catch { Write-Verbose "docker desktop owner probe failed: $($_.Exception.Message)" }
    finally { $ErrorActionPreference = $previous }
    return ''
}

# --- Chocolatey -> winget (scripts/migrate-to-winget.ps1) ----------------------------------------
# winget is the primary Windows manager; a catalog record that moved carries `winget:` plus
# `choco_was:` (its old Chocolatey name). An app Chocolatey installed cannot be adopted by winget
# ("install technology is different"), so moving it is uninstall + install - per app, asked.

# Tools dropped outright (no winget replacement installed): name -> why.
$script:WingetMigrationDrops = [ordered]@{
    'winmerge'                = 'replaced by Meld'
    'notepadplusplus.install' = 'replaced by Geany'
    'notepadplusplus'         = 'replaced by Geany'
    'winscp.install'          = 'replaced by Termius'
    'winscp'                  = 'replaced by Termius'
    'chocolateygui'           = 'Chocolatey is the secondary manager now'
    'cutepdf'                 = 'replaced by Microsoft Print to PDF (built into Windows)'
    'Ghostscript.app'         = 'came with CutePDF'
    'autohotkey.portable'     = "Ghostscript's installer helper"
    'wsl2'                    = 'record only: WSL stays installed; wsl --update keeps it current'
}
# versions.node_major, set by migrate-to-winget.ps1: the Node pin it leaves after moving Node.
$script:WingetMigrationNodeMajor = 0
# Dropped with --skip-autouninstaller: Chocolatey forgets the package, the software stays.
$script:WingetMigrationRecordOnly = @('wsl2')

# The plan, from catalog lines "choco_was|winget|id|winget_args|migrate_risk" and the installed
# Chocolatey ids. Moves (with a risk note when the catalog has one) first, drops after.
function Get-WingetMigrationPlan {
    # DependedOn: Chocolatey package -> the installed Chocolatey packages that depend on it (from
    # their .nuspec files). Chocolatey refuses to uninstall a dependency (opencode needs fzf,
    # ripgrep and unzip), so one whose dependent stays on Chocolatey is kept, with the reason.
    param([string[]]$CatalogLine, [string[]]$Installed, [hashtable]$DependedOn = @{})
    $have = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $Installed) { if ($i) { [void]$have.Add($i) } }
    $leaving = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $CatalogLine) { if ($line) { $c = ($line -split '\|', 2)[0]; [void]$leaving.Add(($c -replace '\.install$', '')); [void]$leaving.Add(($c -replace '\.install$', '') + '.install') } }
    foreach ($name in $script:WingetMigrationDrops.Keys) { [void]$leaving.Add($name) }
    $plan = @()
    foreach ($line in $CatalogLine) {
        if (-not $line) { continue }
        $f = $line -split '\|', 5
        if ($f.Count -lt 3 -or -not $have.Contains($f[0])) { continue }
        $staying = @()
        $after = @()
        foreach ($k in $DependedOn.Keys) {
            if ($k -ieq $f[0]) {
                $staying = @($DependedOn[$k] | Where-Object { $have.Contains($_) -and -not $leaving.Contains($_) })
                # Dependents that are moving too: Chocolatey refuses to remove this one while they
                # are installed, so it goes after them (opencode before its fzf and ripgrep).
                $after = @($DependedOn[$k] | Where-Object { $have.Contains($_) -and $leaving.Contains($_) })
            }
        }
        if ($staying.Count -gt 0) {
            $plan += [pscustomobject]@{
                Action = 'keep'; Choco = $f[0]; Winget = $f[1]; Id = $f[2]; Args = ''
                Risk = "Chocolatey's $($staying -join ', ') depends on it"; Companion = ''; After = @()
            }
            continue
        }
        $plan += [pscustomobject]@{
            Action = 'move'; Choco = $f[0]; Winget = $f[1]; Id = $f[2]
            Args = $(if ($f.Count -ge 4) { $f[3] } else { '' })
            Risk = $(if ($f.Count -ge 5) { $f[4] } else { '' })
            # the other half of a meta/.install pair: git.install's meta `git`, cmake's `cmake.install`
            Companion = $(if ($f[0] -match '\.install$') { $meta = $f[0] -replace '\.install$', ''; if ($have.Contains($meta)) { $meta } else { '' } }
                          elseif ($have.Contains("$($f[0]).install")) { "$($f[0]).install" } else { '' })
            After = @($after | Where-Object { $_ -ine "$($f[0]).install" -and $_ -ine ($f[0] -replace '\.install$', '') })
        }
    }
    # A Chocolatey package that only LEAVING packages depend on (unzip under opencode): nothing
    # needs it once they are gone. Offered for removal after them; a catalog tool never is.
    $catalogChoco = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $CatalogLine) { if ($line) { [void]$catalogChoco.Add(($line -split '\|', 2)[0]) } }
    foreach ($dep in @($DependedOn.Keys)) {
        if (-not $have.Contains($dep) -or $leaving.Contains($dep) -or $catalogChoco.Contains($dep)) { continue }
        $users = @($DependedOn[$dep] | Where-Object { $have.Contains($_) })
        if ($users.Count -eq 0 -or @($users | Where-Object { -not $leaving.Contains($_) }).Count -gt 0) { continue }
        $plan += [pscustomobject]@{
            Action = 'orphan'; Choco = $dep; Winget = ''; Id = $dep; Args = ''
            Risk = "only $($users -join ', ') used it"; Companion = ''; After = @($users)
        }
    }
    foreach ($name in $script:WingetMigrationDrops.Keys) {
        if (-not $have.Contains($name)) { continue }
        $plan += [pscustomobject]@{
            Action = 'drop'; Choco = $name; Winget = ''; Id = $name; Args = ''
            Risk = $script:WingetMigrationDrops[$name]; Companion = ''; After = @()
        }
    }
    return $plan
}

# One item. Moves: choco uninstall (and its .install companion), then winget install; on a failed
# install the way back is printed. Drops: choco uninstall (record-only ones keep the software).
# Returns 'ok', 'failed' or 'skipped'.
function Invoke-WingetMigrationItem {
    param([Parameter(Mandatory)]$Item)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Item.Action -eq 'move' -and $Item.Winget -eq 'Microsoft.PowerShell' -and $PSVersionTable.PSEdition -eq 'Core') {
            Write-Host "  - $($Item.Choco): skipped - PowerShell 7 cannot replace itself; run this from Windows PowerShell (powershell.exe) to move it" -ForegroundColor Yellow
            return 'skipped'
        }
        if ($Item.Action -eq 'keep') {
            Write-Host "  - $($Item.Choco): kept on Chocolatey ($($Item.Risk))" -ForegroundColor Yellow
            return 'skipped'
        }
        # A meta package and its .install go in ONE call: alone, the meta package asks whether to
        # remove its dependency and waits 20 s for an answer that never comes.
        # The meta package goes first, so its dependency is no longer depended on.
        $chocoArgs = @('uninstall') + @(@($Item.Companion, $Item.Choco) | Where-Object { $_ } | Sort-Object { $_ -match '\.install$' })
        $chocoArgs += @('-y', '--no-progress')
        if ($script:WingetMigrationRecordOnly -contains $Item.Choco) { $chocoArgs += '--skip-autouninstaller' }
        & choco @chocoArgs *> $null
        $chocoExit = [int]$LASTEXITCODE
        if (@(0, 1605, 1614, 1641, 3010) -notcontains $chocoExit) {
            # The exit code is not the truth: neovim's beforeModify script warned, choco exited 1,
            # and the package WAS gone - so the winget install was skipped and neovim was lost
            # (2026-10-06). Ask Chocolatey whether it is still there.
            $still = (& choco list --limit-output --exact $Item.Choco 2>$null | Out-String)
            if ($still -match "(?im)^$([regex]::Escape($Item.Choco))\|") {
                Write-Host "  - $($Item.Choco): choco uninstall failed (exit $chocoExit) - left as it is" -ForegroundColor Red
                return 'failed'
            }
        }
        if ($Item.Action -eq 'drop' -or $Item.Action -eq 'orphan') {
            Write-Host "  - $($Item.Choco): removed ($($Item.Risk))" -ForegroundColor Green
            return 'ok'
        }
        # winget may already have its own copy (installed next to Chocolatey's): nothing to install.
        $already = (& winget list --id $Item.Winget --exact --accept-source-agreements --disable-interactivity 2>$null | Out-String)
        if ($already -match [regex]::Escape($Item.Winget)) {
            Write-Host "  - $($Item.Choco): removed; winget's $($Item.Winget) was already installed" -ForegroundColor Green
            return 'ok'
        }
        $extra = @("$($Item.Args)" -split ' ' | Where-Object { $_ })
        & winget install --id $Item.Winget --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity @extra *> $null
        $wingetExit = [int]$LASTEXITCODE
        if ($wingetExit -ne 0) {
            Write-Host "  - $($Item.Choco): winget install $($Item.Winget) failed (exit $wingetExit) - it is NOT installed now; put it back with: choco install $($Item.Choco) -y" -ForegroundColor Red
            return 'failed'
        }
        Write-Host "  - $($Item.Choco) -> winget $($Item.Winget)" -ForegroundColor Green
        if ($Item.Winget -eq 'OpenJS.NodeJS.LTS') {
            # A different Node major breaks native modules of the global npm tools (graft's
            # tree-sitter parsers): rebuild them for the Node now installed.
            $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
            # Not `npm rebuild -g`: it re-links every global command and fails with EEXIST on shims
            # an older npm wrote (2026-10-07, on npm's own shim). graft is the one global tool with
            # native modules (tree-sitter); reinstalling it compiles them for this Node - the path
            # dot upgrade already takes.
            & npm ls -g --depth=0 '@nanonets/graft' *> $null
            if ($LASTEXITCODE -eq 0) {
                $graftAllow = ''
                try { $graftAllow = ('{{ join "," .agents.npm.graft_allow_scripts }}' | chezmoi execute-template | Out-String).Trim() } catch { $graftAllow = '' }
                if (-not $graftAllow) {
                    Write-Host "    graft's native modules were not rebuilt (no allow-list from chezmoi data) - run dot upgrade" -ForegroundColor Yellow
                } elseif ((Invoke-GraftNpmInstall -AllowScripts $graftAllow) -ne 0) {
                    Write-Host "    graft reinstall failed - run dot upgrade to retry" -ForegroundColor Yellow
                } else {
                    Write-Host "    graft reinstalled: its native modules are built for the new Node"
                }
            }
            if ($script:WingetMigrationNodeMajor -gt 0) { $null = Set-NodeLtsPin -Major $script:WingetMigrationNodeMajor }
        }
        return 'ok'
    }
    finally { $ErrorActionPreference = $previous }
}

# --- Node.js: the same major everywhere ------------------------------------------------------------
# Linux/WSL (NodeSource's node_<major>.x repo) and macOS (node@<major>) stay on versions.node_major;
# winget's OpenJS.NodeJS.LTS follows whatever is LTS today. A gating pin "<major>.*" holds it on the
# same major, so bumping node_major moves every platform together. Returns $true when the pin is
# in place (already was, or set now). A pin for another major is replaced.
function Set-NodeLtsPin {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$Major)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }
    if (-not $PSCmdlet.ShouldProcess("OpenJS.NodeJS.LTS", "Pin to $Major.*")) { return $false }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $pins = (& winget pin list --id OpenJS.NodeJS.LTS --exact --accept-source-agreements 2>$null | Out-String)
        if ($pins -match "OpenJS\.NodeJS\.LTS\s.*\b$Major\.\*") { return $true }
        if ($pins -match 'OpenJS\.NodeJS\.LTS\s') { & winget pin remove --id OpenJS.NodeJS.LTS --exact *> $null }
        & winget pin add --id OpenJS.NodeJS.LTS --exact --version "$Major.*" --accept-source-agreements *> $null
        return ($LASTEXITCODE -eq 0)
    }
    finally { $ErrorActionPreference = $previous }
}

# --- Docker Desktop: compacting its data disk (`dot docker-compact`) -------------------------------
# docker_data.vhdx grows with every image and build layer and never shrinks on its own: removing
# images frees space inside it, not on the drive. Compacting needs Docker Desktop stopped and WSL
# shut down (the disk is attached to Docker's WSL distro). Optimize-VHD (Hyper-V PowerShell
# module) is tried first; where it is missing or fails (Windows Home, or no Hyper-V service to
# back it) diskpart's `compact vdisk` does the same job.

function Get-DockerDataDiskPath {
    param([string]$LocalAppData = $env:LOCALAPPDATA)
    return (Join-Path $LocalAppData 'Docker\wsl\disk\docker_data.vhdx')
}

# Each compactor returns $true on success. Separate functions so tests can replace them.
function Invoke-OptimizeVhdCompact {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Get-Command Optimize-VHD -ErrorAction SilentlyContinue)) { return $false }
    try { Optimize-VHD -Path $Path -Mode Full -ErrorAction Stop; return $true }
    catch { Write-Host "  Optimize-VHD failed ($($_.Exception.Message)) - trying diskpart." -ForegroundColor Yellow; return $false }
}

function Invoke-DiskpartCompact {
    param([Parameter(Mandatory)][string]$Path)
    $script = [IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $script -Encoding ASCII -Value @(
            "select vdisk file=`"$Path`"", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk')
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = (& diskpart /s $script 2>&1 | Out-String)
        $code = [int]$LASTEXITCODE
        $ErrorActionPreference = $previous
        if ($code -ne 0) { Write-Host "  diskpart failed (exit $code):" -ForegroundColor Red; Write-Host $out; return $false }
        return $true
    }
    finally { Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue }
}

# The whole run. True when the disk was compacted. Nothing is stopped unless the operator says y
# (or -Yes); a VS Code hosting this terminal is never closed (-ExcludeId).
function Invoke-DockerDiskCompact {
    param([string]$Path = (Get-DockerDataDiskPath), [int[]]$ExcludeId = @(), [switch]$Yes)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "  No Docker data disk at $Path - nothing to compact." -ForegroundColor Yellow
        return $false
    }
    $before = (Get-Item -LiteralPath $Path).Length
    Write-Host ("  Docker data disk: {0:N1} GB ({1})" -f ($before / 1GB), $Path)
    Write-Host "  Compacting stops Docker Desktop (every running container) and shuts WSL down (every WSL" -ForegroundColor Yellow
    Write-Host "  terminal). VS Code is closed first. Nothing is restarted afterwards." -ForegroundColor Yellow
    if (-not $Yes) {
        $answer = (Read-DotAnswer "  Compact it now? [y/N]").Trim().ToLower()
        if ($answer -ne 'y') { Write-Host "  Left as it is."; return $false }
    }
    $vs = @(Get-VsCodeProcess | Where-Object { $ExcludeId -notcontains $_.Id })
    if ($vs.Count -gt 0) { $null = Stop-VsCode -Process $vs }
    if (@(Get-DockerDesktopProcess).Count -gt 0 -and -not (Stop-DockerDesktop)) {
        Write-Host "  Docker Desktop did not stop - nothing was compacted." -ForegroundColor Red
        return $false
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & wsl --shutdown *> $null
    $ErrorActionPreference = $previous

    $ok = Invoke-OptimizeVhdCompact -Path $Path
    if (-not $ok) { $ok = Invoke-DiskpartCompact -Path $Path }
    if (-not $ok) { Write-Host "  The disk was not compacted." -ForegroundColor Red; return $false }
    $after = (Get-Item -LiteralPath $Path).Length
    Write-Host ("  Compacted: {0:N1} GB -> {1:N1} GB (freed {2:N1} GB). Start Docker Desktop when you need it." -f ($before / 1GB), ($after / 1GB), (($before - $after) / 1GB)) -ForegroundColor Green
    return $true
}

# --- where the time of a `dot upgrade` goes -----------------------------------------------------
# A Windows `dot upgrade` took 13m03s and nothing said which part. The scripts put a mark at the
# start of each section; the end of the run prints the slowest ones and appends the same line to
# ~\.local\state\dotfiles\upgrade.log, so one run can be compared with the next. Twin of
# scripts/lib/timing.sh.
#   Add-DotTimingMark -Name <n>      the previous section ends now, <n> starts now
#   Write-DotTimingSummary -Title t  close the open section, print "Timings (t, total): ..."
# Only sections of $env:DOT_TIMING_MIN_SECONDS (default 5) or more are listed, slowest first, at
# most six; the total always is.
$script:DotTimingNames = New-Object System.Collections.Generic.List[string]
$script:DotTimingSeconds = New-Object System.Collections.Generic.List[double]
$script:DotTimingLast = ''
$script:DotTimingFrom = [DateTime]::MinValue
$script:DotTimingStart = [DateTime]::MinValue

function Get-DotTimingNow { return [DateTime]::UtcNow }

# Read-Host for dot upgrade's prompts: the time spent answering is its own section ("your
# answers") in the closing Timings line, not part of the work it interrupted. Twin of
# dot_timing_wait / dot_timing_resume. Outside a timed run it is plain Read-Host.
# A question nobody is there to answer must not hold the run: a dot upgrade sat 26 minutes on
# "Stop them so everything upgrades now?" while its operator was out (2026-10-07). Under
# `dot upgrade --yes` ($script:DotAnswerYes, set by dotupgrade.ps1, which dot-sources this
# file into its own scope) the answer is "y" without asking. Otherwise, after
# DOTUPGRADE_PROMPT_TIMEOUT seconds (default 60; 0 = wait as long as it takes), the empty
# answer: every question's safe default (keep, defer). The wait polls the console for a first
# key; a host without one (redirected input, tests) gets the plain Read-Host.
function Get-DotAnswerTimeout {
    $t = 60
    if ("$env:DOTUPGRADE_PROMPT_TIMEOUT" -match '^\d+$') { $t = [int]$env:DOTUPGRADE_PROMPT_TIMEOUT }
    return $t
}

function Read-DotAnswer {
    param([string]$Prompt)
    if ((Get-Variable -Name DotAnswerYes -Scope Script -ValueOnly -ErrorAction SilentlyContinue) -eq $true) {
        Write-Host "${Prompt}: y (--yes)"
        return 'y'
    }
    $timeout = Get-DotAnswerTimeout
    $resume = $script:DotTimingLast
    if ($resume) { Add-DotTimingMark -Name 'your answers' }
    try {
        if ($timeout -gt 0) {
            $polled = $false
            try {
                $null = [Console]::KeyAvailable
                $polled = $true
            } catch { $polled = $false }
            if ($polled) {
                Write-Host "$Prompt (${timeout}s): " -NoNewline
                $deadline = (Get-Date).AddSeconds($timeout)
                while (-not [Console]::KeyAvailable -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
                if (-not [Console]::KeyAvailable) {
                    Write-Host ''
                    Write-Host "  (no answer in ${timeout}s - taking the default: no)" -ForegroundColor Yellow
                    return ''
                }
                return [Console]::ReadLine()
            }
        }
        return (Read-Host $Prompt)
    }
    finally { if ($resume) { Add-DotTimingMark -Name $resume } }
}

function Add-DotTimingMark {
    param([Parameter(Mandatory)][string]$Name)
    $now = Get-DotTimingNow
    if ($script:DotTimingStart -eq [DateTime]::MinValue) { $script:DotTimingStart = $now }
    if ($script:DotTimingLast) {
        $script:DotTimingNames.Add($script:DotTimingLast)
        $script:DotTimingSeconds.Add(($now - $script:DotTimingFrom).TotalSeconds)
    }
    $script:DotTimingLast = $Name
    $script:DotTimingFrom = $now
}

# 125 -> 2m05s, 45 -> 45s
function Format-DotDuration {
    param([Parameter(Mandatory)][double]$Seconds)
    $whole = [int][math]::Floor($Seconds)
    if ($whole -ge 60) { return ('{0}m{1:00}s' -f [math]::Floor($whole / 60), ($whole % 60)) }
    return ('{0}s' -f $whole)
}

function Write-DotTimingSummary {
    param([string]$Title = 'run', [string]$LogPath)
    $now = Get-DotTimingNow
    if ($script:DotTimingLast) {
        $script:DotTimingNames.Add($script:DotTimingLast)
        $script:DotTimingSeconds.Add(($now - $script:DotTimingFrom).TotalSeconds)
        $script:DotTimingLast = ''
    }
    if ($script:DotTimingNames.Count -eq 0) { return }
    $min = 5
    if ($env:DOT_TIMING_MIN_SECONDS -and $null -ne ($env:DOT_TIMING_MIN_SECONDS -as [int])) { $min = [int]$env:DOT_TIMING_MIN_SECONDS }
    # a section can recur (work resumes after "your answers"): its parts add up
    $sums = [ordered]@{}
    for ($i = 0; $i -lt $script:DotTimingNames.Count; $i++) {
        $name = $script:DotTimingNames[$i]
        if ($sums.Contains($name)) { $sums[$name] += $script:DotTimingSeconds[$i] } else { $sums[$name] = $script:DotTimingSeconds[$i] }
    }
    $rows = @()
    foreach ($name in $sums.Keys) {
        if ($sums[$name] -ge $min) { $rows += [pscustomobject]@{ Name = $name; Seconds = $sums[$name] } }
    }
    $top = @($rows | Sort-Object -Property Seconds -Descending | Select-Object -First 6 |
        ForEach-Object { '{0} {1}' -f $_.Name, (Format-DotDuration -Seconds $_.Seconds) })
    $total = Format-DotDuration -Seconds ($now - $script:DotTimingStart).TotalSeconds
    $text = "Timings ($Title, $total)"
    if ($top.Count -gt 0) { $text += ': ' + ($top -join ', ') }
    Write-Host "  $text"
    if (-not $LogPath) { $LogPath = Join-Path $HOME '.local\state\dotfiles\upgrade.log' }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
        Add-Content -LiteralPath $LogPath -Value ("=== {0} {1}" -f (Get-Date -Format s), $text)
    }
    catch { Write-Verbose "timing log unavailable: $($_.Exception.Message)" }
    $script:DotTimingNames.Clear()
    $script:DotTimingSeconds.Clear()
    $script:DotTimingStart = [DateTime]::MinValue
}
