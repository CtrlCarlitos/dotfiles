# scripts/lib/ps-installer-output.ps1 - what `dot up` shows of a package installer's output.
#
# `choco install` and `winget install` print 20+ lines each (licence boilerplate, validation
# banners, download URLs, hash checks, "Deployed to ..."), while every other step of `dot up`
# is one line (2026-10-09 log: nerd-fonts-FiraCode and charmbracelet.gum). The installers stay
# STREAMED - a hung or prompting installer must stay visible (see the "Capped and streamed,
# never silent" note on the choco loop) - but lines that say nothing are not shown. Everything
# is appended to ~\.local\state\dotfiles\install.log, and a failing installer points there.
#
# Only success boilerplate is matched: a failure's text (an error, "1 packages failed",
# "Installer failed with exit code") never matches, so it always shows.
#
# Inlined into the Windows installer template with `{{ include }}` (self-contained: nothing here
# may depend on ps-common.ps1). Invoke-WithTimeout runs its Action as a job, which does not
# inherit functions or variables: Initialize-InstallerOutput puts the pattern, the log path and
# the filter script itself in $env (like CHOCO_PKG), and an Action ends its installer line with
#     2>&1 | & ([scriptblock]::Create("$env:DOT_INSTALLER_FILTER"))
# tests/installer_output_filter_contract.sh executes it against real captured output.
$script:InstallerNoisePattern = '(?i)^\s*(?:' + (@(
        # blank lines and spinner frames
        '',
        '[-\\|/]',
        # Chocolatey: banner, validations, licence, source and download plumbing. Its pending-reboot
        # paragraph is hidden too: Write-PendingRebootNote says it once per run instead.
        'Chocolatey v\d\S*',
        '\d+ validations performed\..*',
        'Validation Warnings:',
        '- A pending system reboot request has been detected.*',
        'being ignored due to the current Chocolatey.*',
        'want to halt when this occurs.*',
        'using:',
        'choco feature enable --name=.*',
        'or pass the option --exit-when-reboot-detected.',
        'Installing the following packages:',
        'By installing, you accept licenses for the packages\.',
        'Downloading package from source .*',
        '.* package files install completed\. Performing other installation steps\.',
        'Downloading \S+$',
        'from ''https?://.*',
        'Download of .* completed\.',
        'Hashes match\.',
        'Extracting .* to .*',
        'Deployed to .*',
        'The install of \S+ was successful\.',
        'Software (?:installed|deployed) to .*',
        'Chocolatey installed (\d+)/\1 packages\.\s*',
        'See the log for details \(.*\)\.',
        # winget: licence boilerplate and verification steps
        'This application is licensed to you by its owner\.',
        'Microsoft is not responsible for, nor does it grant any licenses to, third-party packages\.',
        'Downloading https?://.*',
        'Successfully verified installer hash',
        'Starting package install\.\.\.',
        'Extracting archive\.\.\.',
        'Successfully extracted archive',
        'Command line alias added: .*',
        # winget progress bars
        ('.*[' + [char]0x2588 + [char]0x2592 + '].*'),
        '[\d.]+\s*[KMG]B\s*/\s*[\d.]+\s*[KMG]B'
    ) -join '|') + ')\s*$'

# Where the full installer output goes; '' when the state directory cannot be made.
function Get-InstallerLogPath {
    param([string]$Root = $HOME)
    $path = Join-Path $Root '.local\state\dotfiles\install.log'
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 2MB) {
            Move-Item -LiteralPath $path -Destination "$path.1" -Force
        }
        return $path
    }
    catch { return '' }
}

# The job-side filter: log every line, pass on the ones that say something.
$script:InstallerJobFilter = 'process { $l = "$_"; if ($env:DOT_INSTALLER_LOG) { try { Add-Content -LiteralPath $env:DOT_INSTALLER_LOG -Value $l } catch { $null = $_ } }; if ($l -notmatch $env:DOT_INSTALLER_NOISE) { $l } }'

function Initialize-InstallerOutput {
    param([string]$Root = $HOME)
    $env:DOT_INSTALLER_NOISE = $script:InstallerNoisePattern
    $env:DOT_INSTALLER_FILTER = $script:InstallerJobFilter
    $env:DOT_INSTALLER_LOG = Get-InstallerLogPath -Root $Root
}

# Chocolatey prints its "pending system reboot" validation warning on EVERY install; hidden above,
# said once here. Same sources Chocolatey reads (CBS, Windows Update, pending file renames).
function Write-PendingRebootNote {
    $pending = $false
    try {
        $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
            [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
    }
    catch { $pending = $false }
    if ($pending) { Write-Host "  Windows has a pending restart (Chocolatey ignores it); restart when convenient - new fonts and PATH entries may not show up until then." -ForegroundColor Yellow }
}
