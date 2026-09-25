#-------------------------------------------------------------------------------
# Modern Tools Initialization
#-------------------------------------------------------------------------------
# starship/zoxide emit shell code that is designed to be eval'd - there is no
# non-iex integration. PSSA suppression is scoped to this wrapper so the rule
# stays live everywhere else.
function Initialize-ModernTool {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'starship/zoxide init output is designed to be eval-ed')]
    param([string]$InitScript)
    Invoke-Expression $InitScript
}
# Starship
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Initialize-ModernTool (&starship init powershell)
}

# Windows Terminal cwd reporting (OSC 9;9) - twin of the PowerShell 7
# profile's block: duplicate panes/tabs and the agent splits open here.
if ($env:WT_SESSION) {
    function Invoke-Starship-PreCommand {
        if ($PWD.Provider.Name -eq 'FileSystem') {
            $host.UI.Write("$([char]27)]9;9;`"$($PWD.ProviderPath)`"$([char]27)\")
        }
    }
}

# Zoxide
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Initialize-ModernTool (&zoxide init powershell | Out-String)
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
# comment on the dot/dp block below for the source-of-truth rule).
# Deliberately NOT ported: `ni` (collides with pwsh's built-in New-Item
# alias), `ps`->procs and `top`->htop (would shadow Get-Process / need a
# TUI Windows doesn't have), the rm/mv/cp -i safety wrappers (pwsh prompts
# differently by design), and `vi` is added below rather than shadowing
# anything. `cd -` is pwsh 7-only - 5.1 has no `-` alias; use the
# `..`/`...`/`....` helpers below.
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
# No `reload`: dot-sourcing $PROFILE inside a function defines everything in
# that function's scope, which is discarded on return. After installing or
# refreshing, restart the terminal instead.
function prof { nvim $PROFILE }
function get { curl.exe -sS @args }
function post { curl.exe -sS -X POST @args }
function devprofiles { devprofile list }
function agy { agy.exe --dangerously-skip-permissions @args }
# Process viewers via pstop (psmux/pstop, Chocolatey "pstop"). The choco
# package ships its own htop.exe shim on PATH, so htop needs NO alias here
# (a profile function would only shadow the real binary). Only top is
# wrapped - it has no shim. `ps` is deliberately left as pwsh's built-in
# Get-Process alias (procs stays available under its own name).
if (Get-Command pstop -ErrorAction SilentlyContinue) {
    function top { pstop @args }
}

# Dotfiles command family (dot CLI). `dot up` syncs
# state and NEVER upgrades (chezmoi update owns the pull; init re-runs the
# config template AFTER the pull - init does not fetch - and a final apply
# fires only when init actually rewrote the config). `dot upgrade` is the
# single upgrade owner (choco sweep + AI tools, live-session gated).
function dot {
    $sub = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
    $rest = @($args | Select-Object -Skip 1)
    $repoScripts = Join-Path $HOME '.local\share\chezmoi\scripts'
    switch ($sub) {
        'up' {
            chezmoi update --apply
            if ($LASTEXITCODE -ne 0) { return }
            $cfg = Join-Path $HOME '.config\chezmoi\chezmoi.toml'
            $before = if (Test-Path $cfg) { (Get-FileHash $cfg -ErrorAction SilentlyContinue).Hash } else { $null }
            chezmoi init
            if ($LASTEXITCODE -ne 0) { return }
            $after = if (Test-Path $cfg) { (Get-FileHash $cfg -ErrorAction SilentlyContinue).Hash } else { $null }
            if ($before -ne $after) { chezmoi apply }
        }
        'upgrade'   { & (Join-Path $repoScripts 'dotupgrade.ps1') @rest }
        'backup'    { & (Join-Path $repoScripts 'dotbackup.ps1') @rest }
        'restore'   { & (Join-Path $repoScripts 'dotrestore.ps1') @rest }
        'doctor'    { & (Join-Path $repoScripts 'dotfiles-doctor.ps1') @rest }
        default {
            Write-Host "dot - dotfiles command family"
            Write-Host "  dot up        sync state (pull + apply + config re-init; never upgrades)"
            Write-Host "  dot upgrade   upgrade ALL tooling (choco + AI tools, session-gated)"
            Write-Host "  dot backup    encrypted portable backup"
            Write-Host "  dot restore   restore a backup"
            Write-Host "  dot doctor    dotfiles health check"
        }
    }
}

# devprofile switcher (not part of the dot family - kept as-is).
function dp { devprofile @args }

# Navigation - depth semantics match dot_aliases.zsh exactly (.. = 1 up,
# ... = 2 up, .... = 3 up). The old twin had `...` defined twice; the second
# (4-up) definition silently won, so `...` jumped four levels and 2-up was
# unreachable. (`cd -` is pwsh 7-only - it is not available in 5.1.)
function ~ { Set-Location ~ }
function .. { Set-Location .. }
function ... { Set-Location ..\.. }
function .... { Set-Location ..\..\.. }

# Docker (dc family is the pwsh-native set; docker-clean/stop-all are the
# dot_aliases.zsh pair, mirrored here for full parity)
function d { docker $args }
function dc { docker compose $args }
function dcu { docker compose up -d $args }
function dcd { docker compose down $args }
function dcl { docker compose logs -f $args }
function dcp { docker compose ps $args }
# docker-clean/stop-all keep their dot_aliases.zsh names verbatim - the names
# ARE the cross-shell contract; PSSA's approved-verb rule is suppressed per
# function for exactly these two.
function docker-clean {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'name is alias-parity with dot_aliases.zsh')]
    param()
    docker system prune -af --volumes
}
function docker-stop-all {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'name is alias-parity with dot_aliases.zsh')]
    param()
    docker stop (docker ps -aq) 2>$null
}

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
        # Splat: $args as one object[] cannot bind to devprofile.ps1's
        # [string]$Command (every `devprofile <cmd>` failed before the splat).
        & $ScriptPath @args
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
            # Never block a new shell - twin of the PowerShell 7 profile's guard:
            # ssh-add on a passphrase-protected key prompts on the console and
            # would hang every terminal at startup. `ssh-keygen -y -P ""` exits
            # non-zero on such a key without prompting (verified: 0 vs 255).
            & ssh-keygen -y -P '""' -f $__kp *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ssh-agent: $__k needs a passphrase - run: ssh-add `"$__kp`"" -ForegroundColor DarkYellow
                continue
            }
            & ssh-add $__kp 2>&1 | Out-Null
        }
    }
} catch { Write-Verbose "ssh-agent prewarm skipped: $($_.Exception.Message)" } finally {
    Remove-Variable __sshAgentIds,__loaded,__k,__kp,__fpSrc,__fp -ErrorAction SilentlyContinue
}
