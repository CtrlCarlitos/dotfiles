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

# --- Live run logs and console verbosity ([data.logging], docs/logging.md) ------------------
# A run's console is the only record of what happened, and it is gone once the window closes; it
# cannot be watched from elsewhere either. With logging on (the default) every run keeps a
# transcript under ~\.local\state\dotfiles\logs\, written as the run goes, so it can be followed
# live (Get-Content -Wait) or read afterwards. A transcript records what PowerShell writes:
# Write-Host lines, prompts and answers, the installer lines the filter above lets through
# (install.log keeps the hidden ones), and native output piped through Out-Host.

# One [data.logging] setting: the environment variable $Name for this run (1/true/yes/on or
# 0/false/no/off), else `$Key = true|false` in chezmoi.toml, else $Default. Read at run time, not
# rendered into the installer: a rendered value would change the run_onchange script's hash, so
# turning verbose on would re-run the whole package install (the same reason
# Test-DesktopShortcutsDisabled reads the file). A plain line scan: `chezmoi data` would resolve
# its own config path (docs/invariants.md #5).
function Resolve-DotFlag {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Key,
        [bool]$Default,
        [string]$ConfigPath = (Join-Path $HOME '.config\chezmoi\chezmoi.toml')
    )
    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        if ($value.Trim() -match '^(?i:1|true|yes|on)$') { return $true }
        if ($value.Trim() -match '^(?i:0|false|no|off)$') { return $false }
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        $inLogging = $false
        foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
            if ($line -match '^\s*\[data\.logging\]\s*$') { $inLogging = $true; continue }
            if ($inLogging -and $line -match '^\s*\[') { break }
            if ($inLogging -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(true|false)\s*(#.*)?$')) {
                return ($Matches[1] -eq 'true')
            }
        }
    }
    return $Default
}

# Starts this run's transcript (<Name>-<yyyyMMdd-HHmmss>.log) and keeps the newest $Keep logs.
# Returns its path, or '' when logging is off or the transcript could not start - a run never
# fails over its log.
function Open-DotLog {
    param([Parameter(Mandatory)][string]$Name, [bool]$Enabled = $true, [string]$Root = $HOME, [int]$Keep = 20)
    if (-not $Enabled) { return '' }
    try {
        $dir = Join-Path $Root '.local\state\dotfiles\logs'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $path = Join-Path $dir ('{0}-{1}.log' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -LiteralPath $path -Force | Out-Null
        Get-ChildItem -LiteralPath $dir -Filter '*.log' -File | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $Keep | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "  Live log: $path" -ForegroundColor DarkGray
        return $path
    }
    catch {
        Write-Host "  Warning: could not start the run log - $($_.Exception.Message)" -ForegroundColor Yellow
        return ''
    }
}

function Close-DotLog {
    try { Stop-Transcript | Out-Null } catch { $null = $_ }
}

# verbose = true: show what the console normally hides. Call after Initialize-InstallerOutput
# (it sets the noise pattern this replaces with one that matches nothing).
function Enable-DotVerbose {
    param([bool]$Enabled)
    if (-not $Enabled) { return }
    $env:DOT_INSTALLER_NOISE = '(?!)'
    $env:DOT_GUARDRAIL_VERBOSE = '1'
    Write-Host "  Verbose output on ([data.logging] verbose or DOT_VERBOSE)" -ForegroundColor DarkGray
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
