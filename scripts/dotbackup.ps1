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
                $relative = [IO.Path]::GetRelativePath($sshSource, $_.FullName)
                $destination = Join-Path $sshRoot $relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $destination
            }
    }

    [ordered]@{
        format_version = 'dotfiles-backup-v1'
        created_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        source_platform = [Environment]::OSVersion.Platform.ToString()
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $payloadRoot 'manifest.json') -Encoding utf8NoBOM

    $backupDirectory = Join-Path $HOME '.dot_backups'
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $archive = Join-Path $backupDirectory ("dotfiles-" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.7z')
    if (Test-Path -LiteralPath $archive) {
        throw "Backup archive already exists: $archive"
    }

    & $sevenZip 'a' '-t7z' '-mhe=on' '-p' $archive $payloadRoot
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip failed while creating backup (exit code $LASTEXITCODE)."
    }

    Write-Output "Backup created: $archive"
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
