# PowerShell One-Liner Installer for Chezmoi Dotfiles
# Usage: iex "& {$(irm https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1)}"

$ErrorActionPreference = "Stop"

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
function Bootstrap-Gum {
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
# package menu entirely — the non-interactive path renders all groups false
# (config-only apply), and downloading gum just to have the menu self-skip
# wastes bandwidth on every container start. Tools in devcontainers come
# from devcontainer-features during image build, not from here.
$IsDevcontainer = ($env:DEVCONTAINER -eq 'true') -or ($env:REMOTE_CONTAINERS -eq 'true')

# 0.1 Consent - ask before touching anything. Non-interactive environments
# (matched above) auto-proceed without prompting.
if (-not $IsNonInteractive) {
    $proceed = Read-Host "This installer installs Chocolatey packages, chezmoi, and applies the CtrlCarlitos dotfiles. Proceed? (Y/n)"
    if ($proceed -eq 'n') {
        Write-Info "Aborted - nothing was installed. Re-run any time."
        exit 0
    }
}

if (-not $IsAdmin) {
    Write-Info "Running without Administrator privileges."
    if ($IsNonInteractive) {
        Write-Info "Non-interactive environment detected - continuing as standard user without prompting."
    } else {
        $response = Read-Host "Administrator rights are recommended for full installation (Chocolatey, etc). Restart as Admin? (Y/n)"
        if ($response -ne 'n') {
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
        } else {
            Write-Info "Continuing as standard user. Some features (Chocolatey) will be skipped."
        }
    }
}

try {
    # 0.5 Install Chocolatey if missing (Required for everything else)
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Info "Chocolatey not found. Installing..."
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        # -TimeoutSec so a stalled fetch errors out instead of hanging the run
        # (WebClient.DownloadString has no timeout of its own).
        $chocoInstall = Invoke-RestMethod -Uri 'https://community.chocolatey.org/install.ps1' -UseBasicParsing -TimeoutSec 120
        Invoke-Expression $chocoInstall
        
        # Refresh env path logic
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        
        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            throw "Chocolatey installation failed."
        }
    }

    # 0.7 Interactive package menu - runs BEFORE `chezmoi init --apply` so the
    # selection lands in the config ahead of the config template. The menu
    # self-skips non-interactive or without gum; chezmoi's native config
    # prompts are always the fallback. Spawned as a child process because
    # select-packages.ps1 exits on completion and must not end this installer.
    # In devcontainers: skipped entirely (see $IsDevcontainer above).
    if (-not $IsDevcontainer) {
        Bootstrap-Gum
        $selectPackages = $null
        if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'scripts\select-packages.ps1'))) {
            $selectPackages = Join-Path $PSScriptRoot 'scripts\select-packages.ps1'
        } elseif (Test-Path '.\scripts\select-packages.ps1') {
            $selectPackages = (Resolve-Path '.\scripts\select-packages.ps1').Path
        } elseif (Test-Path "$env:USERPROFILE/.local/share/chezmoi/scripts/select-packages.ps1") {
            $selectPackages = "$env:USERPROFILE/.local/share/chezmoi/scripts/select-packages.ps1"
        }
        if ($selectPackages) {
            try {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $selectPackages
                if ($LASTEXITCODE -ne 0) {
                    Write-Info "Package menu exited with $LASTEXITCODE - continuing with chezmoi config prompts."
                }
            } catch {
                Write-Info "Package menu could not run: $_ - continuing with chezmoi config prompts."
            }
        } else {
            Write-Info "Package menu script not found (fresh one-liner install) - chezmoi config prompts will collect preferences."
        }
    } else {
        Write-Info "Devcontainer detected - skipping package menu (tools come from devcontainer-features)."
    }

    # 1. Install Chezmoi if missing
    if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
        Write-Info "Chezmoi not found. Installing via Chocolatey..."
        try {
            choco install chezmoi -y --no-progress
            # Refresh env path for current session
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
                throw "Chezmoi installation failed or path not updated."
            }
        } catch {
            Write-Fail "Failed to install chezmoi: $_"
            Write-Host "Please install manually: choco install chezmoi -y"
            exit 1
        }
    }

    # 1.5 Ensure Git is installed (Required for chezmoi init)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Info "Git not found. Installing via Chocolatey..."
        try {
            choco install git -y --no-progress
            # Refresh path to find git
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                 Start-Sleep -Seconds 2
                 if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                     throw "Git installation failed or PATH not updated."
                 }
            }
        } catch {
             Write-Fail "Failed to install Git. Please install manually."
             exit 1
        }
    }

    # 2. Initialize & Apply
    Write-Info "Applying dotfiles..."

    function Invoke-ChezmoiWithRetry {
        param([scriptblock]$Command)
        $max_attempts = 3
        $delay = 5
        $attempt = 1
        
        while ($attempt -le $max_attempts) {
            & $Command
            if ($global:LASTEXITCODE -eq 0) {
                return
            }
            
            Write-Fail "chezmoi operation failed (exit code $($global:LASTEXITCODE)). Attempt $attempt of $max_attempts."
            if ($attempt -lt $max_attempts) {
                Write-Info "Waiting $delay seconds before retrying..."
                Start-Sleep -Seconds $delay
            }
            $attempt++
        }
        
        throw "Chezmoi installation failed after $max_attempts attempts."
    }

    if (Test-Path "$env:USERPROFILE/.local/share/chezmoi/.git") {
        # Repo exists: refresh it BEFORE applying. Confirmed live: a rerun
        # after a failed install silently reused the pre-fix clone (no
        # "Cloning into..." line), so freshly-merged template fixes never
        # reached the machine and the identical failure replayed all 3
        # retries. `chezmoi init --apply` alone does not pull. Fast-forward
        # only - local commits/edits are respected; on failure (offline,
        # diverged) warn and continue with the existing source.
        Write-Info "Updating existing dotfiles clone..."
        # 5.1 promotes any line a redirected native command writes to stderr
        # into a terminating NativeCommandError under $ErrorActionPreference
        # = Stop - and `git pull` writes its FETCH_HEAD progress to stderr
        # exactly when there is something to fetch, so the 2>$null alone does
        # NOT save the rerun path (same class as the extension loop in
        # run_onchange_install_packages.ps1.tmpl). Drop EAP to Continue
        # around the call; the exit code below is the real signal.
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            git -C "$env:USERPROFILE/.local/share/chezmoi" pull --ff-only 2>$null
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Info "  clone update failed (offline? local changes?) - continuing with existing source"
        }
        # Run init (to ensure config exists/generates) and then apply
        Invoke-ChezmoiWithRetry { chezmoi init --apply }
    } else {
        # Check if running locally (e.g. cloned repo)
        if ((Test-Path "chezmoi.toml") -or (Test-Path ".chezmoi.toml.tmpl")) {
            Invoke-ChezmoiWithRetry { chezmoi init --apply --source . }
        } else {
            # Remote install (use PAT if available)
            if ($env:PAT) {
                $srcDir = "$env:USERPROFILE/.local/share/chezmoi"
                # low-speed config aborts a stalled clone (<1KB/s for 60s)
                git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 clone "https://$($env:PAT)@github.com/CtrlCarlitos/dotfiles.git" $srcDir
                Invoke-ChezmoiWithRetry { chezmoi init --apply --source $srcDir }
            } else {
                Invoke-ChezmoiWithRetry { chezmoi init --apply --branch main CtrlCarlitos/dotfiles }
            }
        }
    }

    Write-Success "Done! Restart your terminal to see changes."
    Write-Info "----------------------------------------------------------------"
    Write-Info "To customize your setup (add accounts, toggle features):"
    Write-Info "1. Edit $env:USERPROFILE\.config\chezmoi\chezmoi.toml"
    Write-Info "2. Reference examples in $env:USERPROFILE\.local\share\chezmoi\docs\"
    Write-Info "3. Run 'chezmoi apply'"
    Write-Info "----------------------------------------------------------------"

    # Reload profile for immediate effect (Parity with 'exec zsh')
    if (Test-Path $PROFILE) {
        Write-Info "Reloading PowerShell profile..."
        # Cosmetic only (parity with 'exec zsh'). The profile may reference tools
        # that are not on PATH in this session yet (CI runners, first install), and
        # $ErrorActionPreference = Stop would turn that into a failed install after
        # everything real has already succeeded - so never let the reload be fatal.
        try {
            . $PROFILE
        } catch {
            Write-Host "[!] Profile reload skipped (a new terminal will load it): $_" -ForegroundColor Yellow
        }
        # A native tool the profile invokes (starship/zoxide/direnv init) can leave
        # $LASTEXITCODE non-zero without throwing; GitHub Actions then fails the
        # step even though the install succeeded. The install's own result is
        # what matters here, so clear it.
        $global:LASTEXITCODE = 0
    }

} finally {
    # [Environment]::UserInteractive reflects the window station, not whether stdin is
    # actually attached to a human - it can report true in a CI runner with no one
    # present. Also guard on $IsNonInteractive so this can't hang the same way.
    if ([Environment]::UserInteractive -and -not $IsNonInteractive) {
        Write-Host ""
        Read-Host "Press Enter to exit..."
    }
}

# Every real failure above exits 1 explicitly; reaching here means success.
exit 0
