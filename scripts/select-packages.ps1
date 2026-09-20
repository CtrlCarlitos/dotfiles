#Requires -Version 5.1
#
# select-packages.ps1 — interactive package-group menu (gum), Windows twin of
# scripts/select-packages.sh. Persists the 16-group selection to
# [data.packages] in $env:USERPROFILE\.config\chezmoi\chezmoi.toml
# ($env:HOME/.config/... on Linux/macOS pwsh).
#
# Run standalone to re-choose groups at any time, or from install.ps1 before
# `chezmoi init --apply` (spec §4). Design contracts (shared with the .sh twin):
#
#   - CI-safe: without an interactive stdin ($env:CI set, or stdin
#     piped/redirected as under CI — [Console]::IsInputRedirected) or gum on
#     PATH this is a no-op that exits 0 printing "skipping menu" — pre-seeded
#     CI configs never prompt. (Same contract as the .sh twin's [ -t 0 ] gate;
#     UserInteractive was wrong: GitHub Actions runners report it TRUE —
#     run 34730549901's full-install hung gum on redirected stdin for 2h.)
#   - The menu OWNS [data.packages]: a rewrite replaces the whole section
#     (hand-edited keys inside it are intentionally overwritten — re-running
#     the menu means re-choosing). Everything outside the section is
#     byte-preserved (accounts etc.). Unlike the .sh twin (which re-emits the
#     section at EOF), this twin swaps the section IN PLACE via regex —
#     equally valid TOML, and the surrounding layout stays untouched.
#   - Presets are pre-check sets for the menu only, never persisted.
#
# gum invocation shapes (verified against gum 2.0.1 — v2 has no --multi flag;
# --no-limit is the multi-select, --selected is comma-separated and matches the
# option strings exactly):
#   preset: gum choose --header "..." "minimal" "standard" "full" "custom"
#   groups: gum choose --no-limit --header "..." --selected "core,fonts" `
#             core modern_cli ...

$ErrorActionPreference = 'Stop'

function Info([string]$message) { Write-Host $message }
function Warn([string]$message) { Write-Host $message -ForegroundColor Yellow }

$isWin = ($env:OS -eq 'Windows_NT')
$homeDir = if ($isWin) { $env:USERPROFILE } else { $env:HOME }
$configDir = Join-Path $homeDir '.config/chezmoi'
$configFile = Join-Path $configDir 'chezmoi.toml'

# The 16 package groups, taxonomy order (docs/research/package-groups-spec.md
# §2). The single vocabulary shared with the config template, installers, CI.
$pkgGroups = @('core', 'modern_cli', 'fonts', 'agent_toolkit', 'opencode_cli',
    'opencode_desktop', 'claude_cli', 'claude_desktop', 'chatgpt_cli',
    'chatgpt_desktop', 'antigravity_cli', 'antigravity_desktop', 'dev_desktop',
    'remote_access', 'remote_access_server', 'guardrail')

# Preset → pre-check sets (spec §3). Presets are NOT persisted.
function Get-PresetSet([string]$preset) {
    switch ($preset) {
        'minimal' { return @('core') }
        'standard' { return @('core', 'modern_cli', 'fonts', 'agent_toolkit', 'opencode_cli', 'claude_cli', 'guardrail') }
        'full' { return @($script:pkgGroups | Where-Object { $_ -ne 'remote_access_server' }) }
        default { return @() } # custom (or anything unexpected): nothing pre-checked
    }
}

# ---------------------------------------------------------------- gate ------

$gum = Get-Command gum -ErrorAction SilentlyContinue
# Stdin-tty gate, matching the .sh twin's [ -t 0 ]: IsInputRedirected is $true
# whenever stdin is piped/redirected — every CI shape, even where
# UserInteractive is $true (GH Actions window station) and $env:CI is blanked
# (run 34730549901). $env:CI remains as a belt-and-suspenders hint.
if ([Console]::IsInputRedirected -or $env:CI -or -not $gum) {
    Info 'skipping menu (no interactive terminal/gum) - config template prompts or existing config apply as-is'
    exit 0
}

# ---------------------------------------------------------- pre-check -------

# Match the existing [data.packages] section (tolerating the indented header
# the config template emits) up to the next section header or EOF.
$sectionRegex = '(?ms)^[ \t]*\[data\.packages\][ \t]*\r?\n(.*?)(?=^[ \t]*\[|\z)'

$content = ''
$hasSection = $false
$trueKeys = @()
$vscodeSettings = $null
if (Test-Path -LiteralPath $configFile) {
    $content = [IO.File]::ReadAllText($configFile)
    $sectionMatch = [regex]::Match($content, $sectionRegex)
    if ($sectionMatch.Success) {
        $hasSection = $true
        foreach ($line in ($sectionMatch.Groups[1].Value -split '\r?\n')) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*true\s*$') {
                $trueKeys += $Matches[1]
            }
            if ($line -match '^\s*vscode_settings\s*=\s*(true|false)(?:\s*#.*)?\s*$') {
                $vscodeSettings = $Matches[1]
            }
        }
    }
}

$precheck = @()
if ($hasSection) {
    # Re-run: the user's current keys ARE the pre-check (one Enter accepts
    # unchanged). No preset prompt — presets are first-run scaffolding only.
    $precheck = @($pkgGroups | Where-Object { $trueKeys -contains $_ })
} else {
    $preset = ''
    try {
        # try/catch rather than 2>$null: under $ErrorActionPreference=Stop a
        # native command's stderr can promote to a terminating error the
        # redirect can't prevent (the PS 5.1 native-stderr trap).
        $preset = (& gum choose --header 'Preset? minimal=core only | standard=recommended | full=everything | custom=hand-pick' 'minimal' 'standard' 'full' 'custom' | Out-String).Trim()
    } catch {
        $preset = ''
    }
    if ($LASTEXITCODE -ne 0 -or -not $preset) {
        Warn 'preset prompt canceled - config unchanged'
        exit 0
    }
    $precheck = @(Get-PresetSet $preset)
}

# ------------------------------------------------------------- menu ---------

$menuArgs = @('choose', '--no-limit', '--header', 'Toggle package groups (space=toggle, a=all, enter=confirm)')
if ($precheck.Count -gt 0) {
    $menuArgs += @('--selected', ($precheck -join ','))
}
$menuArgs += $pkgGroups

$chosenRaw = @()
try {
    $chosenRaw = @(& gum @menuArgs)
} catch {
    $chosenRaw = @()
}
# gum exits non-zero on cancel/empty selection ("nothing selected") — that's
# an abort, not a hard failure: leave the config untouched.
if ($LASTEXITCODE -ne 0 -or $chosenRaw.Count -eq 0) {
    Warn 'menu canceled - config unchanged'
    exit 0
}

# Map chosen lines back to known keys (ignore anything unrecognized).
$chosen = @($pkgGroups | Where-Object { $chosenRaw -contains $_ })

# ------------------------------------------------------------ persist -------

$nl = [Environment]::NewLine
$lines = @('[data.packages]')
foreach ($group in $pkgGroups) {
    $value = if ($chosen -contains $group) { 'true' } else { 'false' }
    $lines += "  $group = $value"
}
if ($null -ne $vscodeSettings) { $lines += "  vscode_settings = $vscodeSettings" }
$block = ($lines -join $nl) + $nl
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $configFile)) {
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    [IO.File]::WriteAllText($configFile, $block, $utf8NoBom)
} elseif ($hasSection) {
    # In-place section swap. The pattern consumes everything up to (not
    # including) the next section header, including the blank separator line
    # before it — the replacement re-adds that blank when another section
    # follows. MatchEvaluator (not a plain string replacement) so the block
    # itself never goes through $substitution processing.
    $replacePattern = '(?ms)^[ \t]*\[data\.packages\][ \t]*\r?\n.*?(?=^[ \t]*\[|\z)'
    $capturedContent = $content
    $new = [regex]::Replace($content, $replacePattern, {
        param($match)
        if ($match.Index + $match.Length -lt $capturedContent.Length) { $block + $nl } else { $block }
    })
    [IO.File]::WriteAllText($configFile, $new, $utf8NoBom)
} else {
    # No packages section yet: append one after a blank separator line.
    $trimmed = $content.TrimEnd("`r", "`n")
    $new = if ($trimmed) { $trimmed + $nl + $nl + $block } else { $block }
    [IO.File]::WriteAllText($configFile, $new, $utf8NoBom)
}

Info ("saved [data.packages]: " + ($chosen -join ', ') + " (chezmoi apply installs the difference)")
exit 0
