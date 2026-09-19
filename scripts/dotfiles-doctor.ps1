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
    & chezmoi data *> $null
    if ($LASTEXITCODE -eq 0) {
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
try { $src = (& chezmoi source-path 2>$null | Out-String).Trim() } catch {}
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
try { $installedVersion = ((& chezmoi --version 2>$null | Out-String).Trim() -replace '^chezmoi version ', '') -replace ',.*$', '' } catch {}
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
try { $guardrailPin = (& chezmoi execute-template --source $repoRoot '{{ .guardrail.version }}' 2>$null | Out-String).Trim() } catch {}
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
        try { $have = ((& $grBin version 2>$null | Out-String).Trim() -replace '^guardrail ', '') } catch {}
        if ($have -eq $guardrailPin) {
            Result 'ok' 'guardrail-pin' "guardrail $guardrailPin"
        } else {
            Result 'warn' 'guardrail-pin' "installed $(if ($have) { $have } else { 'unknown' }) vs pin $guardrailPin - run: chezmoi update"
        }
    }
}

} # end not-in-apply (guardrail-pin)

if ($script:Errors -gt 0) {
    Write-Host ""
    Write-Host "$($script:Errors) error(s). $(if ($Fix) { '(-Fix applied where safe)' } else { 're-run with -Fix for auto-repairable items' })"
    exit 1
}
Write-Host ""
Write-Host "no errors"
