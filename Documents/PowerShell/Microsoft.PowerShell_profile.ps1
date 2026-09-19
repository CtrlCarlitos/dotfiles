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

# Direnv: deliberately NOT initialized on Windows. Confirmed live on a
# real machine: with the hook installed, plain directory navigation
# triggered frequent "Select an app to open" ShellExecute popups the
# operator cannot dismiss permanently - and direnv isn't used on the
# Windows side anyway (the zsh/dot_zshrc hook covers WSL). The binary
# stays installed; nothing initializes it here, and starship's direnv
# module is disabled in starship.toml so nothing else spawns it either.



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

# Cross-shell parity with dot_aliases.zsh - the portable subset (see the
# comment on the dotup/dp block below for the source-of-truth rule).
# Deliberately NOT ported: `ni` (collides with pwsh's built-in New-Item
# alias), `ps`->procs and `top`->htop (would shadow Get-Process / need a
# TUI Windows doesn't have), the rm/mv/cp -i safety wrappers (pwsh prompts
# differently by design), and `vi` is added below rather than shadowing
# anything. `cd -` works natively in pwsh 7 - no `-` alias needed.
if (Get-Command eza -ErrorAction SilentlyContinue) {
    function lt { eza --tree --icons --level 2 @args }
    function lta { eza --tree --icons --level 2 -a @args }
}
if (Get-Command nvim -ErrorAction SilentlyContinue) {
    function vi { nvim @args }
}
function c { Clear-Host }
function h { Get-History @args }
function py { python @args }
function nr { npm run @args }
function nrd { npm run dev }
function nrb { npm run build }
function serve { python -m http.server 8000 }
function ff { Get-ChildItem -Recurse -File -Filter "$args" }
function path { $env:Path -split ';' }
function reload { . $PROFILE }
function prof { nvim $PROFILE }
function get { curl.exe -sS @args }
function post { curl.exe -sS -X POST @args }
function devprofiles { devprofile list }
function agy { agy.exe --dangerously-skip-permissions @args }
# htop parity via pstop (psmux/pstop, Chocolatey "pstop") - gated so the
# aliases simply don't exist before the first install completes. `ps` is
# deliberately left as pwsh's built-in Get-Process alias (procs stays
# available under its own name).
if (Get-Command pstop -ErrorAction SilentlyContinue) {
    function htop { pstop @args }
    function top { pstop @args }
}

# Dotfiles parity with dot_aliases.zsh (the zsh file stays the source of
# truth for Unix; only what maps cleanly to PowerShell lives here). Confirmed
# live: dotup was zsh-only and a fresh Windows box had no way to update.
function dotup { chezmoi update --apply @args }
function dp { devprofile @args }

# Navigation - depth semantics match dot_aliases.zsh exactly (.. = 1 up,
# ... = 2 up, .... = 3 up). The old twin had `...` defined twice; the second
# (4-up) definition silently won, so `...` jumped four levels and 2-up was
# unreachable. `cd -` needs no alias - pwsh 7 supports it natively.
function ~ { Set-Location ~ }
function .. { cd .. }
function ... { cd ..\.. }
function .... { cd ..\..\.. }

# Docker (dc family is the pwsh-native set; docker-clean/stop-all are the
# dot_aliases.zsh pair, mirrored here for full parity)
function d { docker $args }
function dc { docker compose $args }
function dcu { docker compose up -d $args }
function dcd { docker compose down $args }
function dcl { docker compose logs -f $args }
function dcp { docker compose ps $args }
function docker-clean { docker system prune -af --volumes }
function docker-stop-all { docker stop (docker ps -aq) 2>$null }

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
