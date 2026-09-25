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

$Log = Join-Path $Tmp '7z.log'
[IO.File]::WriteAllText($Log, '', $Utf8NoBom)
$env:HOME = $homeSource
$env:USERPROFILE = $homeSource
$env:PATH = "$bin;$env:PATH"
$env:FAKE_7Z_LOG = $Log

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
Write-Host '  ok: 5.1 backup creates the encrypted v1 archive, no-BOM manifest, full payload'

# --- [2] Restore into an empty home round-trips every staged file.
$homeRestore = Join-Path $Tmp 'home-restore'
New-Item -ItemType Directory -Force -Path $homeRestore | Out-Null
$env:HOME = $homeRestore
$env:USERPROFILE = $homeRestore
$restoreOut = & $powerShell5 -NoProfile -ExecutionPolicy Bypass -File $Restore -Archive $archive 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "[2] restore failed under 5.1: $restoreOut" }
foreach ($rel in @('.config\chezmoi\chezmoi.toml', '.ssh\custom_signing_key', '.ssh\custom_signing_key.pub', '.ssh\nested\deep_key')) {
    $srcContent = [IO.File]::ReadAllText((Join-Path $homeSource $rel))
    $dstPath = Join-Path $homeRestore $rel
    if (-not (Test-Path -LiteralPath $dstPath)) { Fail "[2] restore did not produce $rel : $restoreOut" }
    if ([IO.File]::ReadAllText($dstPath) -ne $srcContent) { Fail "[2] content mismatch for $rel" }
}
Write-Host '  ok: backup -> restore round-trip preserves the payload'

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

Remove-Item Env:FAKE_7Z_LOG -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
Write-Host 'PASS: dotbackup_restore.ps1 (backup -> restore -> refuse round-trip under 5.1)'
exit 0
