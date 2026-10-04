#Requires -Version 5.1
<#
Behavioral test for the Windows backup/restore entry points - the PowerShell
twin of tests/dotbackup_restore.sh's round-trip core, which CI only runs on
Linux. Runs BOTH scripts under powershell.exe (5.1), the documented host
(docs/backup-restore.md), with a stub 7z that stages the payload next to the
fake archive - so [IO.Path]::GetRelativePath / -Encoding utf8NoBOM class
regressions fail here before a real machine ever sees them.

The stub is compiled from C# with the .NET Framework's in-box csc.exe rather
than shimmed through a script host: pwsh -File re-parses argv and splits
7z-style flags like "-oC:\stage" at the colon, so only a real .exe gives the
scripts the exact argument stream real 7-Zip would.

Backup -> restore round-trip in a temp $env:USERPROFILE; then a second
restore into the populated home must be refused (no-overwrite contract).
#>
$ErrorActionPreference = 'Stop'

$isWin = ($env:OS -eq 'Windows_NT')
if (-not $isWin) {
    Write-Host 'SKIP: dotbackup_restore.ps1 is Windows-only (powershell.exe 5.1 host)'
    exit 0
}

$powerShell5 = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powerShell5)) {
    Write-Host 'SKIP: Windows PowerShell 5.1 host not found'
    exit 0
}
$csc = @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
    Write-Host 'SKIP: in-box csc.exe not found (cannot compile the stub 7z)'
    exit 0
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Backup = Join-Path $RepoRoot 'scripts/dotbackup.ps1'
$Restore = Join-Path $RepoRoot 'scripts/dotrestore.ps1'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Fail([string]$m) {
    Write-Host "FAIL: $m" -ForegroundColor Red
    exit 1
}

foreach ($f in @($Backup, $Restore)) {
    if (-not (Test-Path -LiteralPath $f)) { Fail "missing script: $f" }
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("dotbackup-rt-" + [IO.Path]::GetRandomFileName())
$bin = Join-Path $Tmp 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null

# --- Stub 7z, same contract as the bash twin's fake in tests/dotbackup_restore.sh.
# 'a' stages the payload ROOT next to the archive as <archive>.contents
# (cp -R "$root" semantics); 'x' copies those contents into -o<dir>, handing
# back the dotfiles-backup-v1 layout the restore script validates. The
# passphrase must never appear in argv beyond the bare flag.
$stubCs = Join-Path $bin 'stub7z.cs'
$stubCode = @'
using System;
using System.IO;

class Stub7z
{
    static int Main(string[] args)
    {
        string log = Environment.GetEnvironmentVariable("FAKE_7Z_LOG");
        if (log != null)
        {
            File.AppendAllText(log, string.Join(" ", args) + Environment.NewLine);
        }
        foreach (string a in args)
        {
            if (a.StartsWith("-p") && a != "-p")
            {
                Console.Error.WriteLine("passphrase must not be in argv");
                return 64;
            }
        }
        if (args.Length < 1)
        {
            return 68;
        }
        string command = args[0];
        if (command == "a")
        {
            string archive = null;
            string root = null;
            for (int i = 1; i < args.Length; i++)
            {
                if (args[i].StartsWith("-"))
                {
                    continue;
                }
                if (archive == null) { archive = args[i]; }
                else if (root == null) { root = args[i]; }
            }
            if (archive == null || root == null)
            {
                return 65;
            }
            File.WriteAllText(archive, "");
            string contents = archive + ".contents";
            Directory.CreateDirectory(contents);
            // cp -R "$root" semantics: the payload ROOT lands INSIDE
            // <archive>.contents, so 'x' hands back the dotfiles-backup-v1
            // layout the restore script's root-entry check requires.
            CopyTree(new DirectoryInfo(root), Path.Combine(contents, new DirectoryInfo(root).Name));
            return 0;
        }
        if (command == "x")
        {
            string output = null;
            for (int i = 1; i < args.Length; i++)
            {
                if (args[i].StartsWith("-o"))
                {
                    output = args[i].Substring(2);
                }
            }
            if (output == null || args.Length < 2)
            {
                return 67;
            }
            string contents = args[args.Length - 1] + ".contents";
            if (!Directory.Exists(contents))
            {
                return 67;
            }
            CopyTree(new DirectoryInfo(contents), output);
            return 0;
        }
        return 68;
    }

    static void CopyTree(DirectoryInfo src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (FileInfo f in src.GetFiles())
        {
            f.CopyTo(Path.Combine(dst, f.Name), true);
        }
        foreach (DirectoryInfo d in src.GetDirectories())
        {
            CopyTree(d, Path.Combine(dst, d.Name));
        }
    }
}
'@
[IO.File]::WriteAllText($stubCs, $stubCode, $Utf8NoBom)
$stubExe = Join-Path $bin '7z.exe'
& $csc -nologo -out:$stubExe $stubCs
if ($LASTEXITCODE -ne 0) { Fail "stub 7z compile failed" }
# Get-SevenZip probes '7zz' first - cover both names so a real 7-Zip
# installation anywhere on PATH loses either way (the stub dir is prepended).
Copy-Item -LiteralPath $stubExe -Destination (Join-Path $bin '7zz.exe') -Force

# --- Fixture home: allowlisted payload with a nested key dir.
$homeSource = Join-Path $Tmp 'home-source'
foreach ($d in @(
    (Join-Path $homeSource '.config\chezmoi'),
    (Join-Path $homeSource '.ssh\nested'))) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Set-Content -LiteralPath (Join-Path $homeSource '.config\chezmoi\chezmoi.toml') -Value 'source = "fixture"' -Encoding utf8
Set-Content -LiteralPath (Join-Path $homeSource '.ssh\custom_signing_key') -Value 'private key' -Encoding ascii
Set-Content -LiteralPath (Join-Path $homeSource '.ssh\custom_signing_key.pub') -Value 'public key' -Encoding ascii
Set-Content -LiteralPath (Join-Path $homeSource '.ssh\nested\deep_key') -Value 'nested private key' -Encoding ascii

# Guardrail operator state in all three Windows roots, in passkey mode, plus
# state that must never be captured. APPDATA/LOCALAPPDATA are pointed into the
# temp home below: left alone, the scripts would read and collide with the real
# operator's guardrail files.
foreach ($d in @(
    (Join-Path $homeSource 'AppData\Roaming\guardrail'),
    (Join-Path $homeSource 'AppData\Local\guardrail'),
    (Join-Path $homeSource '.local\state\guardrail\operator-auth\nested'),
    (Join-Path $homeSource '.local\state\guardrail\manifests'))) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Set-Content -LiteralPath (Join-Path $homeSource 'AppData\Roaming\guardrail\waivers.toml') -Value 'approval = "passkey"' -Encoding ascii
Set-Content -LiteralPath (Join-Path $homeSource 'AppData\Roaming\guardrail\night.toml') -Value 'night = true' -Encoding ascii
Set-Content -LiteralPath (Join-Path $homeSource 'AppData\Local\guardrail\audit-2026.jsonl') -Value '{"event":1}' -Encoding ascii
Set-Content -LiteralPath (Join-Path $homeSource '.local\state\guardrail\operator-auth\nested\key') -Value 'credential' -Encoding ascii
Set-Content -LiteralPath (Join-Path $homeSource '.local\state\guardrail\manifests\claude.json') -Value 'regenerated' -Encoding ascii

$Log = Join-Path $Tmp '7z.log'
[IO.File]::WriteAllText($Log, '', $Utf8NoBom)
$env:HOME = $homeSource
$env:USERPROFILE = $homeSource
$env:APPDATA = Join-Path $homeSource 'AppData\Roaming'
$env:LOCALAPPDATA = Join-Path $homeSource 'AppData\Local'
$env:PATH = "$bin;$env:PATH"
$env:FAKE_7Z_LOG = $Log
Remove-Item Env:XDG_STATE_HOME -ErrorAction SilentlyContinue   # hermetic: only scenario [10] sets it

# --- [1] Backup: timestamped archive, bare -p, header encryption, full payload.
$backupOut = & $powerShell5 -NoProfile -ExecutionPolicy Bypass -File $Backup 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "[1] backup failed under 5.1: $backupOut" }
$backups = @(Get-ChildItem -LiteralPath (Join-Path $homeSource '.dot_backups') -Filter 'dotfiles-*.7z' -File)
if ($backups.Count -ne 1) { Fail "[1] expected exactly one archive, got $($backups.Count): $backupOut" }
$archive = $backups[0].FullName
$logText = [IO.File]::ReadAllText($Log)
foreach ($flag in @('-t7z', '-mhe=on')) {
    if (-not $logText.Contains($flag)) { Fail "[1] stub never saw $flag : $logText" }
}
if ($logText -notmatch '(^|\s)-p(\s|$)') { Fail "[1] bare -p flag missing from stub argv: $logText" }
if ($logText -match '(^|\s)-p\S') { Fail "[1] passphrase material leaked into argv: $logText" }

$payload = Join-Path "$archive.contents" 'dotfiles-backup-v1'
foreach ($rel in @('manifest.json', 'chezmoi\chezmoi.toml', 'ssh\custom_signing_key', 'ssh\nested\deep_key')) {
    if (-not (Test-Path -LiteralPath (Join-Path $payload $rel))) { Fail "[1] payload missing $rel" }
}
$manifestHead = [IO.File]::ReadAllBytes((Join-Path $payload 'manifest.json')) | Select-Object -First 3
if ($manifestHead.Count -ge 3 -and $manifestHead[0] -eq 0xEF) {
    Fail '[1] manifest was written with a BOM (5.1-safe no-BOM write regressed)'
}
foreach ($rel in @('guardrail\config\waivers.toml', 'guardrail\config\night.toml', 'guardrail\operator-auth\nested\key')) {
    if (-not (Test-Path -LiteralPath (Join-Path $payload $rel))) { Fail "[1] guardrail payload missing $rel" }
}
if (Test-Path -LiteralPath (Join-Path $payload 'guardrail\audit')) { Fail '[1] audit log captured without DOTBACKUP_AUDIT=1' }
if (@(Get-ChildItem -LiteralPath $payload -Recurse -Force -Filter 'claude.json').Count -ne 0) { Fail '[1] regenerated manifests/ was captured' }
Write-Host '  ok: 5.1 backup creates the encrypted v1 archive, no-BOM manifest, full payload'

# --- [2] Restore into an empty home round-trips every staged file.
$homeRestore = Join-Path $Tmp 'home-restore'
New-Item -ItemType Directory -Force -Path $homeRestore | Out-Null
$env:HOME = $homeRestore
$env:USERPROFILE = $homeRestore
$env:APPDATA = Join-Path $homeRestore 'AppData\Roaming'
$env:LOCALAPPDATA = Join-Path $homeRestore 'AppData\Local'
$restoreOut = & $powerShell5 -NoProfile -ExecutionPolicy Bypass -File $Restore -Archive $archive 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "[2] restore failed under 5.1: $restoreOut" }
foreach ($rel in @('.config\chezmoi\chezmoi.toml', '.ssh\custom_signing_key', '.ssh\custom_signing_key.pub', '.ssh\nested\deep_key')) {
    $srcContent = [IO.File]::ReadAllText((Join-Path $homeSource $rel))
    $dstPath = Join-Path $homeRestore $rel
    if (-not (Test-Path -LiteralPath $dstPath)) { Fail "[2] restore did not produce $rel : $restoreOut" }
    if ([IO.File]::ReadAllText($dstPath) -ne $srcContent) { Fail "[2] content mismatch for $rel" }
}
foreach ($rel in @('AppData\Roaming\guardrail\waivers.toml', 'AppData\Roaming\guardrail\night.toml', '.local\state\guardrail\operator-auth\nested\key')) {
    $dstPath = Join-Path $homeRestore $rel
    if (-not (Test-Path -LiteralPath $dstPath)) { Fail "[2] restore did not produce guardrail file $rel : $restoreOut" }
    if ([IO.File]::ReadAllText($dstPath) -ne [IO.File]::ReadAllText((Join-Path $homeSource $rel))) { Fail "[2] content mismatch for $rel" }
}
$aclText = (& icacls (Join-Path $homeRestore 'AppData\Roaming\guardrail\waivers.toml') | Out-String)
if ($aclText -match 'Everyone|BUILTIN\\Users|Authenticated Users') { Fail "[2] waivers.toml ACL is not user-only: $aclText" }
if ($restoreOut -notmatch 'guardrail operator file') { Fail "[2] guardrail restore not reported: $restoreOut" }
Write-Host '  ok: backup -> restore round-trip preserves the payload and guardrail state (user-only ACL)'

# --- [3] A second restore into the populated home must be refused.
# Drop EAP to Continue around the call: 5.1 promotes stderr lines of a native
# command to a terminating NativeCommandError under EAP=Stop, and this child
# DELIBERATELY writes its refusal to stderr. The exit code is the real signal
# (same class as the git pull block in install.ps1).
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $secondOut = & $powerShell5 -NoProfile -ExecutionPolicy Bypass -File $Restore -Archive $archive 2>&1 | Out-String
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($LASTEXITCODE -eq 0) { Fail '[3] second restore into a populated home succeeded' }
if ($secondOut -notmatch 'Refusing to overwrite') { Fail "[3] refusal not reported: $secondOut" }
Write-Host '  ok: restore refuses to overwrite an existing payload'


# ===== Parity with tests/dotbackup_restore.sh [9]-[19] ============================
# One helper runs a script under 5.1 with EAP=Continue (stderr from a child that
# deliberately fails must not become a NativeCommandError) and returns output + exit.
function Invoke-Script51 {
    param([string]$Script, [string[]]$ScriptArgs = @())
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $powerShell5 -NoProfile -ExecutionPolicy Bypass -File $Script @ScriptArgs 2>&1 | Out-String
        return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
    }
    finally { $ErrorActionPreference = $prev }
}

function Use-Home([string]$Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $env:HOME = $Dir
    $env:USERPROFILE = $Dir
    $env:APPDATA = Join-Path $Dir 'AppData\Roaming'
    $env:LOCALAPPDATA = Join-Path $Dir 'AppData\Local'
    Remove-Item Env:XDG_STATE_HOME -ErrorAction SilentlyContinue
}

# A backup-able home: allowlisted payload plus guardrail state in the given approval mode.
function Build-GuardrailHome([string]$Dir, [string]$Mode, [switch]$NoGuardrail) {
    foreach ($d in @((Join-Path $Dir '.config\chezmoi'), (Join-Path $Dir '.ssh\nested'))) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $Dir '.config\chezmoi\chezmoi.toml') -Value 'source = "fixture"' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Dir '.ssh\custom_signing_key') -Value 'private key' -Encoding ascii
    if ($NoGuardrail) { return }
    foreach ($d in @(
        (Join-Path $Dir 'AppData\Roaming\guardrail'),
        (Join-Path $Dir 'AppData\Local\guardrail'),
        (Join-Path $Dir '.local\state\guardrail\operator-auth\nested'),
        (Join-Path $Dir '.local\state\guardrail\manifests'))) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $Dir 'AppData\Roaming\guardrail\waivers.toml') -Value "approval = `"$Mode`"" -Encoding ascii
    Set-Content -LiteralPath (Join-Path $Dir 'AppData\Roaming\guardrail\night.toml') -Value 'night = true' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $Dir 'AppData\Local\guardrail\audit-2026.jsonl') -Value '{"event":1}' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $Dir '.local\state\guardrail\operator-auth\nested\key') -Value 'credential' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $Dir '.local\state\guardrail\manifests\claude.json') -Value 'regenerated' -Encoding ascii
}

function Get-OnlyArchive([string]$Dir) {
    $found = @(Get-ChildItem -LiteralPath (Join-Path $Dir '.dot_backups') -Filter 'dotfiles-*.7z' -File)
    if ($found.Count -ne 1) { Fail "expected exactly one archive in $Dir, got $($found.Count)" }
    return $found[0].FullName
}

# Copy an archive's staged payload into a new archive, optionally rewriting the manifest
# platform and adding extra files (relative path -> content) under guardrail\.
function Copy-ArchiveWith([string]$Source, [string]$Dest, [string]$Platform, [hashtable]$Extra = @{}) {
    New-Item -ItemType Directory -Force -Path "$Dest.contents" | Out-Null
    Copy-Item -LiteralPath (Join-Path "$Source.contents" 'dotfiles-backup-v1') -Destination "$Dest.contents" -Recurse -Force
    [IO.File]::WriteAllText($Dest, '')
    $payloadCopy = Join-Path "$Dest.contents" 'dotfiles-backup-v1'
    if ($Platform) {
        $m = Join-Path $payloadCopy 'manifest.json'
        $text = [IO.File]::ReadAllText($m) -replace '"source_platform"\s*:\s*"[A-Za-z]*"', "`"source_platform`": `"$Platform`""
        [IO.File]::WriteAllText($m, $text, $Utf8NoBom)
    }
    foreach ($k in $Extra.Keys) {
        $p = Join-Path (Join-Path $payloadCopy 'guardrail') $k
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
        [IO.File]::WriteAllText($p, [string]$Extra[$k], $Utf8NoBom)
    }
}

# --- [4] Prompt mode (the default) does not use the passkey, so it is not captured.
$promptHome = Join-Path $Tmp 'home-prompt'
Build-GuardrailHome $promptHome 'prompt'
Use-Home $promptHome
$r = Invoke-Script51 $Backup
if ($r.Code -ne 0) { Fail "[4] backup failed: $($r.Out)" }
$promptArchive = Get-OnlyArchive $promptHome
$promptPayload = Join-Path "$promptArchive.contents" 'dotfiles-backup-v1'
if (-not (Test-Path -LiteralPath (Join-Path $promptPayload 'guardrail\config\waivers.toml'))) { Fail '[4] waivers.toml not captured in prompt mode' }
if (Test-Path -LiteralPath (Join-Path $promptPayload 'guardrail\operator-auth')) { Fail '[4] passkey enrollment captured outside passkey mode' }
if ($r.Out -match 'Audit log') { Fail "[4] audit size reported without DOTBACKUP_AUDIT=1: $($r.Out)" }
Write-Host '  ok: passkey enrollment captured only in passkey mode'

# --- [5] DOTBACKUP_AUDIT=1 captures the audit log and says how big it is; per-machine
# state added since the section was designed is never captured, not even then.
$auditHome = Join-Path $Tmp 'home-audit'
Build-GuardrailHome $auditHome 'passkey'
foreach ($d in @((Join-Path $auditHome '.local\state\guardrail\session-checks'), (Join-Path $auditHome '.local\bin'))) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Set-Content -LiteralPath (Join-Path $auditHome '.local\state\guardrail\session-checks\repo.json') -Value 'fingerprint' -Encoding ascii
Set-Content -LiteralPath (Join-Path $auditHome '.local\state\guardrail\previous.json') -Value '{"sha256":"x"}' -Encoding ascii
Set-Content -LiteralPath (Join-Path $auditHome '.local\bin\guardrail.previous.exe') -Value 'binary' -Encoding ascii
Use-Home $auditHome
$env:DOTBACKUP_AUDIT = '1'
try { $r = Invoke-Script51 $Backup } finally { Remove-Item Env:DOTBACKUP_AUDIT -ErrorAction SilentlyContinue }
if ($r.Code -ne 0) { Fail "[5] backup failed: $($r.Out)" }
$auditPayload = Join-Path "$(Get-OnlyArchive $auditHome).contents" 'dotfiles-backup-v1'
if (-not (Test-Path -LiteralPath (Join-Path $auditPayload 'guardrail\audit\audit-2026.jsonl'))) { Fail '[5] audit log not captured with DOTBACKUP_AUDIT=1' }
if ($r.Out -notmatch 'Audit log: 1 segment\(s\), ') { Fail "[5] audit size not reported: $($r.Out)" }
foreach ($never in @('session-checks', 'previous.json', 'guardrail.previous.exe', 'claude.json')) {
    if (@(Get-ChildItem -LiteralPath $auditPayload -Recurse -Force -Filter $never).Count -ne 0) { Fail "[5] $never must never be captured" }
}
Write-Host '  ok: audit opt-in captured and sized; per-machine state never captured'

# --- [6] No guardrail state at all: no guardrail\ entry.
$plainHome = Join-Path $Tmp 'home-plain'
Build-GuardrailHome $plainHome 'prompt' -NoGuardrail
Use-Home $plainHome
$r = Invoke-Script51 $Backup
if ($r.Code -ne 0) { Fail "[6] backup failed: $($r.Out)" }
if (Test-Path -LiteralPath (Join-Path "$(Get-OnlyArchive $plainHome).contents" 'dotfiles-backup-v1\guardrail')) { Fail '[6] guardrail\ present without guardrail state' }
Write-Host '  ok: no guardrail section when guardrail was never configured'

# --- [7] Cross-OS: config restored, passkey enrollment skipped with a notice.
$passkeyArchive = $archive   # the round-trip archive from [1]: passkey mode, enrollment captured
$crossArchive = Join-Path $Tmp 'cross-os.7z'
Copy-ArchiveWith $passkeyArchive $crossArchive 'linux'
$crossHome = Join-Path $Tmp 'home-cross'
Use-Home $crossHome
$r = Invoke-Script51 $Restore @('-Archive', $crossArchive)
if ($r.Code -ne 0) { Fail "[7] cross-OS restore failed: $($r.Out)" }
if (-not (Test-Path -LiteralPath (Join-Path $crossHome 'AppData\Roaming\guardrail\waivers.toml'))) { Fail '[7] cross-OS restore dropped waivers.toml' }
if (Test-Path -LiteralPath (Join-Path $crossHome '.local\state\guardrail\operator-auth')) { Fail '[7] cross-OS restore wrote passkey enrollment' }
if ($r.Out -notmatch 'enroll again') { Fail "[7] skipped enrollment not reported: $($r.Out)" }
Write-Host '  ok: cross-OS restore skips passkey enrollment'

# --- [8] An existing guardrail file is never overwritten, and nothing is written first.
$collideHome = Join-Path $Tmp 'home-collide'
Use-Home $collideHome
New-Item -ItemType Directory -Force -Path (Join-Path $collideHome 'AppData\Roaming\guardrail') | Out-Null
Set-Content -LiteralPath (Join-Path $collideHome 'AppData\Roaming\guardrail\waivers.toml') -Value 'keep' -Encoding ascii
$r = Invoke-Script51 $Restore @('-Archive', $passkeyArchive)
if ($r.Code -eq 0) { Fail '[8] existing waivers.toml was overwritten' }
if ($r.Out -notmatch 'Refusing to overwrite existing guardrail file') { Fail "[8] refusal not reported: $($r.Out)" }
if ((Get-Content -LiteralPath (Join-Path $collideHome 'AppData\Roaming\guardrail\waivers.toml')) -ne 'keep') { Fail '[8] collision changed waivers.toml' }
if (Test-Path -LiteralPath (Join-Path $collideHome '.config\chezmoi\chezmoi.toml')) { Fail '[8] collision rejection wrote config first' }
Write-Host '  ok: restore refuses to overwrite guardrail files'

# --- [9] Anything outside the fixed guardrail allowlist is rejected.
$badArchive = Join-Path $Tmp 'bad-allowlist.7z'
Copy-ArchiveWith $passkeyArchive $badArchive '' @{ 'manifests\claude.json' = 'stale' }
$badHome = Join-Path $Tmp 'home-bad'
Use-Home $badHome
$r = Invoke-Script51 $Restore @('-Archive', $badArchive)
if ($r.Code -eq 0) { Fail '[9] archive with a stale manifest was restored' }
if (Test-Path -LiteralPath (Join-Path $badHome '.config\chezmoi\chezmoi.toml')) { Fail '[9] rejected archive wrote config' }
Write-Host '  ok: guardrail allowlist enforced on restore'

# --- [10] XDG_STATE_HOME moves operator-auth (guardrail's rule, even on Windows); a root
# outside USERPROFILE is refused before anything is written.
$xdgHome = Join-Path $Tmp 'home-xdg'
Build-GuardrailHome $xdgHome 'passkey'
Move-Item -LiteralPath (Join-Path $xdgHome '.local\state\guardrail') -Destination (Join-Path $xdgHome 'xst-root') -Force
New-Item -ItemType Directory -Force -Path (Join-Path $xdgHome 'xst') | Out-Null
Move-Item -LiteralPath (Join-Path $xdgHome 'xst-root') -Destination (Join-Path $xdgHome 'xst\guardrail') -Force
Use-Home $xdgHome
$env:XDG_STATE_HOME = Join-Path $xdgHome 'xst'
try { $r = Invoke-Script51 $Backup } finally { Remove-Item Env:XDG_STATE_HOME -ErrorAction SilentlyContinue }
if ($r.Code -ne 0) { Fail "[10] backup failed: $($r.Out)" }
$xdgArchive = Get-OnlyArchive $xdgHome
if (-not (Test-Path -LiteralPath (Join-Path "$xdgArchive.contents" 'dotfiles-backup-v1\guardrail\operator-auth\nested\key'))) { Fail '[10] backup ignored XDG_STATE_HOME' }
$xdgRestore = Join-Path $Tmp 'home-xdg-restore'
Use-Home $xdgRestore
$env:XDG_STATE_HOME = Join-Path $xdgRestore 'xst'
try { $r = Invoke-Script51 $Restore @('-Archive', $xdgArchive) } finally { Remove-Item Env:XDG_STATE_HOME -ErrorAction SilentlyContinue }
if ($r.Code -ne 0) { Fail "[10] restore failed: $($r.Out)" }
if (-not (Test-Path -LiteralPath (Join-Path $xdgRestore 'xst\guardrail\operator-auth\nested\key'))) { Fail '[10] restore ignored XDG_STATE_HOME' }
if (Test-Path -LiteralPath (Join-Path $xdgRestore '.local\state\guardrail')) { Fail '[10] restore also wrote the default state root' }
$outsideHome = Join-Path $Tmp 'home-xdg-outside'
Use-Home $outsideHome
$env:XDG_STATE_HOME = Join-Path $Tmp 'outside-profile-state'
try { $r = Invoke-Script51 $Restore @('-Archive', $xdgArchive) } finally { Remove-Item Env:XDG_STATE_HOME -ErrorAction SilentlyContinue }
if ($r.Code -eq 0) { Fail '[10] a state root outside USERPROFILE must be refused' }
if ($r.Out -notmatch 'outside USERPROFILE') { Fail "[10] the refusal must say the root is outside USERPROFILE: $($r.Out)" }
if (Test-Path -LiteralPath (Join-Path $outsideHome '.config\chezmoi\chezmoi.toml')) { Fail '[10] refused restore wrote config first' }
Write-Host '  ok: XDG_STATE_HOME honored for operator-auth; a root outside USERPROFILE is refused'

# --- [11] Repo grants keyed by absolute path that will not apply here are named.
$realRepo = Join-Path $Tmp 'real-repo'
New-Item -ItemType Directory -Force -Path $realRepo | Out-Null
$escapedReal = $realRepo.Replace('\', '\\')
$waiverText = "approval = `"passkey`"`n`n[`"/home/gone/repo`"]`n  secret_allow = false`n`n[`"C:\\Users\\gone\\repo`"]`n  secret_allow = false`n`n[`"$escapedReal`"]`n  secret_allow = false`n`n[web_hosts]`n  `"example.com`" = true`n"
$inertArchive = Join-Path $Tmp 'inert.7z'
Copy-ArchiveWith $passkeyArchive $inertArchive '' @{ 'config\waivers.toml' = $waiverText }
$inertHome = Join-Path $Tmp 'home-inert'
Use-Home $inertHome
$r = Invoke-Script51 $Restore @('-Archive', $inertArchive)
if ($r.Code -ne 0) { Fail "[11] restore failed: $($r.Out)" }
if ($r.Out -notmatch '2 repo grant\(s\)') { Fail "[11] the count must be 2: $($r.Out)" }
if (-not $r.Out.Contains('/home/gone/repo')) { Fail "[11] a Unix-path grant must be listed: $($r.Out)" }
if (-not $r.Out.Contains('C:\Users\gone\repo')) { Fail "[11] a missing Windows-path grant must be listed: $($r.Out)" }
if ($r.Out.Contains($realRepo)) { Fail "[11] a grant whose directory exists must not be listed: $($r.Out)" }
if ($r.Out.Contains('web_hosts')) { Fail "[11] a non-path table must not be listed: $($r.Out)" }
$cleanHome = Join-Path $Tmp 'home-inert-clean'
Use-Home $cleanHome
$r = Invoke-Script51 $Restore @('-Archive', $passkeyArchive)
if ($r.Code -ne 0) { Fail "[11] clean restore failed: $($r.Out)" }
if ($r.Out.Contains('grant(s)')) { Fail "[11] no warning expected when there are no repo grants: $($r.Out)" }
Write-Host '  ok: restore names repo grants that will not apply here'

Remove-Item Env:FAKE_7Z_LOG -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
Write-Host 'PASS: dotbackup_restore.ps1 (backup -> restore -> refuse round-trip under 5.1)'
exit 0
