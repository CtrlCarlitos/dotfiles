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

function Write-InertGrantReport {
    # waivers.toml keys a repo grant by its ABSOLUTE path (a table named
    # ["C:\\abs\\path"] or ["/abs/path"]). After a cross-OS, cross-user or
    # cross-drive restore those match nothing and the grants silently never
    # apply, so name them. A path key is inert when it is the other OS's form or
    # its directory does not exist here. Non-path tables ([web_hosts]) are not
    # repo grants and are ignored. Twin of report_inert_grants in dotrestore.sh.
    param([string]$Waivers)

    if (-not (Test-Path -LiteralPath $Waivers -PathType Leaf)) { return }
    $inert = @()
    foreach ($line in @(Get-Content -LiteralPath $Waivers)) {
        if ($line -notmatch '^\["(.*)"\]\s*$') { continue }
        $path = $Matches[1].Replace('\\', '\')   # TOML basic string: \\ is one backslash
        if ($path -match '^[A-Za-z]:[\\/]') {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { $inert += "    - $path (directory not found here)" }
        }
        elseif ($path.StartsWith('/')) {
            $inert += "    - $path (a Unix path)"
        }
    }
    if ($inert.Count -eq 0) { return }
    Write-Output "  WARNING: $($inert.Count) repo grant(s) in waivers.toml will not apply on this machine:"
    $inert | Select-Object -First 10 | ForEach-Object { Write-Output $_ }
    if ($inert.Count -gt 10) { Write-Output "    ... and $($inert.Count - 10) more" }
    Write-Output '  Re-grant them from the repos that still matter (they are keyed by absolute path).'
}

# operator-auth follows XDG_STATE_HOME even on Windows (guardrail's own rule);
# a root outside USERPROFILE is refused by Test-DestinationParentsSafe before
# anything is written. Twin of the root resolution in dotbackup.ps1.
$guardrailStateBase = if ($env:XDG_STATE_HOME -and [IO.Path]::IsPathRooted($env:XDG_STATE_HOME)) { $env:XDG_STATE_HOME } else { Join-Path $env:USERPROFILE '.local\state' }

function Get-GuardrailDestination {
    # Where a file under guardrail/ belongs on Windows, or $null for anything
    # outside the fixed allowlist (a crafted archive cannot pick a destination).
    # Three roots: %APPDATA% (operator config), %LOCALAPPDATA% (audit log) and
    # %USERPROFILE%\.local\state (operator-auth).
    param([string]$Relative)

    $parts = @($Relative -split '[\\/]')
    switch ($parts[0]) {
        'config' {
            if ($parts.Count -eq 2 -and @('waivers.toml', 'night.toml') -contains $parts[1]) {
                return Join-Path (Join-Path $env:APPDATA 'guardrail') $parts[1]
            }
        }
        'operator-auth' {
            if ($parts.Count -ge 2) {
                return Join-Path (Join-Path $guardrailStateBase 'guardrail') ($parts -join '\')
            }
        }
        'audit' {
            if ($parts.Count -eq 2 -and $parts[1] -like 'audit*.jsonl') {
                return Join-Path (Join-Path $env:LOCALAPPDATA 'guardrail') $parts[1]
            }
        }
    }
    return $null
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

    # 'guardrail' is the one optional entry (absent in older archives and when
    # guardrail was never configured); the other four are required.
    $payloadEntries = @(Get-ChildItem -LiteralPath $payloadRoot -Force)
    $expectedPayloadEntries = 'manifest.json', 'RESTORE.md', 'chezmoi', 'ssh'
    $payloadNames = @($payloadEntries.Name | Where-Object { $_ -ne 'guardrail' })
    if ($payloadNames.Count -ne 4 -or (($payloadNames | Sort-Object) -join '|') -ne (($expectedPayloadEntries | Sort-Object) -join '|')) {
        throw 'Archive does not contain the dotfiles-backup-v1 layout.'
    }
    $guardrailSource = Join-Path $payloadRoot 'guardrail'
    if ((Test-Path -LiteralPath $guardrailSource) -and -not (Test-Path -LiteralPath $guardrailSource -PathType Container)) {
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

    # source_platform is read through the property table: a manifest without it
    # must not throw under StrictMode. Passkey enrollment is bound to the
    # machine and authenticator it was made on, so a cross-OS restore skips it.
    $sourcePlatformProperty = $manifestData.PSObject.Properties['source_platform']
    $sourcePlatform = if ($null -ne $sourcePlatformProperty) { ([string]$sourcePlatformProperty.Value).ToLowerInvariant() } else { '' }
    $crossOs = ($sourcePlatform -ne '' -and $sourcePlatform -ne 'windows')

    $guardrailFiles = @()
    $skippedAuth = 0
    if (Test-Path -LiteralPath $guardrailSource -PathType Container) {
        foreach ($source in @(Get-ChildItem -LiteralPath $guardrailSource -File -Recurse -Force)) {
            $relative = $source.FullName.Substring($guardrailSource.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            $destination = Get-GuardrailDestination -Relative $relative
            if ($null -eq $destination) {
                throw 'Archive does not contain the dotfiles-backup-v1 layout.'
            }
            if ($crossOs -and $relative -like 'operator-auth*') {
                $skippedAuth++
                continue
            }
            Test-DestinationParentsSafe -Destination $destination -HomeDir $env:USERPROFILE
            $destinationItem = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            if ($null -ne $destinationItem) {
                if ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Refusing reparse-point destination: $destination"
                }
                throw "Refusing to overwrite existing guardrail file: $destination"
            }
            $guardrailFiles += [pscustomobject]@{ Source = $source.FullName; Destination = $destination }
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

        # Cross-OS normalization: an archive from a non-Windows platform
        # carries Unix-style keys - lock restored id_* files to the owning
        # user (OpenSSH for Windows refuses identity files readable by broad
        # principals) and print the translation. Same-platform restores keep
        # current behavior.
        if ($crossOs) {
            $normalized = @()
            foreach ($keyfile in (Get-ChildItem (Join-Path $sshDestinationRoot '.ssh') -Filter 'id_*' -File -ErrorAction SilentlyContinue)) {
                & icacls $keyfile.FullName /grant:r "$($env:USERNAME):R" *> $null
                & icacls $keyfile.FullName /inheritance:r *> $null
                & icacls $keyfile.FullName /remove:g *S-1-1-0 *S-1-5-11 *S-1-5-32-545 *> $null
                $normalized += $keyfile.Name
            }
            Write-Output "Cross-OS restore (source: $sourcePlatform, target: windows): normalized ACL on $($normalized.Count) key file(s)."
        }
    }

    # guardrail operator state: user-only ACL (twin of the .sh 600/700), put
    # back before `dot up` runs guardrail setup so setup sees the approval mode.
    if (Test-Path -LiteralPath $guardrailSource -PathType Container) {
        $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($entry in $guardrailFiles) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $entry.Destination) -Force | Out-Null
            Copy-Item -LiteralPath $entry.Source -Destination $entry.Destination
            & icacls $entry.Destination /inheritance:r /grant:r "*${userSid}:(F)" *> $null
        }
        Write-Output "Restored $($guardrailFiles.Count) guardrail operator file(s), user-only."
        Write-Output "  Review %APPDATA%\guardrail\waivers.toml: it re-applies every old grant."
        Write-InertGrantReport -Waivers (Join-Path (Join-Path $env:APPDATA 'guardrail') 'waivers.toml')
        if ($skippedAuth -gt 0) {
            Write-Output "  Skipped $skippedAuth passkey enrollment file(s): enroll again on this machine."
        }
    }

    Write-Output "Restore complete. Run:`n  chezmoi init`n  chezmoi apply"
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
