<#
.SYNOPSIS
    Git Identity Manager - Manage multiple Git identities for different accounts
.DESCRIPTION
    Commands:
        devprofile              Show current repo's git identity
        devprofile list         List configured accounts and SSH keys
        devprofile use [NAME]   Set git identity for current repo
        devprofile init NAME EMAIL  Create new account with keys
        devprofile verify       Check if identity is configured correctly
        devprofile verify -InstallHook  Install pre-commit hook
        devprofile help         Show help
#>

param(
    [Parameter(Position=0)]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$Arg1,

    [Parameter(Position=2)]
    [string]$Arg2,

    [switch]$InstallHook,

    [switch]$Passphrase,

    [switch]$NoPassphrase,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$Version = "2.0.0"
$SshDir = Join-Path $env:USERPROFILE ".ssh"
$ChezmoiConfig = Join-Path $env:USERPROFILE ".config\chezmoi\chezmoi.toml"

function Write-Info { param([string]$Message) Write-Host "▸ $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "✓ $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "! $Message" -ForegroundColor Yellow }
function Write-Err { param([string]$Message) Write-Host "✗ $Message" -ForegroundColor Red }

#-------------------------------------------------------------------------------
# HELP
#-------------------------------------------------------------------------------
function Show-Help {
    @"
devprofile - Git Identity Manager

USAGE:
    devprofile [COMMAND] [OPTIONS]

COMMANDS:
    (none)          Show current repository's git identity
    list            List all configured accounts and SSH keys
    use [NAME]      Set git identity for current repository
                    Interactive selection if NAME not provided
    init NAME EMAIL [-Passphrase|-NoPassphrase]
                    Create new account with auth and signing keys
    verify          Check if current repo has correct identity
    verify -InstallHook
                    Install pre-commit hook to verify identity
    help            Show this help message

EXAMPLES:
    devprofile                      # Show current identity
    devprofile list                 # List all accounts
    devprofile use CtrlCarlitos     # Set identity for this repo
    devprofile use                  # Interactive selection
    devprofile init work work@co.com # Create new account
    devprofile init work work@co.com -Passphrase # Create with passphrases
    devprofile verify               # Check identity config

NOTES:
    - Accounts are configured in ~/.config/chezmoi/chezmoi.toml
    - SSH keys are stored in ~/.ssh/id_<name> and id_<name>_sign
    - Set DEVPROFILE_PASSPHRASE=1 to always prompt for passphrases
    - Use 'chezmoi apply' after modifying chezmoi.toml
"@
}

#-------------------------------------------------------------------------------
# PARSE CHEZMOI CONFIG
#-------------------------------------------------------------------------------
function Get-Accounts {
    if (Get-Command chezmoi -ErrorAction SilentlyContinue) {
        try {
            $jsonLines = & chezmoi data --format=json 2>$null
            if ($LASTEXITCODE -eq 0 -and $jsonLines) {
                $json = $jsonLines -join "`n"
                $data = $json | ConvertFrom-Json
                if ($data -and $data.accounts) {
                    return $data.accounts
                }
            }
        } catch { Write-Warn "chezmoi data failed, falling back to chezmoi.toml: $($_.Exception.Message)" }
    }

    if (-not (Test-Path $ChezmoiConfig)) { return @() }
    
    $accounts = @()
    $current = @{}
    $inAccount = $false
    
    foreach ($line in Get-Content $ChezmoiConfig) {
        if ($line -match '^\[\[data\.accounts\]\]') {
            if ($current.Count -gt 0 -and $current.username) {
                $accounts += [PSCustomObject]$current
            }
            $current = @{}
            $inAccount = $true
        }
        elseif ($inAccount) {
            if ($line -match '^\s*name\s*=\s*"([^"]+)"') { $current.name = $Matches[1] }
            elseif ($line -match '^\s*email\s*=\s*"([^"]+)"') { $current.email = $Matches[1] }
            elseif ($line -match '^\s*username\s*=\s*"([^"]+)"') { $current.username = $Matches[1] }
            elseif ($line -match '^\s*key\s*=\s*"([^"]+)"') { $current.key = $Matches[1] }
            elseif ($line -match '^\s*signingKey\s*=\s*"([^"]+)"') { $current.signingKey = $Matches[1] }
            elseif ($line -match '^\s*provider\s*=\s*"([^"]+)"') { $current.provider = $Matches[1] }
            elseif ($line -match '^\s*dirs\s*=\s*\[(.*)\]') {
                # dirs = ["a/b", "c"] -> @("a/b", "c"); an empty array yields @()
                $current.dirs = @([regex]::Matches($Matches[1], '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
            }
        }
    }
    
    if ($current.Count -gt 0 -and $current.username) {
        $accounts += [PSCustomObject]$current
    }
    
    return $accounts
}

#-------------------------------------------------------------------------------
# SHOW CURRENT IDENTITY
#-------------------------------------------------------------------------------
function Show-Current {
    Write-Host ""
    
    $name = $null
    $email = $null
    $signingkey = $null
    $source = "global"
    
    $isRepo = $false
    try { 
        git rev-parse --git-dir 2>$null | Out-Null
        $isRepo = $LASTEXITCODE -eq 0
    } catch { Write-Warn "git rev-parse --git-dir failed: $($_.Exception.Message)" }
    
    if ($isRepo) {
        # In a git repo - get effective identity
        $name = git config user.name 2>$null
        $email = git config user.email 2>$null
        $signingkey = git config user.signingkey 2>$null
        
        # Determine source (local or inherited)
        $localEmail = git config --local user.email 2>$null
        if ($localEmail) {
            $source = "repo-local"
        } else {
            $source = "inherited from global"
        }
    } else {
        # Not in git repo - show global
        $name = git config --global user.name 2>$null
        $email = git config --global user.email 2>$null
        $signingkey = git config --global user.signingkey 2>$null
    }
    
    if ($name -and $email) {
        Write-Success "Current identity ($source):"
        Write-Host ""
        
        # Boxed format with row headings
        Write-Host "  ┌──────────┬────────────────────────────────────────────┐"
        Write-Host ("  │ {0,-8} │ {1,-42} │" -f "Name", $name) -ForegroundColor Cyan -NoNewline
        Write-Host ""
        Write-Host "  ├──────────┼────────────────────────────────────────────┤"
        Write-Host ("  │ {0,-8} │ {1,-42} │" -f "Email", $email) -ForegroundColor Cyan -NoNewline
        Write-Host ""
        if ($signingkey) {
            Write-Host "  ├──────────┼────────────────────────────────────────────┤"
            $shortkey = $signingkey -replace [regex]::Escape($env:USERPROFILE), '~'
            if ($shortkey.Length -gt 42) { $shortkey = $shortkey.Substring(0, 40) + ".." }
            Write-Host ("  │ {0,-8} │ {1,-42} │" -f "Key", $shortkey) -ForegroundColor Cyan -NoNewline
            Write-Host ""
        }
        Write-Host "  └──────────┴────────────────────────────────────────────┘"
        Write-Host ""
        
        $accounts = Get-Accounts
        $match = $accounts | Where-Object { $_.email -eq $email }
        if ($match) {
            Write-Success "Email matches a configured account"
        } else {
            Write-Warn "Email does not match any configured account"
        }
    } else {
        Write-Warn "No git identity configured"
        Write-Host ""
        Write-Host "Run: devprofile use <account-name>"
    }
    Write-Host ""
}

#-------------------------------------------------------------------------------
# LIST ACCOUNTS
#-------------------------------------------------------------------------------
function Show-List {
    Write-Host ""
    
    $accounts = Get-Accounts
    
    if ($accounts.Count -eq 0) {
        Write-Warn "No accounts configured in chezmoi.toml"
        Write-Host ""
        Write-Host "Add accounts with: devprofile init <username> <email>"
        Write-Host ""
        return
    }
    
    Write-Info "Configured Accounts ($($accounts.Count) total):"
    Write-Host ""
    
    # Table with box-drawing characters
    Write-Host "  ┌────────────────────┬────────────────────────┬──────────────────────────────┬──────────┐"
    Write-Host ("  │ {0,-18} │ {1,-22} │ {2,-28} │ {3,-8} │" -f "USERNAME", "NAME", "EMAIL", "PROVIDER") -ForegroundColor Cyan
    Write-Host "  ├────────────────────┼────────────────────────┼──────────────────────────────┼──────────┤"
    
    foreach ($acc in $accounts) {
        $name = $acc.name
        $email = $acc.email
        $provider = if ($acc.provider) { $acc.provider } else { "github" }
        
        # Truncate long values
        if ($name.Length -gt 22) { $name = $name.Substring(0, 20) + ".." }
        if ($email.Length -gt 28) { $email = $email.Substring(0, 26) + ".." }
        
        Write-Host ("  │ {0,-18} │ {1,-22} │ {2,-28} │ {3,-8} │" -f $acc.username, $name, $email, $provider)
    }
    
    Write-Host "  └────────────────────┴────────────────────────┴──────────────────────────────┴──────────┘"
    Write-Host ""
    
    # SSH Keys section
    Write-Info "SSH Keys:"
    Write-Host ""
    Write-Host "  ┌──────────────────────────┬────────────┬────────────────┐"
    Write-Host ("  │ {0,-24} │ {1,-10} │ {2,-14} │" -f "KEY FILE", "TYPE", "STATUS") -ForegroundColor Cyan
    Write-Host "  ├──────────────────────────┼────────────┼────────────────┤"
    
    $keys = Get-ChildItem "$SshDir\id_*" -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".pub" }
    if ($keys) {
        foreach ($key in $keys) {
            $keyname = $key.Name
            $keytype = if ($keyname -match "_sign$") { "signing" } else { "auth" }
            $statusIcon = "✓"
            $statusText = "ok"
            
            if (-not (Test-Path "$($key.FullName).pub")) {
                $statusIcon = "!"
                $statusText = "no .pub"
            }
            
            # Check if key is used by any account
            foreach ($acc in $accounts) {
                if ($acc.key -and ($keyname -eq $acc.key -or $keyname -eq "$($acc.key)_sign")) {
                    $statusText = "in use"
                }
            }
            
            Write-Host ("  │ {0,-24} │ {1,-10} │ {2} {3,-12} │" -f $keyname, $keytype, $statusIcon, $statusText)
        }
        Write-Host "  └──────────────────────────┴────────────┴────────────────┘"
    } else {
        Write-Host ("  │ {0,-24} │ {1,-10} │ {2,-14} │" -f "(no keys found)", "-", "-")
        Write-Host "  └──────────────────────────┴────────────┴────────────────┘"
    }
    Write-Host ""
}

#-------------------------------------------------------------------------------
# USE ACCOUNT
#-------------------------------------------------------------------------------
function Use-Account {
    param([string]$AccountName)
    
    try { git rev-parse --git-dir 2>$null | Out-Null } catch { Write-Warn "git rev-parse --git-dir failed: $($_.Exception.Message)" }
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Not in a git repository"
        exit 1
    }
    
    $accounts = Get-Accounts
    if ($accounts.Count -eq 0) {
        Write-Err "No accounts configured"
        exit 1
    }
    
    if (-not $AccountName) {
        Write-Host ""
        Write-Info "Select account for this repository:"
        Write-Host ""
        
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            $acc = $accounts[$i]
            Write-Host ("  {0}) {1} - {2} <{3}>" -f ($i+1), $acc.username, $acc.name, $acc.email) -ForegroundColor Cyan
        }
        Write-Host ""
        
        $choice = Read-Host "Choice [1]"
        if (-not $choice) { $choice = "1" }
        
        $idx = [int]$choice - 1
        if ($idx -lt 0 -or $idx -ge $accounts.Count) {
            Write-Err "Invalid selection"
            exit 1
        }
        
        $selected = $accounts[$idx]
    } else {
        $selected = $accounts | Where-Object { $_.username -eq $AccountName }
        if (-not $selected) {
            Write-Err "Account not found: $AccountName"
            Write-Host "Run 'devprofile list' to see available accounts"
            exit 1
        }
    }
    
    # Prefer the account's dedicated signing key over the auth key, same as
    # dot_gitconfig.tmpl / run_onchange_generate_identities - falls back to the
    # auth key only if no signingKey is configured for this account.
    $signKeyName = if ($selected.signingKey) { $selected.signingKey } else { $selected.key }

    git config user.name $selected.name
    git config user.email $selected.email
    if ($selected.key) {
        $keyPath = Join-Path $SshDir "$signKeyName.pub"
        git config user.signingkey $keyPath
        git config commit.gpgsign true
        git config gpg.format ssh
    }

    Write-Host ""
    Write-Success "Configured identity for this repo: $($selected.username)"
    Write-Host ""

    # Boxed format with row headings
    Write-Host "  ┌──────────┬────────────────────────────────────────────┐"
    Write-Host ("  │ {0,-8} │ {1,-42} │" -f "Name", $selected.name) -ForegroundColor Cyan -NoNewline
    Write-Host ""
    Write-Host "  ├──────────┼────────────────────────────────────────────┤"
    Write-Host ("  │ {0,-8} │ {1,-42} │" -f "Email", $selected.email) -ForegroundColor Cyan -NoNewline
    Write-Host ""
    if ($selected.key) {
        Write-Host "  ├──────────┼────────────────────────────────────────────┤"
        Write-Host ("  │ {0,-8} │ {1,-42} │" -f "Key", "~/.ssh/$($selected.key)") -ForegroundColor Cyan -NoNewline
        Write-Host ""
        Write-Host "  ├──────────┼────────────────────────────────────────────┤"
        Write-Host ("  │ {0,-8} │ {1,-42} │" -f "Signing", "~/.ssh/$signKeyName") -ForegroundColor Cyan -NoNewline
        Write-Host ""
    }
    Write-Host "  └──────────┴────────────────────────────────────────────┘"
    Write-Host ""
}

#-------------------------------------------------------------------------------
# INIT NEW ACCOUNT
#-------------------------------------------------------------------------------
function Initialize-Account {
    param(
        [string]$Name,
        [string]$Email,
        [switch]$PassphraseFlag,
        [switch]$NoPassphraseFlag,
        [string[]]$ExtraArgs
    )
    
    if (-not $Name -or -not $Email) {
        Write-Err "Usage: devprofile init NAME EMAIL [-Passphrase|-NoPassphrase]"
        exit 1
    }

    $passphraseMode = "ask"
    if ($PassphraseFlag) { $passphraseMode = "prompt" }
    if ($NoPassphraseFlag) { $passphraseMode = "none" }

    foreach ($arg in ($ExtraArgs | Where-Object { $_ })) {
        if ($arg -eq "--passphrase") { $passphraseMode = "prompt" }
        elseif ($arg -eq "--no-passphrase") { $passphraseMode = "none" }
    }

    if ($env:DEVPROFILE_PASSPHRASE) {
        switch ($env:DEVPROFILE_PASSPHRASE.ToLower()) {
            "1" { $passphraseMode = "prompt" }
            "true" { $passphraseMode = "prompt" }
            "yes" { $passphraseMode = "prompt" }
            "0" { $passphraseMode = "none" }
            "false" { $passphraseMode = "none" }
            "no" { $passphraseMode = "none" }
        }
    }

    if ($passphraseMode -eq "ask") {
        if ([Environment]::UserInteractive) {
            $resp = Read-Host "Use passphrase for SSH keys? [y/N] (recommended)"
            if ($resp -match '^[Yy]') { $passphraseMode = "prompt" } else { $passphraseMode = "none" }
        } else {
            $passphraseMode = "none"
        }
    }
    
    if (-not (Test-Path $SshDir)) { New-Item -ItemType Directory -Path $SshDir -Force | Out-Null }
    
    $authKey = Join-Path $SshDir "id_$Name"
    $signKey = Join-Path $SshDir "id_${Name}_sign"
    
    Write-Host ""
    Write-Info "Creating account: $Name <$Email>"
    Write-Host ""
    
    if (Test-Path $authKey) {
        Write-Warn "Auth key already exists: $authKey"
    } else {
        Write-Info "Generating authentication key..."
        if ($passphraseMode -eq "none") {
            ssh-keygen -t ed25519 -f $authKey -C $Email -N ""
        } else {
            ssh-keygen -t ed25519 -f $authKey -C $Email
        }
        if ($LASTEXITCODE -eq 0) { Write-Success "Created: $authKey" }
    }
    
    if (Test-Path $signKey) {
        Write-Warn "Signing key already exists: $signKey"
    } else {
        Write-Info "Generating signing key..."
        # Comment is "<email>-sign", not "signing-<name>" - allowed_signers
        # generation parses this to recover the email when scanning ~/.ssh for
        # keys it doesn't already know about via chezmoi.toml (see
        # run_onchange_generate_identities.ps1.tmpl); an unparseable comment
        # means that key silently never gets trusted for verification.
        if ($passphraseMode -eq "none") {
            ssh-keygen -t ed25519 -f $signKey -C "${Email}-sign" -N ""
        } else {
            ssh-keygen -t ed25519 -f $signKey -C "${Email}-sign"
        }
        if ($LASTEXITCODE -eq 0) { Write-Success "Created: $signKey" }
    }
    
    Write-Host ""
    Write-Host "Public keys:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Authentication key (add to GitHub/GitLab as Authentication Key):" -ForegroundColor Cyan
    Get-Content "$authKey.pub"
    Write-Host ""
    Write-Host "Signing key (add to GitHub/GitLab as Signing Key):" -ForegroundColor Cyan
    Get-Content "$signKey.pub"
    Write-Host ""
    
    Write-Info "Next steps:"
    Write-Host "  1. Add keys to your Git provider (GitHub, GitLab, etc.)"
    Write-Host "  2. Add account to ~/.config/chezmoi/chezmoi.toml:"
    Write-Host ""
    Write-Host "     [[data.accounts]]"
    Write-Host "       name = `"Your Name`""
    Write-Host "       email = `"$Email`""
    Write-Host "       username = `"$Name`""
    Write-Host "       provider = `"github`""
    Write-Host "       key = `"id_$Name`""
    Write-Host "       signingKey = `"id_${Name}_sign`""
    Write-Host "       dirs = [`"projects/$Name`"]"
    Write-Host ""
    Write-Host "  3. Run 'chezmoi apply' to update git config"
    Write-Host ""
}

#-------------------------------------------------------------------------------
# VERIFY IDENTITY
#-------------------------------------------------------------------------------
function Test-Identity {
    param([switch]$InstallHookFlag)
    
    try { git rev-parse --git-dir 2>$null | Out-Null } catch { Write-Warn "git rev-parse --git-dir failed: $($_.Exception.Message)" }
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Not in a git repository"
        exit 1
    }
    
    Write-Host ""
    $name = git config user.name 2>$null
    $email = git config user.email 2>$null
    $signingkey = git config user.signingkey 2>$null
    
    $issues = 0
    $identityStatus = ""
    $identityIcon = "✓"
    $keyStatus = ""
    $keyIcon = "▸"
    $accountStatus = ""
    $accountIcon = "▸"
    
    # Check identity
    if (-not $name -or -not $email) {
        $identityStatus = "Not configured"
        $identityIcon = "✗"
        $issues++
    } else {
        $identityStatus = "$name <$email>"
        $identityIcon = "✓"
    }
    
    # Check signing key
    if ($signingkey) {
        if ($signingkey -like "ssh-*") {
            $keyStatus = "Inline public key"
            $keyIcon = "✓"
        } else {
            $keyPath = $signingkey -replace '\.pub$', ''
            if ((Test-Path $keyPath) -or (Test-Path $signingkey)) {
                $shortkey = $signingkey -replace [regex]::Escape($env:USERPROFILE), '~'
                $keyStatus = $shortkey
                $keyIcon = "✓"
            } else {
                $keyStatus = "File not found"
                $keyIcon = "!"
                $issues++
            }
        }
    } else {
        $keyStatus = "Not configured (optional)"
        $keyIcon = "▸"
    }
    
    # Check if email matches known account
    $accounts = Get-Accounts
    if ($email) {
        $match = $accounts | Where-Object { $_.email -eq $email }
        if ($match) {
            $accountStatus = "Email matches configured account"
            $accountIcon = "✓"
        } else {
            $accountStatus = "Email not in config"
            $accountIcon = "!"
        }
    } else {
        $accountStatus = "No config to check"
        $accountIcon = "▸"
    }

    # Check whether the active identity is the one this directory is actually
    # mapped to (via each account's `dirs` list) - catches the case where a
    # repo-local override (`devprofile use`) was set while sitting in the wrong
    # repo, or a repo was cloned/moved under the wrong account's directory.
    $dirStatus = ""
    $dirIcon = "▸"
    $repoRoot = $null
    try { $repoRoot = (git rev-parse --show-toplevel 2>$null) } catch { Write-Warn "git rev-parse --show-toplevel failed: $($_.Exception.Message)" }

    if (-not $repoRoot) {
        $dirStatus = "Could not resolve repo path"
        $dirIcon = "▸"
    } else {
        $repoRootNorm = ($repoRoot.Trim() -replace '\\', '/')
        $homeNorm = (($env:USERPROFILE) -replace '\\', '/').TrimEnd('/')
        if ($repoRootNorm -notlike "$homeNorm/*") {
            $dirStatus = "Repo outside home dir - no mapping to check"
            $dirIcon = "▸"
        } elseif ($accounts.Count -eq 0) {
            $dirStatus = "No account config to check against"
            $dirIcon = "▸"
        } else {
            $relpath = $repoRootNorm.Substring($homeNorm.Length + 1)
            $bestIdx = -1
            $bestLen = -1
            for ($i = 0; $i -lt $accounts.Count; $i++) {
                foreach ($d in $accounts[$i].dirs) {
                    if (-not $d) { continue }
                    if ($relpath -eq $d -or $relpath -like "$d/*") {
                        if ($d.Length -gt $bestLen) { $bestLen = $d.Length; $bestIdx = $i }
                    }
                }
            }
            if ($bestIdx -ge 0) {
                $expectedEmail = $accounts[$bestIdx].email
                $expectedUsername = $accounts[$bestIdx].username
                if (-not $email) {
                    $dirStatus = "Expected $expectedUsername ($expectedEmail) - no identity set"
                    $dirIcon = "!"
                    $issues++
                } elseif ($email -eq $expectedEmail) {
                    $dirStatus = "Matches $expectedUsername (dirs mapping)"
                    $dirIcon = "✓"
                } else {
                    $dirStatus = "Expected $expectedUsername ($expectedEmail), signing as $email"
                    $dirIcon = "✗"
                    $issues++
                }
            } else {
                $dirStatus = "No account's dirs list covers this path"
                $dirIcon = "▸"
            }
        }
    }

    # Display boxed results
    Write-Info "Identity Verification:"
    Write-Host ""
    
    # Truncate if too long
    $displayIdentity = $identityStatus
    if ($displayIdentity.Length -gt 40) { $displayIdentity = $displayIdentity.Substring(0, 38) + ".." }
    
    Write-Host "  ┌──────────┬──────────────────────────────────────────┬───┐"
    Write-Host ("  │ {0,-8} │ {1,-40} │ {2} │" -f "Identity", $displayIdentity, $identityIcon) -ForegroundColor Cyan -NoNewline
    Write-Host ""
    Write-Host "  ├──────────┼──────────────────────────────────────────┼───┤"
    
    $displayKey = $keyStatus
    if ($displayKey.Length -gt 40) { $displayKey = $displayKey.Substring(0, 38) + ".." }
    Write-Host ("  │ {0,-8} │ {1,-40} │ {2} │" -f "Key", $displayKey, $keyIcon) -ForegroundColor Cyan -NoNewline
    Write-Host ""
    Write-Host "  ├──────────┼──────────────────────────────────────────┼───┤"
    
    $displayAccount = $accountStatus
    if ($displayAccount.Length -gt 40) { $displayAccount = $displayAccount.Substring(0, 38) + ".." }
    Write-Host ("  │ {0,-8} │ {1,-40} │ {2} │" -f "Account", $displayAccount, $accountIcon) -ForegroundColor Cyan -NoNewline
    Write-Host ""
    Write-Host "  ├──────────┼──────────────────────────────────────────┼───┤"

    $displayDir = $dirStatus
    if ($displayDir.Length -gt 40) { $displayDir = $displayDir.Substring(0, 38) + ".." }
    Write-Host ("  │ {0,-8} │ {1,-40} │ {2} │" -f "Dir", $displayDir, $dirIcon) -ForegroundColor Cyan -NoNewline
    Write-Host ""
    Write-Host "  └──────────┴──────────────────────────────────────────┴───┘"
    
    Write-Host ""
    
    if ($InstallHookFlag) {
        $gitDir = git rev-parse --git-dir
        $hookFile = Join-Path $gitDir "hooks\pre-commit"
        $userHook = Join-Path $gitDir "hooks\pre-commit.user"
        $hooksDir = Join-Path $gitDir "hooks"

        if (-not (Test-Path $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }

        if (Test-Path $hookFile) {
            $existing = Get-Content $hookFile -Raw
            if ($existing -notmatch "devprofile-hook-wrapper") {
                if (Test-Path $userHook) {
                    $ts = [int][double]::Parse((Get-Date -UFormat %s))
                    Move-Item $hookFile "$userHook.$ts"
                    Write-Warn "Existing pre-commit moved to $userHook.$ts"
                } else {
                    Move-Item $hookFile $userHook
                    Write-Warn "Existing pre-commit moved to $userHook"
                }
            }
        }

        $userHookSh = $userHook -replace '\\','/'
        $wrapper = @"
#!/bin/sh
# devprofile-hook-wrapper

email=\$(git config user.email)
name=\$(git config user.name)

if [ -z "\$email" ] || [ -z "\$name" ]; then
    echo "ERROR: Git identity not configured!"
    echo "Run: devprofile use <account-name>"
    exit 1
fi

echo "Committing as: \$name <\$email>"

USER_HOOK="$userHookSh"
if [ -x "\$USER_HOOK" ]; then
    "\$USER_HOOK" "\$@"
fi
"@

        Set-Content $hookFile -Encoding UTF8 -Value $wrapper

        Write-Success "Pre-commit hook installed: $hookFile"
        Write-Host ""
    }
    
    if ($issues -eq 0) {
        Write-Success "All checks passed!"
    } else {
        Write-Warn "$issues issue(s) found"
    }
    Write-Host ""
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
$installHookFlag = $InstallHook -or ($Arg1 -eq "--install-hook") -or ($Rest -contains "--install-hook")

switch ($Command) {
    "help" { Show-Help }
    "--help" { Show-Help }
    "-h" { Show-Help }
    "list" { Show-List }
    "use" { Use-Account -AccountName $Arg1 }
    "init" { Initialize-Account -Name $Arg1 -Email $Arg2 -PassphraseFlag:$Passphrase -NoPassphraseFlag:$NoPassphrase -ExtraArgs $Rest }
    "verify" { Test-Identity -InstallHookFlag:$installHookFlag }
    "" { Show-Current }
    default {
        Write-Err "Unknown command: $Command"
        Write-Host "Run 'devprofile help' for usage"
        exit 1
    }
}
