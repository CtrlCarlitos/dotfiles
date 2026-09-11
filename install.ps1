# PowerShell One-Liner Installer for Chezmoi Dotfiles
# Usage: iex "& {$(irm https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1)}"

$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Message) Write-Host "[:] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[v] $Message" -ForegroundColor Green }
function Write-Error { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Red }

# 0. Setup
$InstallerUrl = "https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1"
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# CI matches the convention already used in .chezmoi.toml.tmpl for the same purpose
# (GitHub Actions, and most CI systems generally, set CI=true). CHEZMOI_TEST_MINIMAL
# is the flag ci.yml's own tests set explicitly for this exact scenario. Without this
# check, Read-Host below blocks forever with no error and no timeout in a runner with
# no real stdin - confirmed live: a Windows Installer Test run hung 40+ minutes here.
$IsNonInteractive = ($env:CI -eq 'true') -or ($env:CHEZMOI_TEST_MINIMAL -eq 'true')

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
            Write-Error "Failed to install chezmoi: $_"
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
             Write-Error "Failed to install Git. Please install manually."
             exit 1
        }
    }

    # 1.6 Install Modern Tools (Chocolatey)
    Write-Info "Installing modern tools (Starship, Zoxide, Direnv, etc)..."
    $modernTools = @("starship", "zoxide", "direnv", "lazygit", "bat", "eza", "fd", "gsudo", "powertoys")
    foreach ($tool in $modernTools) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
             try {
                 choco install $tool -y --no-progress
             } catch {
                 Write-Error "Failed to install $tool (might be already installed or error)"
             }
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
            
            Write-Error "chezmoi operation failed (exit code $($global:LASTEXITCODE)). Attempt $attempt of $max_attempts."
            if ($attempt -lt $max_attempts) {
                Write-Info "Waiting $delay seconds before retrying..."
                Start-Sleep -Seconds $delay
            }
            $attempt++
        }
        
        throw "Chezmoi installation failed after $max_attempts attempts."
    }

    if (Test-Path "$env:USERPROFILE/.local/share/chezmoi/.git") {
        # Repo exists: Run init (to ensure config exists/generates) and then apply
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
