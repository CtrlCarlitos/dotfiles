<#
dotrestore.ps1 - restore a dotbackup archive onto this machine (Windows twin
of scripts/dotrestore.sh). Validates the manifest, restores the allowlisted
config + ~/.ssh files, and refuses to overwrite an existing chezmoi config or
any existing ~/.ssh file. Afterwards run `chezmoi init` then `chezmoi apply`.
Usage: .\dotrestore.ps1 -Archive <backup.7z>   (or: dot restore <archive>)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Archive
)

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

function Test-DestinationParentsSafe {
    # $HOME itself is ReadOnly+AllScope, so a parameter must not be named $Home.
    param([string]$Destination, [string]$HomeDir)

    $homePath = [IO.Path]::GetFullPath($HomeDir).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Destination))
    while ($true) {
        $parentPath = [IO.Path]::GetFullPath($parent).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if (-not $parentPath.StartsWith($homePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Destination is outside USERPROFILE: $Destination"
        }

        $item = Get-Item -LiteralPath $parentPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            if (-not $item.PSIsContainer) {
                throw "Destination parent is not a directory: $parentPath"
            }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing reparse-point destination parent: $parentPath"
            }
        }

        if ($parentPath -eq $homePath) {
            return
        }
        $parent = Split-Path -Parent $parentPath
    }
}

if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) {
    throw "Archive is not readable: $Archive"
}

$sevenZip = Get-SevenZip
$stage = Join-Path ([IO.Path]::GetTempPath()) ("dotrestore-" + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path $stage | Out-Null

    & $sevenZip 'x' '-p' "-o$stage" $Archive
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip failed while extracting archive (exit code $LASTEXITCODE)."
    }

    $rootEntries = @(Get-ChildItem -LiteralPath $stage -Force)
    if ($rootEntries.Count -ne 1 -or $rootEntries[0].Name -ne 'dotfiles-backup-v1' -or -not $rootEntries[0].PSIsContainer -or ($rootEntries[0].Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Archive does not contain the dotfiles-backup-v1 layout.'
    }

    $payloadRoot = $rootEntries[0].FullName
    $stagedReparsePoint = Get-ChildItem -LiteralPath $payloadRoot -Force -Recurse |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Select-Object -First 1
    if ($null -ne $stagedReparsePoint) {
        throw "Archive contains a reparse point: $($stagedReparsePoint.FullName)"
    }

    $payloadEntries = @(Get-ChildItem -LiteralPath $payloadRoot -Force)
    $expectedPayloadEntries = 'manifest.json', 'chezmoi', 'ssh'
    if ($payloadEntries.Count -ne 3 -or (($payloadEntries.Name | Sort-Object) -join '|') -ne (($expectedPayloadEntries | Sort-Object) -join '|')) {
        throw 'Archive does not contain the dotfiles-backup-v1 layout.'
    }

    $manifest = Join-Path $payloadRoot 'manifest.json'
    $chezmoiSource = Join-Path $payloadRoot 'chezmoi'
    $configSource = Join-Path $chezmoiSource 'chezmoi.toml'
    $sshSource = Join-Path $payloadRoot 'ssh'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf) -or -not (Test-Path -LiteralPath $chezmoiSource -PathType Container) -or -not (Test-Path -LiteralPath $configSource -PathType Leaf) -or -not (Test-Path -LiteralPath $sshSource -PathType Container)) {
        throw 'Archive does not contain the dotfiles-backup-v1 layout.'
    }

    try {
        $manifestData = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    }
    catch {
        throw 'Invalid backup manifest.'
    }
    if ($manifestData.format_version -ne 'dotfiles-backup-v1') {
        throw 'Invalid backup manifest.'
    }

    $configDestination = Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml'
    Test-DestinationParentsSafe -Destination $configDestination -HomeDir $env:USERPROFILE
    $configDestinationItem = Get-Item -LiteralPath $configDestination -Force -ErrorAction SilentlyContinue
    if ($null -ne $configDestinationItem) {
        if ($configDestinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing reparse-point destination: $configDestination"
        }
        throw "Refusing to overwrite existing ChezMoi config: $configDestination"
    }

    $sshDestinationRoot = Join-Path $env:USERPROFILE '.ssh'
    $sshFiles = @(Get-ChildItem -LiteralPath $sshSource -File -Recurse -Force)

    Test-DestinationParentsSafe -Destination (Join-Path $sshDestinationRoot '.dotrestore-parent-check') -HomeDir $env:USERPROFILE
    foreach ($source in $sshFiles) {
        $relative = $source.FullName.Substring($sshSource.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $destination = Join-Path $sshDestinationRoot $relative
        Test-DestinationParentsSafe -Destination $destination -HomeDir $env:USERPROFILE
        $destinationItem = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        if ($null -ne $destinationItem) {
            if ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing reparse-point destination: $destination"
            }
            throw "Refusing to overwrite existing SSH file: $destination"
        }
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $configDestination) -Force | Out-Null
    Copy-Item -LiteralPath $configSource -Destination $configDestination
    if ($sshFiles.Count -gt 0) {
        New-Item -ItemType Directory -Path $sshDestinationRoot -Force | Out-Null
        foreach ($source in $sshFiles) {
            $relative = $source.FullName.Substring($sshSource.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            $destination = Join-Path $sshDestinationRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source.FullName -Destination $destination
        }
    }

    Write-Output "Restore complete. Run:`n  chezmoi init`n  chezmoi apply"
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
