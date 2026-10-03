#Requires -Version 5.1
<#
dotfiles-doctor.ps1 - Windows twin of scripts/dotfiles-doctor.sh. Repo-level
complement to `chezmoi doctor`, checking failure classes this repo has hit
live: config saved as Windows-1252 (the WinMerge/Notepad-ANSI edit class),
unparseable config, prompted keys missing from the live config (the
"map has no entry for key" outage), missing source dir, drifted chezmoi
version vs .chezmoi-version, and guardrail binary vs the .chezmoidata.yaml
pin. See the .sh twin for the full rationale of each check.

Usage: pwsh -File dotfiles-doctor.ps1 [-Fix]
Exit 0 = no errors (warnings allowed); exit 1 = at least one error.
#>
param([switch]$Fix)

$ErrorActionPreference = 'Stop'

# In-apply mode: invoked by run_after_dotfiles-doctor.ps1 during a chezmoi
# apply, which HOLDS chezmoi's persistent-state lock - sub-chezmoi calls
# deadlock on it and are tautological mid-apply anyway. File-level checks
# only in this mode (twin of the .sh DOTFILES_DOCTOR_IN_APPLY).
$InApply = [bool]$env:DOTFILES_DOCTOR_IN_APPLY

$isWin = ($env:OS -eq 'Windows_NT')
$homeDir = if ($isWin) { $env:USERPROFILE } else { $env:HOME }
$configDir = if ($env:CHEZMOI_CONFIG_DIR) { $env:CHEZMOI_CONFIG_DIR } else { Join-Path $homeDir '.config/chezmoi' }
$config = Join-Path $configDir 'chezmoi.toml'
$repoRoot = Split-Path -Parent $PSScriptRoot

$script:Errors = 0
function Result([string]$r, [string]$check, [string]$msg) {
    Write-Host ("{0,-7}  {1,-16} {2}" -f $r, $check, $msg)
    if ($r -eq 'error') { $script:Errors++ }
}

# vX.Y.Z[-suffix] -> zero-padded comparable long (twin of the sh ver_num).
function VerNum([string]$v) {
    $v = $v.TrimStart('v')
    $v = ($v -split '-')[0]
    $p = $v -split '\.'
    [long]::Parse($p[0]) * 100000000L +
        [long]::Parse($p[1]) * 10000L +
        [long]::Parse($p[2])
}

$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)   # throwOnInvalidBytes
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$cp1252 = [System.Text.Encoding]::GetEncoding(1252)
$latin1 = [System.Text.Encoding]::GetEncoding(28591) # 1:1 byte<->char, for line-wise checks

# --- 1. Config file is valid UTF-8 ------------------------------------------

if (-not (Test-Path -LiteralPath $config)) {
    Result 'error' 'config-utf8' "config not found: $config (run the installer, or chezmoi init)"
} else {
    $bytes = [IO.File]::ReadAllBytes($config)
    $valid = $true
    try { [void]$utf8Strict.GetString($bytes) } catch { $valid = $false }

    if ($valid) {
        Result 'ok' 'config-utf8' "$config is valid UTF-8"
    } else {
        # Mixed-encoding detection: any line that contains non-ASCII AND
        # decodes as strict UTF-8 on its own means some non-ASCII is real
        # UTF-8 - a blind 1252->UTF-8 transcode would mangle it. Refuse.
        $asLatin1 = $latin1.GetString($bytes)
        $mixed = $false
        foreach ($line in ($asLatin1 -split "`n")) {
            if ($line -match '[^\x00-\x7F]') {
                $lineBytes = $latin1.GetBytes($line.TrimEnd("`r"))
                try { [void]$utf8Strict.GetString($lineBytes) } catch { continue }
                $mixed = $true
                break
            }
        }

        if ($Fix -and -not $mixed) {
            try {
                $text = $cp1252.GetString($bytes)
                [IO.File]::WriteAllText($config, $text, $utf8NoBom)
                $recheck = $true
                try { [void]$utf8Strict.GetString([IO.File]::ReadAllBytes($config)) } catch { $recheck = $false }
                if ($recheck) {
                    Result 'ok' 'config-utf8' 'converted Windows-1252 -> UTF-8'
                } else {
                    Result 'error' 'config-utf8' 'transcode produced invalid UTF-8 - restore by hand'
                }
            } catch {
                Result 'error' 'config-utf8' "Windows-1252 decode failed - fix $config by hand"
            }
        } elseif ($mixed) {
            Result 'error' 'config-utf8' 'MIXED encodings: some non-ASCII is valid UTF-8, some is not - fix by hand (open in an editor, save as UTF-8)'
        } else {
            Result 'error' 'config-utf8' 'invalid UTF-8 (saved as Windows-1252/ANSI?) - re-run with -Fix to convert'
        }
    }
}

# --- 2. Config parses --------------------------------------------------------

if ($InApply) {
    Result 'skip' 'config-parse' 'in-apply mode - chezmoi already parsed the config to get this far'
} elseif (Test-Path -LiteralPath $config) {
    # --config pins chezmoi to the file every other check inspects (see the
    # .sh twin): bare `chezmoi data` resolves its own config independently.
    # try/catch like every other native call here: under EAP=Stop the 5.1
    # profile's `dot doctor` turned chezmoi's config-parse stderr into a
    # terminating NativeCommandError - crashing on exactly the input this
    # check exists to report.
    $configParses = $false
    try {
        & chezmoi --config $config data *> $null
        if ($LASTEXITCODE -eq 0) { $configParses = $true }
    } catch { Write-Verbose "config-parse probe failed: $($_.Exception.Message)" }
    if ($configParses) {
        Result 'ok' 'config-parse' 'chezmoi loads the config'
    } else {
        Result 'error' 'config-parse' 'chezmoi cannot parse the config (encoding above? run: chezmoi execute-template "{{ .chezmoi.sourceDir }}" to see raw errors)'
    }
}

# --- 3. Every prompted key exists in the live config ------------------------

if (Test-Path -LiteralPath $config) {
    $content = [IO.File]::ReadAllText($config)
    $sectionMatch = [regex]::Match($content, '(?ms)^[ \t]*\[data\.packages\][ \t]*\r?\n(.*?)(?=^[ \t]*\[|\z)')
    $sectionBody = if ($sectionMatch.Success) { $sectionMatch.Groups[1].Value } else { '' }

    $keys = @('core', 'modern_cli', 'fonts', 'agent_toolkit', 'opencode_cli',
        'opencode_desktop', 'claude_cli', 'claude_desktop', 'chatgpt_cli',
        'chatgpt_desktop', 'antigravity_cli', 'antigravity_desktop', 'dev_desktop',
        'remote_access', 'remote_access_server', 'guardrail')
    $missing = @($keys | Where-Object {
        -not [regex]::IsMatch($sectionBody, ("^\s*" + [regex]::Escape($_) + "\s*="), [System.Text.RegularExpressions.RegexOptions]::Multiline)
    })

    if ($missing.Count -gt 0) {
        Result 'error' 'prompted-keys' ("missing [data.packages] keys (map-has-no-entry outage class): " + ($missing -join ' '))
    } else {
        Result 'ok' 'prompted-keys' "all $($keys.Count) [data.packages] keys present"
    }

    if ($content -match '(?m)^\s*primaryName\s*=' -or $content -match '(?m)^\s*\[\[data\.accounts\]\]') {
        Result 'ok' 'git-identity' 'primary* keys or [[data.accounts]] present'
    } else {
        Result 'error' 'git-identity' 'no git identity: neither primary* keys nor [[data.accounts]] - re-run chezmoi init'
    }
}

# --- 4. Source directory present ---------------------------------------------

if ($InApply) {
    Result 'skip' 'source-dir' 'in-apply mode - running from it right now'
} else {

$src = ''
try { $src = (& chezmoi source-path 2>$null | Out-String).Trim() } catch { Write-Verbose "source-path probe failed: $($_.Exception.Message)" }
if ($src -and (Test-Path -LiteralPath $src)) {
    $dirty = $false
    & git -C $src diff --quiet *> $null
    if ($LASTEXITCODE -ne 0) { $dirty = $true }
    & git -C $src diff --cached --quiet *> $null
    if ($LASTEXITCODE -ne 0) { $dirty = $true }
    if ($dirty) {
        Result 'warn' 'source-dir' "$src has uncommitted changes"
    } else {
        Result 'ok' 'source-dir' "$src (clean)"
    }
} else {
    Result 'warn' 'source-dir' 'source dir missing - run the installer or: chezmoi init CtrlCarlitos/dotfiles'
}

} # end not-in-apply (source-dir)

# --- 5. Installed chezmoi vs the repo's .chezmoi-version pin ------------------

if ($InApply) {
    Result 'skip' 'chezmoi-version' 'in-apply mode - run standalone for version/pin drift checks'
} else {

$pinVersion = ''
if (Test-Path (Join-Path $repoRoot '.chezmoi-version')) {
    $pinVersion = ([IO.File]::ReadAllText((Join-Path $repoRoot '.chezmoi-version'))).Trim()
}
$installedVersion = ''
try { $installedVersion = ((& chezmoi --version 2>$null | Out-String).Trim() -replace '^chezmoi version ', '') -replace ',.*$', '' } catch { Write-Verbose "chezmoi --version probe failed: $($_.Exception.Message)" }
if ($pinVersion -and $installedVersion -and ($installedVersion -match '^v?\d+\.\d+\.\d+')) {
    if ((VerNum $installedVersion) -lt (VerNum $pinVersion)) {
        Result 'warn' 'chezmoi-version' "installed $installedVersion < pinned $pinVersion - run: chezmoi upgrade"
    } else {
        Result 'ok' 'chezmoi-version' "installed $installedVersion (pin: $pinVersion)"
    }
} else {
    Result 'skip' 'chezmoi-version' "cannot compare (installed: $(if ($installedVersion) { $installedVersion } else { '?' }), pin: $(if ($pinVersion) { $pinVersion } else { '?' }))"
}

} # end not-in-apply (chezmoi-version)

# --- 6. Installed guardrail binary vs .chezmoidata.yaml pin -------------------

if ($InApply) {
    Result 'skip' 'guardrail-pin' 'in-apply mode - run standalone for version/pin drift checks'
} else {

$guardrailPin = ''
try { $guardrailPin = (& chezmoi execute-template --source $repoRoot '{{ .guardrail.version }}' 2>$null | Out-String).Trim() } catch { Write-Verbose "guardrail pin probe failed: $($_.Exception.Message)" }
if (-not $guardrailPin) {
    Result 'skip' 'guardrail-pin' 'source unreadable - run from a full checkout'
} else {
    $grBin = Join-Path $homeDir '.local\bin\guardrail.exe'
    if (-not (Test-Path $grBin)) { $grBin = Join-Path $homeDir '.local/bin/guardrail' }
    if (-not (Test-Path $grBin)) {
        $cmd = Get-Command guardrail -ErrorAction SilentlyContinue
        if ($cmd) { $grBin = $cmd.Source }
    }
    if (-not (Test-Path $grBin)) {
        Result 'skip' 'guardrail-pin' 'guardrail not installed (opt-in via packages.guardrail)'
    } else {
        $have = ''
        try { $have = ((& $grBin version 2>$null | Out-String).Trim() -replace '^guardrail ', '') } catch { Write-Verbose "guardrail version probe failed: $($_.Exception.Message)" }
        if ($have -eq $guardrailPin) {
            Result 'ok' 'guardrail-pin' "guardrail $guardrailPin"
        } else {
            Result 'warn' 'guardrail-pin' "installed $(if ($have) { $have } else { 'unknown' }) vs pin $guardrailPin - run: chezmoi update"
        }
    }
}

} # end not-in-apply (guardrail-pin)

# --- 7. ~/.ssh key files readable by broad principals -------------------------
# OpenSSH for Windows refuses identity files whose ACL grants read to broad
# principals (Everyone / Users / Authenticated Users). Live observation: the
# default inherited ACLs (user-only) pass, so this only trips when something
# loosens them. -Fix locks each flagged file to the owning user (explicit
# user:R first, then strip inherited ACEs) and re-verifies.

if (Test-Path (Join-Path $homeDir '.ssh')) {
    # SIDs, not names: ACE identity display names are localized on non-English
    # Windows. Everyone=S-1-1-0, Authenticated Users=S-1-5-11, Users=S-1-5-32-545.
    $broadSids = 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545'
    $sshDir = Join-Path $homeDir '.ssh'

    function Get-LooseKeyFileList {
        $found = @()
        foreach ($keyfile in (Get-ChildItem $sshDir -Filter 'id_*' -File -ErrorAction SilentlyContinue)) {
            $acl = Get-Acl -LiteralPath $keyfile.FullName -ErrorAction SilentlyContinue
            foreach ($ace in $acl.Access) {
                if ($ace.AccessControlType -ne 'Allow') { continue }
                $sid = ''
                try { $sid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { Write-Verbose "unresolvable ACE identity skipped" }
                if ($broadSids -contains $sid) {
                    $found += $keyfile
                    break
                }
            }
        }
        return ,@($found)
    }

    $loose = Get-LooseKeyFileList
    if ($loose.Count -gt 0) {
        if ($Fix) {
            # Lock each flagged file to the owning user: explicit user:R
            # first (so stripping inheritance cannot lock anyone out), then
            # remove inherited ACEs, then remove any explicit grants for the
            # broad principals (observed live: an EXPLICIT Everyone ACE on a
            # copied .pub survives /inheritance:r).
            foreach ($f in $loose) {
                & icacls $f.FullName /grant:r "$($env:USERNAME):R" *> $null
                & icacls $f.FullName /inheritance:r *> $null
                & icacls $f.FullName /remove:g *S-1-1-0 *S-1-5-11 *S-1-5-32-545 *> $null
            }
            $still = Get-LooseKeyFileList
            if ($still.Count -gt 0) {
                Result 'warn' 'ssh-keyacl' "still readable by broad principals after -Fix: $(($still | ForEach-Object { $_.Name }) -join ', ')"
            } else {
                Result 'ok' 'ssh-keyacl' "normalized to user-only ACL: $(($loose | ForEach-Object { $_.Name }) -join ', ')"
            }
        } else {
            Result 'warn' 'ssh-keyacl' "readable by broad principals: $(($loose | ForEach-Object { $_.Name }) -join ', ') - remedy: icacls <file> /grant:r '<user>:R' /inheritance:r /remove:g *S-1-1-0 *S-1-5-11 *S-1-5-32-545 (or re-run with -Fix)"
        }
    } else {
        Result 'ok' 'ssh-keyacl' 'key file ACLs not broadly readable'
    }
}

# --- 8. SSH text files use LF on every platform -------------------------------
# Strict UTF-8 text only; preserve binary files, standalone CRs and ACLs.
# Do not follow reparse points out of the SSH directory.
function Get-SshTextCandidate([string]$Directory) {
    if ((Get-Item -LiteralPath $Directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    foreach ($entry in (Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($entry.PSIsContainer) { Get-SshTextCandidate $entry.FullName }
        else { $entry }
    }
}

if (Test-Path (Join-Path $homeDir '.ssh')) {
    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
    $crlfCount = 0
    foreach ($keyfile in (Get-SshTextCandidate (Join-Path $homeDir '.ssh'))) {
        try {
            $bytes = [IO.File]::ReadAllBytes($keyfile.FullName)
            try { $text = $utf8Strict.GetString($bytes) }
            catch [Text.DecoderFallbackException] { continue }
            if ($text -match '[\x00-\x08\x0b\x0e-\x1f]' -or -not $text.Contains("`r`n")) { continue }
            $crlfCount++
            if ($Fix) {
                [IO.File]::WriteAllBytes($keyfile.FullName, $utf8Strict.GetBytes($text.Replace("`r`n", "`n")))
                Result 'ok' 'ssh-crlf' "normalized CRLF to LF: $($keyfile.FullName)"
            } else {
                Result 'warn' 'ssh-crlf' "CRLF violates SSH text LF policy: $($keyfile.FullName) - re-run with -Fix"
            }
        } catch {
            Result 'error' 'ssh-crlf' "could not inspect or normalize $($keyfile.FullName): $_"
        }
    }
    if ($crlfCount -eq 0) { Result 'ok' 'ssh-crlf' 'SSH text files are LF' }
}

# --- 9. python3 resolves to a real interpreter (Windows) ------------------------
# The official Python installer ships python.exe, never python3, while this
# repo's scripts and tests assume the POSIX name: dot_local/bin/python3(.cmd)
# are the shims that forward to `python`. The Microsoft Store's python3.exe stub
# (Settings > Apps > Advanced app settings > App execution aliases) lives in
# WindowsApps, which comes EARLIER on PATH than ~/.local/bin, and shadows them:
# it prints "Python was not found" instead of running. Judged by behaviour (does
# `python3 --version` print Python 3.x?), so a genuine Store-installed Python,
# which also lives in WindowsApps, is fine. Warn-only: an error here would fail
# every apply. -Fix removes ONLY a WindowsApps python3 that does not run as
# Python. Skipped in-apply: the apply is what deploys the shim, and it must
# never touch the stub.
if ($isWin) {
    if ($InApply) {
        Result 'skip' 'python3' 'in-apply mode - run standalone to check python3 / the Microsoft Store stub'
    } else {
        $windowsApps = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps' } else { '' }

        function Get-Python3Probe {
            # Scope-local: on Windows PowerShell 5.1 a native stderr line would
            # otherwise throw under the script-wide 'Stop'.
            $ErrorActionPreference = 'Continue'
            $cmd = Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $cmd) { return @{ State = 'missing' } }
            $source = $cmd.Source
            $output = ''
            try { $output = (& $source --version 2>&1 | Out-String).Trim() } catch { $output = '' }
            if ($output -match '^Python 3\.') { return @{ State = 'ok'; Source = $source; Version = $output } }
            if ($windowsApps -and $source.StartsWith($windowsApps + '\', [StringComparison]::OrdinalIgnoreCase)) {
                return @{ State = 'stub'; Source = $source }
            }
            return @{ State = 'broken'; Source = $source; Output = $output }
        }

        $stubCure = 'turn it off: Settings > Apps > Advanced app settings > App execution aliases > python3.exe'
        $probe = Get-Python3Probe
        switch ($probe.State) {
            'ok' { Result 'ok' 'python3' "$($probe.Version) via $($probe.Source)" }
            'stub' {
                if ($Fix) {
                    # The alias is a zero-length reparse point; Remove-Item usually
                    # deletes it (as the Settings toggle does), cmd's del is the fallback.
                    try { Remove-Item -LiteralPath $probe.Source -Force -ErrorAction Stop }
                    catch { & cmd.exe /c del /f /q ('"' + $probe.Source + '"') *> $null }
                    $after = Get-Python3Probe
                    if ($after.State -eq 'ok') {
                        Result 'ok' 'python3' "removed the Microsoft Store stub; python3 is now $($after.Version) via $($after.Source)"
                    } elseif ($after.State -eq 'stub') {
                        Result 'warn' 'python3' "could not remove the Microsoft Store stub $($probe.Source) - $stubCure"
                    } else {
                        Result 'warn' 'python3' "removed the Microsoft Store stub, but python3 still does not resolve ($($after.State)) - run: chezmoi apply (deploys the shim)"
                    }
                } else {
                    Result 'warn' 'python3' "resolves to the Microsoft Store stub $($probe.Source), which shadows the python3 shim and prints 'Python was not found' - $stubCure (or re-run with -Fix)"
                }
            }
            'broken' { Result 'warn' 'python3' "$($probe.Source) does not run as Python 3 (it printed: $($probe.Output)) - fix or remove it; -Fix only ever removes the WindowsApps stub" }
            default { Result 'warn' 'python3' 'not found - run: chezmoi apply (deploys the python3 shim to ~\.local\bin), or install Python: choco install python' }
        }
    }
}

if ($script:Errors -gt 0) {
    Write-Host ""
    Write-Host "$($script:Errors) error(s). $(if ($Fix) { '(-Fix applied where safe)' } else { 're-run with -Fix for auto-repairable items' })"
    exit 1
}
Write-Host ""
Write-Host "no errors"
