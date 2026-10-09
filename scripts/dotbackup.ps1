<#
dotbackup.ps1 - encrypted portable backup of this machine's dotfiles state
(Windows twin of scripts/dotbackup.sh). Packs the chezmoi config and every
regular file under ~/.ssh into an AES-256 7-Zip archive under ~/.dot_backups.
Prompts for the passphrase; never echoed or passed on the command line.
Usage: .\dotbackup.ps1    (or: dot backup)  - docs/backup-restore.md
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SevenZip {
    foreach ($name in '7zz', '7z') {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    # The 7-Zip installer (winget 7zip.7zip, the core package) does not add
    # itself to PATH: find it through its own registry key, then the default
    # install folder.
    $folders = @()
    foreach ($key in 'HKLM:\SOFTWARE\7-Zip', 'HKCU:\SOFTWARE\7-Zip') {
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            foreach ($value in 'Path64', 'Path') {
                if ($item.PSObject.Properties[$value]) { $folders += $item.$value }
            }
        }
    }
    $folders += (Join-Path $env:ProgramFiles '7-Zip')
    foreach ($folder in $folders) {
        $candidate = Join-Path $folder '7z.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'Install 7-Zip (7zz or 7z) first.'
}

$sevenZip = Get-SevenZip
$config = Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml'
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
    throw "Missing ChezMoi config: $config"
}
$configItem = Get-Item -LiteralPath $config -Force
if ($configItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Refusing reparse-point ChezMoi config: $config"
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ("dotbackup-" + [guid]::NewGuid())
try {
    $payloadRoot = Join-Path $stage 'dotfiles-backup-v1'
    $chezmoiRoot = Join-Path $payloadRoot 'chezmoi'
    $sshRoot = Join-Path $payloadRoot 'ssh'
    New-Item -ItemType Directory -Path $chezmoiRoot, $sshRoot -Force | Out-Null
    Copy-Item -LiteralPath $config -Destination (Join-Path $chezmoiRoot 'chezmoi.toml')

    $sshSource = Join-Path $env:USERPROFILE '.ssh'
    if (Test-Path -LiteralPath $sshSource -PathType Container) {
        Get-ChildItem -LiteralPath $sshSource -File -Recurse -Force |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            ForEach-Object {
                # Twin of dotrestore.ps1's relative-path slice. 5.1 is the
                # documented host (docs/backup-restore.md) and has no
                # [IO.Path]::GetRelativePath (.NET Core only).
                $relative = $_.FullName.Substring($sshSource.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                $destination = Join-Path $sshRoot $relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $destination
            }
    }

    # guardrail operator state (optional section; twin of dotbackup.sh). Windows
    # splits it across three roots: %APPDATA%\guardrail (waivers.toml,
    # night.toml), %LOCALAPPDATA%\guardrail (audit log) and
    # %USERPROFILE%\.local\state\guardrail (operator-auth). Only what cannot be
    # recreated is captured; operator-auth only in passkey mode, the audit log
    # only with DOTBACKUP_AUDIT=1. manifests, sessions, allowances (auth.key),
    # selftest-passed, the binary and backups\*.exe are never captured.
    $guardrailCount = 0
    $auditSegments = 0
    $auditBytes = 0L
    $guardrailConfig = Join-Path $env:APPDATA 'guardrail'
    # operator-auth follows XDG_STATE_HOME even on Windows (guardrail's own rule);
    # the config (%APPDATA%) and audit (%LOCALAPPDATA%) roots ignore XDG there.
    $stateBase = if ($env:XDG_STATE_HOME -and [IO.Path]::IsPathRooted($env:XDG_STATE_HOME)) { $env:XDG_STATE_HOME } else { Join-Path $env:USERPROFILE '.local\state' }
    $guardrailState = Join-Path $stateBase 'guardrail'
    $guardrailRoot = Join-Path $payloadRoot 'guardrail'
    foreach ($name in 'waivers.toml', 'night.toml') {
        $item = Get-Item -LiteralPath (Join-Path $guardrailConfig $name) -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and -not $item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            New-Item -ItemType Directory -Path (Join-Path $guardrailRoot 'config') -Force | Out-Null
            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $guardrailRoot "config\$name")
            $guardrailCount++
        }
    }
    $waivers = Join-Path $guardrailConfig 'waivers.toml'
    $authSource = Join-Path $guardrailState 'operator-auth'
    if ((Test-Path -LiteralPath $waivers -PathType Leaf) -and
        (Select-String -LiteralPath $waivers -Pattern '^\s*approval\s*=\s*"passkey"' -Quiet) -and
        (Test-Path -LiteralPath $authSource -PathType Container)) {
        Get-ChildItem -LiteralPath $authSource -File -Recurse -Force |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            ForEach-Object {
                $relative = $_.FullName.Substring($authSource.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                $destination = Join-Path $guardrailRoot "operator-auth\$relative"
                New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $destination
                $guardrailCount++
            }
    }
    if ($env:DOTBACKUP_AUDIT -eq '1') {
        $auditSource = Join-Path $env:LOCALAPPDATA 'guardrail'
        if (Test-Path -LiteralPath $auditSource -PathType Container) {
            Get-ChildItem -LiteralPath $auditSource -Filter 'audit*.jsonl' -File -Force |
                Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                ForEach-Object {
                    New-Item -ItemType Directory -Path (Join-Path $guardrailRoot 'audit') -Force | Out-Null
                    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $guardrailRoot "audit\$($_.Name)")
                    $guardrailCount++
                    $auditSegments++
                    $auditBytes += $_.Length
                }
        }
    }

    # WriteAllText with UTF8Encoding($false) = no BOM, same as every other
    # script here. 5.1 has no `-Encoding utf8NoBOM` (pwsh 6+), and 5.1's
    # default Set-Content encoding writes a BOM.
    # source_platform is normalized to the canonical vocabulary the restore
    # twins compare against: windows / linux / darwin (Win32NT etc. mapped).
    $manifest = [ordered]@{
        format_version = 'dotfiles-backup-v1'
        created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        source_platform = 'windows'
    } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'manifest.json'), $manifest, (New-Object System.Text.UTF8Encoding($false)))

    # RESTORE.md: human-only orientation inside the archive (the restore
    # scripts never read it - they act on manifest.json). What is inside, how
    # to restore on the same OS, and what changes on a different OS.
    $restoreMd = @"
# Dotfiles backup (created on windows, $(Get-Date -Format 'yyyy-MM-dd'))

## Contents

- ``chezmoi/chezmoi.toml`` - this machine's ChezMoi config (prompted values,
  package groups, ssh_hosts, remote_access). Review before reusing on a
  different OS: paths and remote_access values are machine-specific.
- ``ssh/`` - every regular file from this machine's ``~/.ssh``: private keys,
  .pub halves, config, known_hosts.
- ``guardrail/`` - present only if guardrail was configured: ``config/``
  (waivers.toml, night.toml: approval mode and every per-repo grant),
  ``operator-auth/`` (passkey enrollment, same machine only) and ``audit/``
  (history). Review waivers.toml before restoring: it re-applies every old
  grant.

## Restore on the same OS

````powershell
7z x -p <this-archive> -o<stage>
.\dotrestore.ps1 -Archive <stage>/dotfiles-backup-v1   # from the dotfiles repo
`````
Then: ``chezmoi init`` && ``chezmoi apply``.

## Restore on a different OS

The ssh keys translate: the restore normalizes permissions (user-only ACL on
Windows, 600 + CRLF strip on Linux/macOS targets). The chezmoi config needs a
human pass first - machine paths and remote_access values do not translate.

## Model

Private keys live in exactly one place per platform (the Windows agent vault,
or this machine's ~/.ssh) - .pub halves are the only thing duplicated across
machines, and Host blocks reference the .pub.
"@
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'RESTORE.md'), $restoreMd, (New-Object System.Text.UTF8Encoding($false)))

    $backupDirectory = Join-Path $HOME '.dot_backups'
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $archive = Join-Path $backupDirectory ("dotfiles-windows-" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.7z')
    if (Test-Path -LiteralPath $archive) {
        throw "Backup archive already exists: $archive"
    }

    & $sevenZip 'a' '-t7z' '-mhe=on' '-p' $archive $payloadRoot
    # Twin of the .sh notice: say what the archive holds. Counted by exclusion
    # so nothing here ever opens a private key.
    $keyCount = 0
    $sshRoot = Join-Path $HOME '.ssh'
    if (Test-Path -LiteralPath $sshRoot) {
        $skip = @('config', 'known_hosts', 'known_hosts.old', 'authorized_keys', 'environment')
        $keyCount = @(Get-ChildItem -LiteralPath $sshRoot -File -Recurse |
            Where-Object { $_.Extension -ne '.pub' -and $skip -notcontains $_.Name }).Count
    }

    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip failed while creating backup (exit code $LASTEXITCODE)."
    }

    Write-Output "Backup created: $archive"
    Write-Output "  Contains $keyCount private key file(s) from ~/.ssh. Treat this archive as key material."
    Write-Output "  Contains $guardrailCount guardrail operator file(s)."
    if ($auditSegments -gt 0) {
        # Rotated segments pile up on a long-lived machine: say how big before it is handed around.
        Write-Output ("  Audit log: {0} segment(s), {1} MiB (DOTBACKUP_AUDIT=1; unset it to leave the history out)." -f $auditSegments, [math]::Floor($auditBytes / 1MB))
    }
    Write-Output "  This is disaster recovery for THIS machine, not a way to set up another one:"
    Write-Output "  give an additional machine its own keys instead (docs/ssh-agents.md)."
    Write-Output "  Re-run after rotating a key - older archives still hold the old ones."
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
