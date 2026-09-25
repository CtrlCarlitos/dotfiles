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

    # WriteAllText with UTF8Encoding($false) = no BOM, same as every other
    # script here. 5.1 has no `-Encoding utf8NoBOM` (pwsh 6+), and 5.1's
    # default Set-Content encoding writes a BOM.
    $manifest = [ordered]@{
        format_version = 'dotfiles-backup-v1'
        created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        source_platform = [Environment]::OSVersion.Platform.ToString()
    } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $payloadRoot 'manifest.json'), $manifest, (New-Object System.Text.UTF8Encoding($false)))

    $backupDirectory = Join-Path $HOME '.dot_backups'
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $archive = Join-Path $backupDirectory ("dotfiles-" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.7z')
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
    Write-Output "  This is disaster recovery for THIS machine, not a way to set up another one:"
    Write-Output "  give an additional machine its own keys instead (docs/ssh-agents.md)."
    Write-Output "  Re-run after rotating a key - older archives still hold the old ones."
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
