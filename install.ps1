# PowerShell One-Liner Installer for Chezmoi Dotfiles
# Usage: iex "& {$(irm https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1)}"

$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 redraws the Invoke-WebRequest/Expand-Archive progress
# bar for every received chunk, throttling downloads to a crawl. Scope-local
# here (script or `& { }` block), so it never leaks into the caller's session.
$ProgressPreference = 'SilentlyContinue'

function Write-Info { param([string]$Message) Write-Host "[:] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[v] $Message" -ForegroundColor Green }
# Write-Fail, NOT a custom Write-Error: redefining Write-Error shadows the
# built-in cmdlet for this whole session (issue #123) - any library code
# loaded later that legitimately calls Write-Error would silently get this
# host-print instead of the error record. Same output, honest name.
function Write-Fail { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Red }

# Bootstrap gum (pinned) for the interactive package menu. Best-effort
# only: on failure warn and continue - without gum the menu self-skips and
# chezmoi's native config prompts take over.
#
# The pin's single source is .chezmoidata.yaml versions.gum (#125): read it
# when a checkout is on disk. The inline fallback only covers the one-liner
# run, where this script was downloaded alone - scripts/update-versions.sh
# syncs it to the yaml pin, so the two cannot drift silently.
$gumVersion = '2.0.1'
$gumYamlCandidates = @()
# $PSScriptRoot is empty under the iex one-liner - guard the Join-Path.
if ($PSScriptRoot) { $gumYamlCandidates += (Join-Path $PSScriptRoot '.chezmoidata.yaml') }
$gumYamlCandidates += (Join-Path $env:USERPROFILE '.local\share\chezmoi\.chezmoidata.yaml')
foreach ($gumYaml in $gumYamlCandidates) {
    if ($gumYaml -and (Test-Path $gumYaml)) {
        $gumMatch = Select-String -LiteralPath $gumYaml -Pattern '^\s{2}gum:\s*"?([^"]+)"?\s*$' | Select-Object -First 1
        if ($gumMatch) { $gumVersion = $gumMatch.Matches[0].Groups[1].Value; break }
    }
}
# Approved verb (PSUseApprovedVerbs): renamed from Bootstrap-Gum.
function Install-Gum {
    if (Get-Command gum -ErrorAction SilentlyContinue) { return }

    $gumDir = Join-Path $env:USERPROFILE '.local\bin'
    $zipUrl = "https://github.com/charmbracelet/gum/releases/download/v$gumVersion/gum_${gumVersion}_Windows_x86_64.zip"
    try {
        # PS 5.1 defaults can lack TLS 1.2 (same fix as the Chocolatey fetch)
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        New-Item -ItemType Directory -Force -Path $gumDir | Out-Null
        # -TimeoutSec so a stalled download errors out instead of hanging
        $zipPath = Join-Path $env:TEMP "gum_${gumVersion}_Windows_x86_64.zip"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
        Expand-Archive -Path $zipPath -DestinationPath $gumDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        # zip layout varies (flat vs nested dir) - ensure gum.exe lands at the root
        if (-not (Test-Path (Join-Path $gumDir 'gum.exe'))) {
            $nested = Get-ChildItem -Path $gumDir -Recurse -Filter 'gum.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($nested) { Move-Item -LiteralPath $nested.FullName -Destination (Join-Path $gumDir 'gum.exe') -Force }
        }
        # Session PATH: Machine+User rebuild (existing pattern) with the gum dir
        # prepended - Windows never puts ~\.local\bin on PATH by default.
        $env:Path = "$gumDir;" + [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
        if (Get-Command gum -ErrorAction SilentlyContinue) {
            Write-Success "Bootstrapped gum for the package menu."
        } else {
            Write-Info "gum extracted to $gumDir but not runnable - menu will self-skip."
        }
    } catch {
        Write-Fail "gum bootstrap failed: $_ - continuing (menu will self-skip)."
    }
}

# 0. Setup
$InstallerUrl = "https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1"
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# CI matches the convention already used in .chezmoi.toml.tmpl for the same purpose
# (GitHub Actions, and most CI systems generally, set CI=true). CHEZMOI_TEST_MINIMAL
# is the flag ci.yml's own tests set explicitly for this exact scenario. Without this
# check, Read-Host below blocks forever with no error and no timeout in a runner with
# no real stdin - confirmed live: a Windows Installer Test run hung 40+ minutes here.
$IsNonInteractive = ($env:CI -eq 'true') -or ($env:CHEZMOI_TEST_MINIMAL -eq 'true')

# Devcontainer detection (mirrors install.sh): skip gum bootstrap AND the
# package menu entirely - the non-interactive path renders all groups false
# (config-only apply), and downloading gum just to have the menu self-skip
# wastes bandwidth on every container start. Tools in devcontainers come
# from devcontainer-features during image build, not from here.
$IsDevcontainer = ($env:DEVCONTAINER -eq 'true') -or ($env:REMOTE_CONTAINERS -eq 'true')

# 0.1 Consent - ask before touching anything. Non-interactive environments
# (matched above) auto-proceed without prompting.
if (-not $IsNonInteractive) {
    # Say what actually happens (2026-10-14 fresh-install review): winget is the primary manager,
    # the apply changes machine settings, and a first install needs a restart.
    Write-Host "This installer (run as Administrator):"
    Write-Host "  - installs Git and chezmoi with winget, then applies the CtrlCarlitos dotfiles;"
    Write-Host "  - installs the package groups in ~\.config\chezmoi\chezmoi.toml (winget first, Chocolatey as fallback);"
    Write-Host "  - may enable Windows features (WSL, Virtual Machine Platform) and set the CurrentUser execution policy to RemoteSigned;"
    Write-Host "  - with the guardrail group on, registers agent hooks and a Microsoft Defender exclusion for guardrail.exe."
    Write-Host "  A first install usually needs a Windows restart at the end."
    $proceed = Read-Host "Proceed? (Y/n)"
    if ($proceed -eq 'n') {
        Write-Info "Aborted - nothing was installed. Re-run any time."
        exit 0
    }
}

# Hard requirement, not a recommendation: Chocolatey, winget's machine-scope installs, and
# `chezmoi init --apply` below (which runs run_onchange_install_packages.ps1.tmpl immediately)
# all need admin. That template has its own hard elevation gate and exits 1 the moment it's
# reached - so "continuing as standard user" used to just delay the same failure by one step,
# behind a message that implied a working degraded install. Fail here instead, before anything
# is touched, same policy as that gate (docs/windows.md, Run dot up as Administrator).
if (-not $IsAdmin) {
    if ($IsNonInteractive) {
        Write-Fail "This installer requires an elevated PowerShell (Chocolatey and machine-wide winget installs need it, and the dotfiles apply that follows hard-requires it too). Re-run from an Administrator PowerShell."
        exit 1
    }
    Write-Info "Running without Administrator privileges."
    $response = Read-Host "This installer requires Administrator rights (Chocolatey, machine-wide installs). Restart as Admin? (Y/n)"
    if ($response -eq 'n') {
        Write-Info "Aborted - nothing was installed. Re-run from an Administrator PowerShell."
        exit 0
    }
    Write-Info "Restarting as Administrator..."
    if ($PSCommandPath) {
        # Running from file - restart file
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    } else {
        # Running from one-liner - restart command
        # Using 'iex' inside the new process to re-download and run
        $cmd = "iex (irm $InstallerUrl)"
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
    }
    exit
}

# Set CurrentUser execution policy directly via the registry, not Set-ExecutionPolicy -
# that cmdlet's module can fail to auto-load inside certain non-interactive invocations.
# The chezmoi-managed run_once script that normally handles this (same technique, a
# direct registry write) confirmed live to never actually run across two real wipes on
# this machine - root cause not yet understood, so do it here too, idempotently, as a
# guaranteed path: this way the user's own PowerShell profile loads on the very next
# terminal even if everything after this point fails (e.g. the apply itself).
try {
    $execPolicyKeyPath = "HKCU:\Software\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell"
    if (-not (Test-Path $execPolicyKeyPath)) {
        New-Item -Path $execPolicyKeyPath -Force -ErrorAction Stop | Out-Null
    }
    Set-ItemProperty -Path $execPolicyKeyPath -Name "ExecutionPolicy" -Value "RemoteSigned" -Type String -Force -ErrorAction Stop
} catch {
    Write-Host "[!] Could not set the CurrentUser execution policy - $_" -ForegroundColor Yellow
}

# Lets the finally block tell a failure apart from success at the final prompt: the
# blank "Press Enter to exit..." looked identical either way, confirmed live to read
# as a hang after chezmoi init --apply failed. Set immediately before every exit 1 below -
# every real failure exits 1 explicitly (see the comment at the end of this file).
$script:InstallFailed = $false

try {
    # [data.logging] (docs/logging.md): this run's live transcript under ~\.local\state\dotfiles\logs,
    # so the install can be followed from another terminal (Get-Content -Wait) or read afterwards.
    # Inline twin of Resolve-DotFlag / Open-DotLog in scripts/lib/ps-installer-output.ps1 - a one-liner
    # cannot include it. The environment (DOT_LOG=0|1) wins, then [data.logging] log in a restored
    # chezmoi.toml, then on. Native installers below pipe through Out-Host: a transcript records only
    # what PowerShell writes. The apply's own scripts keep their own log (dot-up-*).
    $InstallLogOn = $true
    $InstallLogConfig = Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml'
    if (Test-Path -LiteralPath $InstallLogConfig) {
        $inLogging = $false
        foreach ($line in [IO.File]::ReadAllLines($InstallLogConfig)) {
            if ($line -match '^\s*\[data\.logging\]\s*$') { $inLogging = $true; continue }
            if ($inLogging -and $line -match '^\s*\[') { break }
            if ($inLogging -and $line -match '^\s*log\s*=\s*(true|false)\s*(#.*)?$') { $InstallLogOn = ($Matches[1] -eq 'true') }
        }
    }
    if ($env:DOT_LOG -match '^(?i:1|true|yes|on)$') { $InstallLogOn = $true }
    if ($env:DOT_LOG -match '^(?i:0|false|no|off)$') { $InstallLogOn = $false }
    $InstallLogOpen = $false
    if ($InstallLogOn) {
        try {
            $InstallLogDir = Join-Path $env:USERPROFILE '.local\state\dotfiles\logs'
            New-Item -ItemType Directory -Force -Path $InstallLogDir | Out-Null
            $InstallLogPath = Join-Path $InstallLogDir ('install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Start-Transcript -LiteralPath $InstallLogPath -Force | Out-Null
            $InstallLogOpen = $true
            Write-Info "Live log: $InstallLogPath (the apply adds dot-up-*.log beside it)"
        } catch {
            Write-Host "[!] Could not start the install log - continuing without it: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    # The official Chocolatey bootstrap is eval-based by design (its installer
    # script must run in this session to set env vars); PSSA suppression is
    # scoped to this wrapper so the rule stays live everywhere else.
    function Invoke-ChocoBootstrap {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'official Chocolatey bootstrap is eval-based by design')]
        param([string]$InstallerText)
        Invoke-Expression $InstallerText
    }

    # Machine+User PATH merged INTO the session's, never replacing it: a replace drops
    # session-only entries such as the gum dir Install-Gum prepends.
    # SupportsShouldProcess: same shape as Update-SessionPath (scripts/lib/ps-common.ps1), which
    # PSScriptAnalyzer's PSUseShouldProcessForStateChangingFunctions requires of an Update- verb.
    function Update-InstallerPath {
        [CmdletBinding(SupportsShouldProcess)]
        param()
        $entries = [System.Collections.Generic.List[string]]@($env:Path -split ';' | Where-Object { $_ })
        foreach ($entry in (([System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")) -split ';')) {
            if ($entry -and -not $entries.Contains($entry)) { $entries.Add($entry) }
        }
        if ($PSCmdlet.ShouldProcess('$env:Path', 'merge Machine+User registry entries')) {
            $env:Path = $entries -join ';'
        }
    }

    # 0.5 Chocolatey - only when winget is missing. winget is the primary manager and installs
    # Git and chezmoi below; Chocolatey is their fallback here. The packages template bootstraps
    # Chocolatey itself when a selected group needs it, so an unconditional bootstrap here only
    # cost a fresh machine a minute for nothing (2026-10-14 review).
    if (-not (Get-Command winget -ErrorAction SilentlyContinue) -and -not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Info "winget not found - installing Chocolatey as the fallback for Git and chezmoi..."
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        # -TimeoutSec so a stalled fetch errors out instead of hanging the run
        # (WebClient.DownloadString has no timeout of its own).
        $chocoInstall = Invoke-RestMethod -Uri 'https://community.chocolatey.org/install.ps1' -UseBasicParsing -TimeoutSec 120
        Invoke-ChocoBootstrap $chocoInstall
        Update-InstallerPath
        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            throw "Chocolatey installation failed."
        }
    }

    # 1. Git - first, because the source is cloned before anything else reads it.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Info "Git not found. Installing via winget (Chocolatey if winget is missing)..."
        try {
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                winget install --id Git.Git --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
            } else {
                choco install git -y --no-progress | Out-Host
            }
            Update-InstallerPath
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                 Start-Sleep -Seconds 2
                 if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                     throw "Git installation failed or PATH not updated."
                 }
            }
        } catch {
             Write-Fail "Failed to install Git. Please install manually."
             $script:InstallFailed = $true
             exit 1
        }
    }

    # 2. The source checkout, BEFORE chezmoi, the menu and the apply. Three reasons
    # (2026-10-14 fresh-install review):
    #   - the package menu (scripts/select-packages.ps1) is in the repo, so on a fresh one-liner
    #     run it was never found and the gum menu docs/package-groups.md promises never showed;
    #   - the chezmoi and gum pins (.chezmoi-version, .chezmoidata.yaml) are read from the
    #     checkout, so a fresh machine now gets the pinned versions instead of latest;
    #   - only this network step is retried. The old loop retried the whole
    #     `chezmoi init --apply`, so any late failure (the doctor's exit 1, a guardrail error)
    #     re-ran the entire package install - and its prompts - up to three times.
    # Unauthenticated https on purpose: the repo is public (tests/installer_url_credentials_contract.sh).
    $SourceDir = Join-Path $env:USERPROFILE '.local\share\chezmoi'
    $SourceUrl = 'https://github.com/CtrlCarlitos/dotfiles.git'
    # DOTFILES_BRANCH (default main) installs another branch - how a fix is tried on a fresh
    # machine before it is merged. install.sh's twin; an existing clone is switched only when asked.
    $SourceBranch = if ($env:DOTFILES_BRANCH) { $env:DOTFILES_BRANCH } else { 'main' }
    $LocalSource = (Test-Path "chezmoi.toml") -or (Test-Path ".chezmoi.toml.tmpl")

    # 5.1 promotes any line a native command writes to stderr into a terminating
    # NativeCommandError under $ErrorActionPreference = Stop - and git writes its
    # progress ("Cloning into...", FETCH_HEAD) to stderr. Drop EAP to Continue around
    # each git call; the exit code is the real signal.
    function Invoke-Git {
        param([string[]]$Arguments)
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            # stderr lines arrive as ErrorRecords; print their text (a blank one would
            # otherwise print as "System.Management.Automation.RemoteException").
            & git @Arguments 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } } | Out-Host
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        return ($global:LASTEXITCODE -eq 0)
    }

    if ($LocalSource) {
        Write-Info "Using the local checkout at $((Get-Location).Path)"
    } elseif (Test-Path (Join-Path $SourceDir '.git')) {
        # Repo exists: refresh it BEFORE applying. Confirmed live: a rerun
        # after a failed install silently reused the pre-fix clone, so
        # freshly-merged template fixes never reached the machine.
        # Fast-forward only - local commits/edits are respected; on failure
        # (offline, diverged) warn and continue with the existing source.
        Write-Info "Updating existing dotfiles clone..."
        # Read before the `if`: a `2>` inside an if condition is PSScriptAnalyzer's
        # PSPossibleIncorrectUsageOfRedirectionOperator (it fails CI's lint).
        $currentBranch = (& git -C $SourceDir rev-parse --abbrev-ref HEAD 2>$null)
        if ($env:DOTFILES_BRANCH -and $currentBranch -ne $SourceBranch) {
            # `git switch <b>` creates the local branch from origin/<b> on its own once fetched
            if (-not ((Invoke-Git @('-C', $SourceDir, 'fetch', 'origin', $SourceBranch)) -and (Invoke-Git @('-C', $SourceDir, 'switch', $SourceBranch)))) {
                Write-Info "  could not switch the clone to $SourceBranch (local changes?) - continuing on the current branch"
            }
        }
        if (-not (Invoke-Git @('-C', $SourceDir, 'pull', '--ff-only'))) {
            Write-Info "  clone update failed (offline? local changes?) - continuing with existing source"
        }
    } else {
        Write-Info "Cloning the dotfiles ($SourceBranch) into $SourceDir..."
        $cloned = $false
        for ($attempt = 1; $attempt -le 3 -and -not $cloned; $attempt++) {
            if (Test-Path $SourceDir) { Remove-Item -LiteralPath $SourceDir -Recurse -Force -ErrorAction SilentlyContinue }
            $cloned = Invoke-Git @('clone', '--branch', $SourceBranch, $SourceUrl, $SourceDir)
            if (-not $cloned -and $attempt -lt 3) {
                Write-Fail "clone failed (attempt $attempt of 3) - retrying in 5 seconds..."
                Start-Sleep -Seconds 5
            }
        }
        if (-not $cloned) {
            Write-Fail "Could not clone $SourceUrl after 3 attempts. Check the network and re-run the installer."
            $script:InstallFailed = $true
            exit 1
        }
    }
    $PinRoot = if ($LocalSource) { (Get-Location).Path } else { $SourceDir }

    # 3. chezmoi
    if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
        Write-Info "Chezmoi not found. Installing via winget (Chocolatey if winget is missing)..."
        # Pin coherence (#133): install the SAME chezmoi CI tests - the repo's
        # .chezmoi-version, now always on disk because the checkout comes first
        # (choco wants the bare semver, no leading v). If the pinned version is
        # missing from a repo (package lag), fall back to latest rather than fail.
        $chezmoiPin = $null
        $chezmoiPinFile = Join-Path $PinRoot '.chezmoi-version'
        if (Test-Path $chezmoiPinFile) {
            $chezmoiPin = ([IO.File]::ReadAllText($chezmoiPinFile)).Trim() -replace '^v', ''
        }
        try {
            # winget is the primary Windows manager (twpayne.chezmoi); `dot upgrade`'s winget sweep
            # then keeps chezmoi current. Chocolatey only where winget is missing.
            # chezmoi's winget package is "portable", which defaults to user scope - and `dot
            # upgrade` runs elevated, which cannot upgrade a user-scope copy ("installed for user
            # scope cannot be uninstalled when running with administrator privileges"; the same
            # reason gum's catalog entry carries --scope machine, .chezmoidata/packages.yaml).
            # Unconditional, not $IsAdmin-gated: the elevation gate above already guarantees admin
            # by the time execution reaches here.
            $wingetFlags = @('--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity', '--scope', 'machine')
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                if ($chezmoiPin) {
                    winget install --id twpayne.chezmoi --version $chezmoiPin @wingetFlags | Out-Host
                    if ($LASTEXITCODE -ne 0) {
                        Write-Fail "chezmoi $chezmoiPin not installable via winget - falling back to latest."
                        winget install --id twpayne.chezmoi @wingetFlags | Out-Host
                    }
                } else {
                    winget install --id twpayne.chezmoi @wingetFlags | Out-Host
                }
            } elseif ($chezmoiPin) {
                choco install chezmoi -y --no-progress --version $chezmoiPin | Out-Host
                if ($LASTEXITCODE -ne 0 -or -not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
                    Write-Fail "chezmoi $chezmoiPin not installable via Chocolatey (package lag?) - falling back to latest."
                    choco install chezmoi -y --no-progress | Out-Host
                }
            } else {
                choco install chezmoi -y --no-progress | Out-Host
            }
            Update-InstallerPath
            if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
                throw "Chezmoi installation failed or path not updated."
            }
        } catch {
            Write-Fail "Failed to install chezmoi: $_"
            Write-Host "Please install manually: winget install --id twpayne.chezmoi --exact"
            $script:InstallFailed = $true
            exit 1
        }
    }

    # 4. Interactive package menu - after the checkout (the script lives there) and
    # BEFORE `chezmoi init --apply`, so the selection lands in the config ahead of the
    # config template. The menu self-skips non-interactive or without gum; chezmoi's
    # native config prompts are always the fallback. Spawned as a child process because
    # select-packages.ps1 exits on completion and must not end this installer.
    # In devcontainers: skipped entirely (see $IsDevcontainer above).
    if (-not $IsDevcontainer) {
        # The gum pin from the checkout that now exists (the lookup at the top of this file
        # ran before the clone, so on a one-liner run it fell back to the inline pin).
        $gumYaml = Join-Path $PinRoot '.chezmoidata.yaml'
        if (Test-Path $gumYaml) {
            $gumMatch = Select-String -LiteralPath $gumYaml -Pattern '^\s{2}gum:\s*"?([^"]+)"?\s*$' | Select-Object -First 1
            if ($gumMatch) { $gumVersion = $gumMatch.Matches[0].Groups[1].Value }
        }
        Install-Gum
        $selectPackages = Join-Path $PinRoot 'scripts\select-packages.ps1'
        if (Test-Path $selectPackages) {
            try {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $selectPackages
                if ($LASTEXITCODE -ne 0) {
                    Write-Info "Package menu exited with $LASTEXITCODE - continuing with chezmoi config prompts."
                }
            } catch {
                Write-Info "Package menu could not run: $_ - continuing with chezmoi config prompts."
            }
        } else {
            Write-Info "Package menu script not found at $selectPackages - chezmoi config prompts will collect preferences."
        }
    } else {
        Write-Info "Devcontainer detected - skipping package menu (tools come from devcontainer-features)."
    }

    # 5. Apply - once. A failure here is reported, not retried: the apply is the whole package
    # install, and `chezmoi apply` (or `dot up`) resumes it - run_onchange records nothing on failure.
    Write-Info "Applying dotfiles..."
    if ($LocalSource) {
        chezmoi init --apply --source .
    } else {
        chezmoi init --apply
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "chezmoi init --apply failed (exit code $LASTEXITCODE). Scroll up for the first error, fix it, then re-run from an Administrator terminal: chezmoi apply"
        $script:InstallFailed = $true
        exit 1
    }

    Write-Success "Done!"
    Write-Info "----------------------------------------------------------------"
    # One restart notice for everything the apply enabled (WSL and Virtual Machine Platform,
    # WHPX, Docker Desktop) - the same three sources Chocolatey reads. Scattered per-step lines
    # were easy to miss in an hour of output (2026-10-14).
    $restartPending = $false
    try {
        $restartPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
            [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
    } catch { $restartPending = $false }
    if ($restartPending) {
        Write-Host "[!] RESTART WINDOWS NOW - features enabled by this install (WSL, Virtual Machine Platform, WHPX) finish only after a restart." -ForegroundColor Yellow
    }
    Write-Info "Next:"
    Write-Info "1. Open a NEW Administrator terminal (this one has a stale PATH and no profile)."
    # The guardrail hook Claude Code runs before every tool call needs Git Bash, which a session
    # started before Git was installed cannot find: every tool call was blocked until Claude Code
    # was restarted (2026-10-14).
    Write-Info "2. Restart any running agent (Claude Code, Codex, OpenCode, agy) - their hooks need the new PATH."
    if (Test-Path (Join-Path $env:USERPROFILE '.local\bin\guardrail.exe')) {
        Write-Info "3. Run 'guardrail setup' to enroll yourself - the install armed the agent planes without asking anyone."
    }
    Write-Info "Customize: edit $env:USERPROFILE\.config\chezmoi\chezmoi.toml (examples in $SourceDir\docs\), then run 'dot up'."
    Write-Info "----------------------------------------------------------------"
    # No profile reload here: dot-sourcing $PROFILE inside this script block defined nothing in the
    # caller's session, and `exit` below ends it anyway - the new terminal is what loads it.

} finally {
    # [Environment]::UserInteractive reflects the window station, not whether stdin is
    # actually attached to a human - it can report true in a CI runner with no one
    # present. Also guard on $IsNonInteractive so this can't hang the same way.
    if ([Environment]::UserInteractive -and -not $IsNonInteractive) {
        Write-Host ""
        if ($script:InstallFailed) {
            Write-Host "[!] Installation FAILED - scroll up for the error." -ForegroundColor Red
            Read-Host "Press Enter to close this window"
        } else {
            Read-Host "Press Enter to exit..."
        }
    }
    if ($InstallLogOpen) { try { Stop-Transcript | Out-Null } catch { $null = $_ } }
}

# Every real failure above exits 1 explicitly; reaching here means success.
exit 0
