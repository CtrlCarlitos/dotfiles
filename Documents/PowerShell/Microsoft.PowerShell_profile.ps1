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
    # starship (and zoxide, below) use 'powershell' as the shell identifier for both
    # Windows PowerShell and PowerShell 7+ - 'pwsh' is rejected by both (unlike direnv,
    # which is the opposite: it requires 'pwsh' and rejects 'powershell').
    Initialize-ModernTool (&starship init powershell)
}

# Windows Terminal cwd reporting (OSC 9;9): lets "duplicate" panes/tabs -
# Alt+Shift+D and the Ctrl+Alt+Shift+<agent> splits - open in THIS directory
# instead of the profile's start dir. Starship calls this hook before every
# prompt; in-process, no fork. Only inside Terminal (VS Code's own shell
# integration already tracks cwd).
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
# OpenCode TUI clipboard
#-------------------------------------------------------------------------------
# Upstream's experimental flag (verified against 1.18.33: the binary parses
# "true"/"1" as its only truthy spellings and treats UNSET as true). Set to
# "false", highlighting a selection copies it on mouse-release with a "Copied
# to clipboard" toast - the same highlight-copies contract as Windows
# Terminal's copyOnSelect and VS Code's copyOnSelection. Unset, opencode
# keeps right-click-to-copy instead. Restart opencode after changing this.
$env:OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT = 'false'

#-------------------------------------------------------------------------------
# Chocolatey - lazy on purpose. Importing chocolateyProfile (tab completion,
# refreshenv) measured ~320 ms on every shell start, and it only matters once
# you actually type `choco`. The first call imports the module globally,
# removes this shim, and forwards to the real exe - after that, `choco` and
# `refreshenv` behave stock. Until the first call there is no choco tab
# completion and no refreshenv; that is the trade.
#-------------------------------------------------------------------------------
if (Test-Path "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1") {
    function choco {
        Remove-Item function:choco -ErrorAction SilentlyContinue
        Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1" -Global
        & "$env:ChocolateyInstall\choco.exe" @args
    }
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
            # New installs land in the registry PATH; this session only sees
            # them after a re-read (child installers keep their own PATH).
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        }
        'upgrade'   { & (Join-Path $repoScripts 'dotupgrade.ps1') @rest }
        'backup'    { & (Join-Path $repoScripts 'dotbackup.ps1') @rest }
        'restore'   { & (Join-Path $repoScripts 'dotrestore.ps1') @rest }
        'doctor'    {
            $repair = @($rest | Where-Object { $_ -in '--fix', '-Fix' }).Count -gt 0
            $doctorArgs = @($rest | Where-Object { $_ -notin '--fix', '-Fix' })
            & (Join-Path $repoScripts 'dotfiles-doctor.ps1') -Fix:$repair @doctorArgs
        }
        'remote' { & (Join-Path $repoScripts 'remote-access.ps1') @rest }
        'devtmp' { & (Join-Path $repoScripts 'devtmp.ps1') @rest }
        'version' { & (Join-Path $repoScripts 'dotversion.ps1') @rest }
        'ssh-fingerprints' { python (Join-Path $repoScripts 'ssh_fingerprints.py') @rest }
        default {
            $unknown = $sub -ne '' -and $sub -notin @('help', '-h', '--help')
            if ($unknown) {
                Write-Host "dot: unknown command '$sub'"
                Write-Host "  (a command added by a recent 'dot up' needs a new shell: this one loaded an older dot)"
            }
            Write-Host "dot - dotfiles command family"
            Write-Host ("  {0,-20}  {1}" -f 'dot ssh-fingerprints', 'preview agent fingerprint sync (--write to save)')
            Write-Host ("  {0,-20}  {1}" -f 'dot up', 'sync state (pull + apply + config re-init; never upgrades)')
            Write-Host ("  {0,-20}  {1}" -f 'dot upgrade', 'upgrade ALL tooling (choco + AI tools, session-gated)')
            Write-Host ("  {0,-20}  {1}" -f 'dot backup', 'encrypted portable backup')
            Write-Host ("  {0,-20}  {1}" -f 'dot restore', 'restore a backup')
            Write-Host ("  {0,-20}  {1}" -f 'dot doctor', 'dotfiles health check')
            Write-Host ("  {0,-20}  {1}" -f 'dot remote', 'remote-access setup/status/fix')
            Write-Host ("  {0,-20}  {1}" -f 'dot devtmp', 'build/test output folder for Defender (plan/apply/run)')
            Write-Host ("  {0,-20}  {1}" -f 'dot version', 'which version of the dotfiles repo this is')
            if ($unknown) { $global:LASTEXITCODE = 2 }
        }
    }
}

# devprofile switcher (not part of the dot family - kept as-is).
function dp { devprofile @args }

# Navigation - depth semantics match dot_aliases.zsh exactly (.. = 1 up,
# ... = 2 up, .... = 3 up). The old twin had `...` defined twice; the second
# (4-up) definition silently won, so `...` jumped four levels and 2-up was
# unreachable. `cd -` needs no alias - pwsh 7 supports it natively.
function ~ { Set-Location ~ }

# wsl: land in the WSL home directory instead of the /mnt/c mirror of the
# Windows cwd - the mirror's directory scans are slow (9p + AV) and starship
# times out on them ("Scanning current directory timed out"). Arguments pass
# through (wsl -d <distro> still works); run `wsl --cd <dir>` when the
# /mnt/c mirror of the current directory IS the destination.
function wsl {
    wsl.exe --cd ~ @args
}

# Path-like tokens autocd (interactive, via PSReadLine): PowerShell parses a
# bare token like ~\.local\share\chezmoi as a MODULE spec - "The module '~'
# could not be loaded" - and its command resolution never reaches
# CommandNotFoundAction for separator tokens (verified: the hook fires for
# plain typos but not here). The Enter handler rewrites such lines to
# Set-Location before accepting: zsh autocd, scoped to separator-containing
# tokens that exist as directories (no whitespace/quotes), so command typos
# and every other input are accepted unchanged.
if (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Chord Enter -ScriptBlock {
        $line = $null
        $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        $trimmed = $line.Trim()
        if ($trimmed -and $trimmed -notmatch '[\s"'']' -and $trimmed -match '[/\\]') {
            $candidate = if ($trimmed.StartsWith('~')) { Join-Path $HOME $trimmed.Substring(1) } else { $trimmed }
            if (Test-Path -LiteralPath $candidate -PathType Container -ErrorAction SilentlyContinue) {
                # Echoed as a short, honest "cd -LiteralPath '<path>'" line.
                # A silent variant (Set-Location + InvokePrompt re-render) was
                # tried and rejected: InvokePrompt re-runs the prompt before
                # its git segment resolves, littering the scrollback with a
                # "?" placeholder line.
                $escaped = $candidate.Replace("'", "''")
                [Microsoft.PowerShell.PSConsoleReadLine]::Delete(0, $line.Length)
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert("cd '$escaped'")
                [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
            }
        }
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }
}
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

# serena-clean (oraios/serena#2122): agy leaves serena shim+python trees
# running after exit; the next agy session's /mcp reload fails ("failed to
# stop mcp instance: serena: exit status 1") until they are gone. Close the
# agent CLIs first, then run it.
function serena-clean {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'name is alias-parity with docker-clean')]
    param()
    Get-Process serena -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
        Where-Object { $_.CommandLine -match 'serena' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

# clip-to-file (the psmux paste workaround, psmux#719): pastes into agent
# TUIs through psmux arrive as a raw blob (psmux does not wrap in bracketed
# paste), so substantial content goes via a file instead. Copies the
# highlighted text (already on the clipboard through copyOnSelect) to a
# timestamped file, puts the file path back on the clipboard, and prints it:
# in the agent, reference it as @<path> (or just paste the path) and the
# agent reads the content.
function clip-to-file {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'user-facing workflow name (clip-to-file), not an action verb')]
    param()
    $f = Join-Path $env:TEMP ("clip-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".txt")
    Get-Clipboard -Raw | Set-Content -NoNewline $f
    Set-Clipboard $f
    Write-Output $f
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
#
# This runs in EVERY shell, so the normal case - the agent already holds every
# declared key, which it persists across reboots - must be cheap: one
# `ssh-add -l` and a fingerprint compare against $SshAgentFingerprints, which
# the generator computes from the .pub files once per apply. Output from an
# older generator (no map in agent-identities.ps1 yet) falls back to
# fingerprinting each key file itself - one ssh-keygen spawn per key, once,
# until the generator re-runs.
try {
    $__sshAgentIds = Join-Path $env:USERPROFILE ".ssh\agent-identities.ps1"
    if ((Test-Path $__sshAgentIds) -and (Get-Command ssh-add -ErrorAction SilentlyContinue)) {
        . $__sshAgentIds   # -> $SshAgentIdentities (+ $SshAgentFingerprints from newer generators)
        $__loaded = @(& ssh-add -l 2>$null)
        $__loadFps = @($__loaded | ForEach-Object { ($_ -split '\s+')[1] })
        $__missing = @(
            foreach ($__k in @($SshAgentIdentities)) {
                $__kp = Join-Path $env:USERPROFILE ".ssh\$__k"
                if (-not (Test-Path $__kp)) { continue }
                if ($SshAgentFingerprints -and $SshAgentFingerprints.Contains($__k)) {
                    # Fast path: compare against the generated fingerprint - no spawn.
                    if ($__loadFps -notcontains $SshAgentFingerprints[$__k]) { $__k }
                } else {
                    # Older generator output: fingerprint the key file (one spawn per key).
                    $__fpSrc = if (Test-Path "$__kp.pub") { "$__kp.pub" } else { $__kp }
                    $__fp = ((& ssh-keygen -lf $__fpSrc 2>$null) -split '\s+')[1]
                    if (-not ($__fp -and ($__loaded -match [regex]::Escape($__fp)))) { $__k }
                }
            }
        )
        foreach ($__k in $__missing) {
            $__kp = Join-Path $env:USERPROFILE ".ssh\$__k"
            # Never block a new shell: `ssh-add` on a passphrase-protected key
            # prompts on the console, which would hang EVERY terminal at startup
            # for anyone who uses passphrases. `ssh-keygen -y -P ""` succeeds only
            # on a key with no passphrase, so it is a safe pre-flight test.
            # Passphrase keys are added once, by hand - the Windows agent is a
            # service and persists them across reboots (DPAPI, in the registry),
            # so that is a one-time cost, not a per-login one.
            & ssh-keygen -y -P '""' -f $__kp *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ssh-agent: $__k needs a passphrase - run: ssh-add `"$__kp`"" -ForegroundColor DarkYellow
                continue
            }
            & ssh-add $__kp 2>&1 | Out-Null
        }
    }
} catch { Write-Verbose "ssh-agent prewarm skipped: $($_.Exception.Message)" } finally {
    Remove-Variable __sshAgentIds,__loaded,__loadFps,__missing,__k,__kp,__fpSrc,__fp -ErrorAction SilentlyContinue
}
