#-------------------------------------------------------------------------------
# Modern Tools Initialization
#-------------------------------------------------------------------------------
# Starship
if (Get-Command starship -ErrorAction SilentlyContinue) {
    # starship (and zoxide, below) use 'powershell' as the shell identifier for both
    # Windows PowerShell and PowerShell 7+ - 'pwsh' is rejected by both (unlike direnv,
    # which is the opposite: it requires 'pwsh' and rejects 'powershell').
    Invoke-Expression (&starship init powershell)
}

# Zoxide
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (&zoxide init powershell | Out-String)
}

# Direnv (Using a helper or just checking hook)
if (Get-Command direnv -ErrorAction SilentlyContinue) {
    # PowerShell hook for direnv
    function Invoke-DirenvHook {
        $env:DIRENV_LOG_FORMAT = ""
        $output = (direnv export json | ConvertFrom-Json)
        if ($output) {
             foreach ($prop in $output.PSObject.Properties) {
                 if ($prop.Value -eq $null) {
                     Remove-Item -Path "env:\$($prop.Name)"
                 } else {
                     Set-Item -Path "env:\$($prop.Name)" -Value $prop.Value
                 }
             }
        }
    }
    # Register the hook but verify conflicts first needed? usually prompt hook
    # Native hook is better:
    Invoke-Expression "$(direnv hook pwsh)"
}



#-------------------------------------------------------------------------------
# Chocolatey
#-------------------------------------------------------------------------------
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}

#-------------------------------------------------------------------------------
# Aliases & Modern Tools
#-------------------------------------------------------------------------------
if (Get-Command eza -ErrorAction SilentlyContinue) {
    Set-Alias -Name ls -Value eza -Option AllScope -Force
    function ll { eza -l --icons --group-directories-first $args }
    function la { eza -la --icons --group-directories-first $args }
}

if (Get-Command bat -ErrorAction SilentlyContinue) {
    Set-Alias -Name cat -Value bat -Option AllScope -Force
}

if (Get-Command nvim -ErrorAction SilentlyContinue) {
    Set-Alias -Name vim -Value nvim -Option AllScope -Force
    Set-Alias -Name v -Value nvim -Option AllScope -Force
}

# OMZ-style Git Aliases
function gst { git status $args }
function gd { git diff $args }
function gl { git pull $args }
function gp { git push $args }
function gco { git checkout $args }
function ga { git add $args }
function gcam { git commit -am $args }
function gb { git branch $args }

# Navigation
function .. { cd .. }
function ... { cd ..\.. }
function .... { cd ..\..\.. }
function ... { cd ..\..\..\.. }

# Docker
function d { docker $args }
function dc { docker compose $args }
function dcu { docker compose up -d $args }
function dcd { docker compose down $args }
function dcl { docker compose logs -f $args }
function dcp { docker compose ps $args }

#-------------------------------------------------------------------------------
# Utilities
#-------------------------------------------------------------------------------
function devprofile {
    # Chezmoi places this in a standard location (e.g. ~/.local/bin or similar if we map it so).
    # For now, let's assume it's in a known scripts directory managed by chezmoi or just a function here.
    # Logic: We should really make devprofile available on PATH.
    # Fallback to local script if installed via dot_local/bin
    $ScriptPath = Join-Path $env:USERPROFILE ".local\bin\devprofile.ps1"
    if (Test-Path $ScriptPath) {
        & "$ScriptPath" $args
    } else {
        Write-Host "devprofile.ps1 not found at $ScriptPath" -ForegroundColor Red
    }
}

#-------------------------------------------------------------------------------
# PATH Additions
#-------------------------------------------------------------------------------
$UserNodeModules = Join-Path $env:APPDATA "npm"
if (Test-Path $UserNodeModules) {
    $env:Path = "$UserNodeModules;" + $env:Path
}

$LocalBin = Join-Path $env:USERPROFILE ".local\bin"
if (Test-Path $LocalBin) {
    if ($env:Path -notlike "*$LocalBin*") {
        $env:Path = "$LocalBin;" + $env:Path
    }
}

#-------------------------------------------------------------------------------
# SSH agent - top up with declared identities not already loaded
#-------------------------------------------------------------------------------
# Safety net for the load done by run_onchange_generate_identities (which sets
# the service to Automatic + Running and ssh-add's the declared keys). Covers a
# service that got cleared, or the generator not having re-run since an account
# was added. Only ADDS - never flushes. To remove a key: ssh-add -d ~/.ssh/<key>
# (or ssh-add -D for all); de-declaring the account does not evict it.
try {
    $__sshAgentIds = Join-Path $env:USERPROFILE ".ssh\agent-identities.ps1"
    if ((Test-Path $__sshAgentIds) -and (Get-Command ssh-add -ErrorAction SilentlyContinue)) {
        . $__sshAgentIds   # -> $SshAgentIdentities
        $__loaded = & ssh-add -l 2>$null
        foreach ($__k in $SshAgentIdentities) {
            $__kp = Join-Path $env:USERPROFILE ".ssh\$__k"
            if (-not (Test-Path $__kp)) { continue }
            $__fpSrc = if (Test-Path "$__kp.pub") { "$__kp.pub" } else { $__kp }
            $__fp = ((& ssh-keygen -lf $__fpSrc 2>$null) -split '\s+')[1]
            if ($__fp -and ($__loaded -match [regex]::Escape($__fp))) { continue }
            & ssh-add $__kp 2>&1 | Out-Null
        }
    }
} catch { } finally {
    Remove-Variable __sshAgentIds,__loaded,__k,__kp,__fpSrc,__fp -ErrorAction SilentlyContinue
}
