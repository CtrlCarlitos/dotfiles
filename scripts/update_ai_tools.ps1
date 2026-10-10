<#
update_ai_tools.ps1 - refresh the AI coding tools and curated skills, no
package-manager sweep (Windows twin of scripts/update_ai_tools.sh). Upgrades
the AI CLIs (Claude Code, Codex, OpenCode, agy, Serena, act) and
re-runs the curated-skill install, honoring DOTUPGRADE_DEFER. Entry points:
`dot upgrade` (which exports the defer list) or direct: .\update_ai_tools.ps1
#>
# Windows PowerShell 5.1 redraws the Invoke-WebRequest progress bar for every
# received chunk, throttling downloads to a crawl. Script-scoped; the child
# `irm | iex` below is a separate process and sets it itself.
$ProgressPreference = 'SilentlyContinue'
# Shared helpers (the current-version checks below); the file sits next to this script.
if ($PSScriptRoot) { . (Join-Path $PSScriptRoot 'lib\ps-common.ps1') }
# Native tools print UTF-8; PowerShell decodes their output with the console's OEM code page,
# so a captured "..." came out as "three CP437 characters" (2026-10-07). Process-local, as in the installer.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { Write-Verbose "console encoding unchanged: $($_.Exception.Message)" }
# Glyphs from code points: this file stays ASCII. Windows PowerShell 5.1 reads a BOM-less file
# as Windows-1252, where a UTF-8 emoji's bytes can include 0x93 - a "smart quote" that ends a
# string ("The term 'upgrading' is not recognized", 2026-10-07). See docs/invariants.md #16.
$G = @{
    robot    = [char]::ConvertFromUtf32(0x1F916)
    package  = [char]::ConvertFromUtf32(0x1F4E6)
    warning  = [string][char]0x26A0 + [char]0xFE0F
    sparkles = [string][char]0x2728
    brain    = [char]::ConvertFromUtf32(0x1F9E0)
    globe    = [char]::ConvertFromUtf32(0x1F310)
    puzzle   = [char]::ConvertFromUtf32(0x1F9E9)
    seedling = [char]::ConvertFromUtf32(0x1F331)
    check    = [string][char]0x2705
}
Write-Host "$($G.robot) Updating AI Coding Tools..." -ForegroundColor Cyan

# Defer protocol: scripts/dotupgrade.ps1 (the ONLY entry point - `dot
# upgrade`) exports DOTUPGRADE_DEFER with the tools whose package dirs
# cannot be recreated while live agent sessions resolve from them.
function Test-Deferred([string]$Tool) { return (@($env:DOTUPGRADE_DEFER -split ',') -contains $Tool) }

Add-DotTimingMark -Name 'NPM packages and OpenCode'
# 1. NPM Packages (Codex) + OpenCode via choco
# OpenCode is NOT npm on Windows anymore: opencode-ai's npm package only
# fetches its real platform binary in a postinstall script, and installs
# where that didn't run leave a dead exe that fails with "not a valid
# application for this OS platform" (confirmed live 2026-08-31). choco is
# the Windows route opencode's own README documents - see
# run_onchange_install_packages.ps1.tmpl #3 for the full story.
if (Get-Command npm -ErrorAction SilentlyContinue) {
    if (Test-Deferred 'codex') {
        Write-Host "  codex deferred - a codex session is live (dot upgrade reports it)." -ForegroundColor Yellow
    } else {
        Write-Host "$($G.package) Updating NPM packages..." -ForegroundColor Yellow
        # Package name from .chezmoidata/agents.yaml, read at runtime like the
        # guardrail pin below. No literal fallback - that would be a copy.
        $codexPkg = ''
        try { $codexPkg = (chezmoi execute-template '{{ .agents.npm.codex }}' | Out-String).Trim() } catch { Write-Verbose "codex package probe failed: $($_.Exception.Message)" }
        if (-not $codexPkg) {
            Write-Host "  codex package name unavailable from chezmoi data - skipping" -ForegroundColor Red
        } else {
            # Never "current" while it cannot start; never upgraded to a release whose binary
            # for this platform is not published yet (scripts/lib/ps-common.ps1).
            Update-CodexNpm -Package $codexPkg
        }
    }
    # The package catalog's npm globals (field `npm`: markdownlint-cli2), read at runtime
    # like the codex name. Updated only when installed and behind; `dot up` installs them.
    $npmTools = @()
    # Templates with a double quote go to chezmoi on STDIN: Windows PowerShell 5.1 strips the
    # quotes inside a native argument (`hasKey . "npm"` reached chezmoi as `hasKey . npm`).
    try { $npmTools = @((('{{ range .catalog.packages }}{{ if hasKey . "npm" }}{{ .npm }} {{ end }}{{ end }}' | chezmoi execute-template | Out-String).Trim() -split ' ') | Where-Object { $_ }) } catch { Write-Verbose "npm tool list probe failed: $($_.Exception.Message)" }
    foreach ($npmTool in $npmTools) {
        npm ls -g --depth=0 $npmTool 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }
        if (Test-NpmGlobalCurrent $npmTool) {
            Write-Host "  $npmTool is current ($script:NpmCurrentVersion)"
        } else {
            if (-not (Install-NpmGlobalLatest -Name $npmTool -Version $script:NpmLatestVersion -Arguments @("$($npmTool)@latest"))) {
                Write-Host "  $npmTool upgrade failed - continuing" -ForegroundColor Red
            }
        }
    }
} else {
    Write-Host "$($G.warning)  npm not found. Skipping npm packages." -ForegroundColor Red
}
# OpenCode is winget's SST.opencode now, upgraded (or held while a session is live) by
# dotupgrade.ps1's winget sweep. A machine where Chocolatey still has it keeps the choco upgrade
# until scripts/migrate-to-winget.ps1 moves it.
$ocChocoLib = Join-Path $(if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { 'C:\ProgramData\chocolatey' }) 'lib\opencode'
if ((Get-Command choco -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $ocChocoLib)) {
    if (Test-Deferred 'opencode') {
        Write-Host "  opencode deferred - an opencode session is live (upgrading it races the running binary)." -ForegroundColor Yellow
    } else {
        Write-Host "$($G.package) Updating OpenCode (choco)..." -ForegroundColor Yellow
        $null = Invoke-ChocoUpgradeAll -Arguments @('upgrade', 'opencode', '-y', '--no-progress')
    }
    # Remove any legacy npm-global opencode-ai shim (dead binary) so it can't
    # shadow choco's binary - the PS profile prepends %APPDATA%\npm to PATH.
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        npm rm -g opencode-ai --loglevel=error --no-progress 2>$null | Out-Null   # its "up to date in 1s" said nothing
    }
}

Add-DotTimingMark -Name 'Superpowers (Antigravity)'
# 1a. Superpowers plugin for Antigravity CLI (agy). agy self-updates
# (checksum verify each run); this just refreshes the plugin.
if (Get-Command agy -ErrorAction SilentlyContinue) {
    Write-Host "$($G.sparkles) Updating Superpowers (Antigravity)..." -ForegroundColor Yellow
    # Its seven-line "Cloning plugin... [ok] superpowers" block said nothing on every run.
    $agyOut = @(& agy plugin install https://github.com/obra/superpowers 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { $agyOut | ForEach-Object { Write-Host "  $_" }; Write-Host "  Superpowers update for Antigravity failed - continuing" -ForegroundColor Red }
}

Add-DotTimingMark -Name 'curated skills'
# 1b. Curated third-party skills via the `skills` CLI (vercel-labs/skills).
# Re-running the same `skills add` re-fetches latest (--copy overwrites). Keep
# this list in sync with run_onchange_install_packages.ps1.tmpl. The CLI
# refreshes $env:USERPROFILE\.claude\skills and $env:USERPROFILE\.agents\skills
# before the Antigravity fan-out. OpenCode and Codex discover the shared path.
# --loglevel=error: npm 12's npx prints a benign "npm notice run ..." hint to
# stderr on every run; under PS 5.1 + $ErrorActionPreference=Stop (if this
# script is dot-sourced from one) `2>$null` doesn't stop that promoting to a
# terminating error - keep stderr empty instead (see installer for full notes).
function Write-CuratedSkillsSkippedSummary {
    foreach ($agent in 'Claude Code', 'OpenCode', 'Antigravity', 'Codex') {
        Write-Host "  Curated skills: $agent installed=0 skipped=$curatedSkillTotal failed=0"
    }
}

# The catalog sits next to this script (both live in the source repo's
# scripts/), and the no-npx fallback above derives its count from it - never a
# literal, which drifted every time the catalog gained a skill.
$curatedCatalog = $null
if ($PSScriptRoot) { $curatedCatalog = Join-Path $PSScriptRoot 'curated-agent-skills.txt' }
$curatedSkillTotal = 0
if (($null -ne $curatedCatalog) -and (Test-Path -LiteralPath $curatedCatalog -PathType Leaf)) {
    foreach ($line in Get-Content -LiteralPath $curatedCatalog) {
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith('#')) { $curatedSkillTotal++ }
    }
}

if (Get-Command npx -ErrorAction SilentlyContinue) {
    Write-Host "$($G.sparkles) Updating curated agent skills (Matt Pocock + Anthropic + Vercel Labs)..." -ForegroundColor Yellow
    # From .chezmoidata/agents.yaml, read at runtime (see $codexPkg above).
    try { $skAgents = @((('{{ join "," .agents.skills.agents }}' | chezmoi execute-template | Out-String).Trim()) -split ',') } catch { $skAgents = @() }
    # Shared with the installer (inlined there at render time): the "already installed from this
    # upstream commit?" check, so an unchanged source costs one git ls-remote instead of an npx fetch.
    if ($PSScriptRoot) { . (Join-Path $PSScriptRoot 'lib\ps-skills.ps1') }
    if ($PSScriptRoot) { Invoke-RetiredSkillsCleanup -ListPath (Join-Path $PSScriptRoot 'retired-agent-skills.txt') }
    # every source's upstream HEAD in one parallel round (Get-SkillsRemoteHead answers from it)
    Read-SkillsUpstreamHead -Repo @('mattpocock/skills', 'anthropics/skills', 'vercel-labs/skills', 'vercel-labs/agent-browser', 'CtrlCarlitos/skills', 'Leonxlnx/taste-skill')
    Invoke-SkillsSource -Label 'Matt Pocock skills' -Repo 'mattpocock/skills' -Skills @('codebase-design', 'domain-modeling', 'grill-with-docs', 'improve-codebase-architecture', 'prototype', 'research', 'grilling', 'handoff', 'teach', 'writing-for-agents', 'pr', 'retro') -Agents $skAgents -Install {
        npx --yes --loglevel=error skills@latest add mattpocock/skills -s codebase-design domain-modeling grill-with-docs improve-codebase-architecture prototype research grilling handoff teach writing-for-agents pr retro -a $skAgents -g -y --copy 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "$($G.warning)  Matt Pocock skills update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
        $LASTEXITCODE -eq 0
    }

    if (Test-SkillsUpToDate -Repo 'mattpocock/skills' -Skills @('mp-code-review') -Agents $skAgents) {
        Write-Host "  mp-code-review: up to date"
    } else {
        $skRepo  = "$env:TEMP\mp-skills-repo"
        $skStage = "$env:TEMP\mp-skills-stage"
        Remove-Item $skRepo, $skStage -Recurse -Force -ErrorAction SilentlyContinue
        git clone --quiet --depth 1 https://github.com/mattpocock/skills $skRepo 2>$null
        $cr = Join-Path $skRepo "skills\engineering\code-review"
        if (-not (Test-Path $cr)) { $cr = Join-Path $skRepo "code-review" }
        if (Test-Path $cr) {
            New-Item -ItemType Directory -Force -Path "$skStage\mp-code-review" | Out-Null
            Copy-Item "$cr\*" -Destination "$skStage\mp-code-review" -Recurse -Force
            $skf = "$skStage\mp-code-review\SKILL.md"
            if (Test-Path $skf) {
                $patched = (Get-Content $skf) -replace '^name:\s.*$', 'name: mp-code-review'
                [System.IO.File]::WriteAllLines($skf, $patched, (New-Object System.Text.UTF8Encoding($false)))
            }
            npx --yes --loglevel=error skills@latest add "$skStage" -s mp-code-review -a $skAgents -g -y --copy 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Host "$($G.warning)  mp-code-review update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
            if ($LASTEXITCODE -eq 0) { Save-SkillsSource; Write-Host "  mp-code-review: installed" }
        }
        Remove-Item $skRepo, $skStage -Recurse -Force -ErrorAction SilentlyContinue
    }

    Invoke-SkillsSource -Label 'frontend-design' -Repo 'anthropics/skills' -Skills @('frontend-design') -Agents $skAgents -Install {
        npx --yes --loglevel=error skills@latest add anthropics/skills -s frontend-design -a $skAgents -g -y --copy 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "$($G.warning)  frontend-design update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
        $LASTEXITCODE -eq 0
    }

    # find-skills (vercel-labs/skills, 3.4M installs) - search/install skills from skills.sh mid-session
    Invoke-SkillsSource -Label 'find-skills' -Repo 'vercel-labs/skills' -Skills @('find-skills') -Agents $skAgents -Install {
        npx --yes --loglevel=error skills@latest add vercel-labs/skills -s find-skills -a $skAgents -g -y --copy 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "$($G.warning)  find-skills update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
        $LASTEXITCODE -eq 0
    }
    # agent-browser (vercel-labs/agent-browser, 843.8K installs) - navigate, click, fill, scrape, screenshot
    Invoke-SkillsSource -Label 'agent-browser' -Repo 'vercel-labs/agent-browser' -Skills @('agent-browser') -Agents $skAgents -Install {
        npx --yes --loglevel=error skills@latest add vercel-labs/agent-browser -s agent-browser -a $skAgents -g -y --copy 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "$($G.warning)  agent-browser update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
        $LASTEXITCODE -eq 0
    }
    # skill-creator (CtrlCarlitos/skills) - our drop-in fork of Anthropic's skill-creator with Windows fixes (pipe reader, UTF-8 file I/O, --project-root); pinned upstream commit + patch queue in that repo, drop when anthropics/skills#1827 lands
    Invoke-SkillsSource -Label 'skill-creator' -Repo 'CtrlCarlitos/skills' -Skills @('skill-creator') -Agents $skAgents -Install {
        npx --yes --loglevel=error skills@latest add CtrlCarlitos/skills -s skill-creator -a $skAgents -g -y --copy 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "$($G.warning)  skill-creator update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
        $LASTEXITCODE -eq 0
    }
    # taste skills (Leonxlnx/taste-skill) - design-taste-frontend (new-page visual direction) + redesign-existing-projects (audit + fix existing UI)
    Invoke-SkillsSource -Label 'taste skills' -Repo 'Leonxlnx/taste-skill' -Skills @('design-taste-frontend', 'redesign-existing-projects') -Agents $skAgents -Install {
        npx --yes --loglevel=error skills@latest add Leonxlnx/taste-skill -s design-taste-frontend redesign-existing-projects -a $skAgents -g -y --copy 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "$($G.warning)  taste skills update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
        $LASTEXITCODE -eq 0
    }
    # code-search (CtrlCarlitos/skills) - search-tool escalation: repo graph > serena > rg > grep, probed once per session
    Invoke-SkillsSource -Label 'code-search' -Repo 'CtrlCarlitos/skills' -Skills @('code-search') -Agents $skAgents -Install {
        npx --yes --loglevel=error skills@latest add CtrlCarlitos/skills -s code-search -a $skAgents -g -y --copy 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "$($G.warning)  code-search update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
        $LASTEXITCODE -eq 0
    }
    # (writing-great-skills removed 2026-09-14: mattpocock renamed it upstream to
    #  writing-for-agents, which is already in the batch above - the old name
    #  failed silently on every run.)

    Invoke-SkillsStatePrune

    $catalog = $curatedCatalog
    if ((-not $catalog) -or -not (Test-Path -LiteralPath $catalog -PathType Leaf)) {
        Write-Host "  Warning: curated skill catalog is unavailable: $catalog" -ForegroundColor Yellow
        Write-CuratedSkillsSkippedSummary
    } else {
        $skills = Get-Content $catalog | Where-Object { $_ -and -not $_.StartsWith('#') }
        $markerPattern = '(?m)^<!-- managed-by: chezmoi-curated-skills -->\r?$'
        $agentTargets = @{
            'Claude Code' = "$env:USERPROFILE\.claude\skills"
            'OpenCode' = "$env:USERPROFILE\.agents\skills"
            'Antigravity' = "$env:USERPROFILE\.gemini\antigravity-cli\skills"
            'Codex' = "$env:USERPROFILE\.agents\skills"
        }
        $skillSummary = @{}
        foreach ($agent in $agentTargets.Keys) {
            $skillSummary[$agent] = @{ installed = 0; skipped = 0; failed = 0 }
        }
        foreach ($skill in $skills) {
            $source = "$env:USERPROFILE\.claude\skills\$skill"
            $targetRoot = "$env:USERPROFILE\.gemini\antigravity-cli\skills"
            $target = Join-Path $targetRoot $skill
            if (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf) {
                $antigravityStatus = 'failed'
                New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
                $temporary = Join-Path $targetRoot ".${skill}.tmp.$([guid]::NewGuid().ToString('N'))"
                $backup = Join-Path $targetRoot ".${skill}.backup.$([guid]::NewGuid().ToString('N'))"
                New-Item -ItemType Directory -Force -Path $temporary | Out-Null
                try {
                    Get-ChildItem -Force -LiteralPath $source | Copy-Item -Destination $temporary -Recurse -Force -ErrorAction Stop
                    if (Test-Path -LiteralPath $target) {
                        Move-Item -LiteralPath $target -Destination $backup -ErrorAction Stop
                        try {
                            Move-Item -LiteralPath $temporary -Destination $target -ErrorAction Stop
                            Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
                            $antigravityStatus = 'installed'
                        } catch {
                            Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
                            Move-Item -LiteralPath $backup -Destination $target -ErrorAction SilentlyContinue
                            Write-Host "  Warning: failed to promote curated skill for Antigravity: $skill" -ForegroundColor Yellow
                        }
                    } else {
                        Move-Item -LiteralPath $temporary -Destination $target -ErrorAction Stop
                        $antigravityStatus = 'installed'
                    }
                } catch {
                    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host "  Warning: failed to copy curated skill for Antigravity: $skill" -ForegroundColor Yellow
                }
            } else {
                $antigravityStatus = 'skipped'
                Write-Host "  Warning: Claude skill missing; skipping Antigravity copy: $skill" -ForegroundColor Yellow
            }

            $commandRoot = "$env:USERPROFILE\.config\opencode\commands"
            $commandFile = Join-Path $commandRoot "$skill.md"
            $source = "$env:USERPROFILE\.agents\skills\$skill"
            if (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf) {
                New-Item -ItemType Directory -Force -Path $commandRoot | Out-Null
                if ((Test-Path -LiteralPath $commandFile -PathType Leaf) -and -not ((Get-Content -Raw -LiteralPath $commandFile) -match $markerPattern)) {
                    Write-Host "  Warning: OpenCode command is user-managed; leaving unchanged: $commandFile" -ForegroundColor Yellow
                } else {
                    $command = "<!-- managed-by: chezmoi-curated-skills -->`r`n---`r`ndescription: Run the $skill skill`r`n---`r`nLoad the native ``$skill`` skill with the skill tool, then follow it for: `$ARGUMENTS`r`n"
                    [System.IO.File]::WriteAllText($commandFile, $command, (New-Object System.Text.UTF8Encoding($false)))
                }
            } elseif ((Test-Path -LiteralPath $commandFile -PathType Leaf) -and ((Get-Content -Raw -LiteralPath $commandFile) -match $markerPattern)) {
                Remove-Item -LiteralPath $commandFile -Force
            }

            foreach ($agent in $agentTargets.Keys) {
                if ($agent -eq 'Antigravity') {
                    $skillSummary[$agent][$antigravityStatus]++
                } elseif ($agent -eq 'Codex' -and $skAgents -notcontains 'codex') {
                    # Codex shares OpenCode's target dir; when this operation does
                    # not select Codex, its summary stays at zero rather than
                    # claiming the shared dir's contents as its own result.
                } else {
                    $skillFile = Join-Path (Join-Path $agentTargets[$agent] $skill) 'SKILL.md'
                    if (Test-Path -LiteralPath $skillFile -PathType Leaf) {
                        $skillSummary[$agent].installed++
                    } else {
                        $skillSummary[$agent].failed++
                    }
                }
            }
        }
        foreach ($agent in 'Claude Code', 'OpenCode', 'Antigravity', 'Codex') {
            Write-Host "  Curated skills: $agent installed=$($skillSummary[$agent].installed) skipped=$($skillSummary[$agent].skipped) failed=$($skillSummary[$agent].failed)"
        }
    }
} else {
    Write-CuratedSkillsSkippedSummary
}

# Superpowers for Codex CLI: the pre-configured Codex plugin marketplace carries
# it, and `codex plugin add` both installs and updates (same command, idempotent
# - like `agy plugin install` above). Defer-aware: the plugin dir is resolved by
# live codex sessions, same premise as the npm upgrade above. The marketplace
# name comes from codex itself - see Get-CodexSuperpowersMarketplace in
# scripts/lib/ps-skills.ps1 for why hardcoding it was wrong.
if (Get-Command codex -ErrorAction SilentlyContinue) {
    if (Test-Deferred 'codex') {
        Write-Host "  codex deferred - Superpowers (Codex) update skipped with it." -ForegroundColor Yellow
    } else {
        Write-Host "$($G.sparkles) Updating Superpowers (Codex)..." -ForegroundColor Yellow
        if (-not (Get-Command Get-CodexSuperpowersMarketplace -ErrorAction SilentlyContinue) -and $PSScriptRoot) { . (Join-Path $PSScriptRoot 'lib\ps-skills.ps1') }
        $cxMarket = Get-CodexSuperpowersMarketplace
        if (-not $cxMarket) {
            Write-Host "  No Codex marketplace lists a superpowers plugin - skipping" -ForegroundColor Yellow
        } else {
            # Its "Added plugin ... / Installed plugin root ..." lines said nothing on every run.
            $cxOut = @(& codex plugin add "superpowers@$cxMarket" 2>&1 | ForEach-Object { "$_" })
            if ($LASTEXITCODE -ne 0) { $cxOut | ForEach-Object { Write-Host "  $_" }; Write-Host "  Superpowers update for Codex failed - continuing" -ForegroundColor Red }
        }
    }
}

Add-DotTimingMark -Name 'guardrail'
# guardrail-section: begin
# 1c. Agent guardrails: single opt-in desired-state flag read from
# ~/.config/chezmoi/chezmoi.toml [data.packages] guardrail (default false,
# same semantics as the installer template). Installation itself lives in
# agent-guardrails (its install.ps1, ADR-0029 there) - binary download,
# checksum, Mark-of-the-Web unblock, user-PATH persistence, the Defender
# exclusion (exact-file scoped; agent-guardrails #146), self-update of an
# older binary, and `guardrail setup` (plane
# wiring, coverage). This script only fetches the pinned release's
# install.ps1 + SHA256SUMS, verifies the installer against SHA256SUMS, and
# runs it FROM THE TEMP FILE with -File (never piped into the session):
#   packages.guardrail true  -> install.ps1 -Version <pin> -State enabled
#   packages.guardrail false -> install.ps1 -Version <pin> -State disabled,
#                               only when guardrail.exe is already installed
#                               (never a download just to disable; nothing
#                               is removed).
# `guardrail setup` prints a WebAuthn approval URL and blocks until the
# operator responds, so the installer's output streams through untouched.
# Unlike the auto-run installer template (which throws and fails the whole
# reconciliation on a bad install), a non-zero installer exit here is a
# WARNING, not fatal - this script keeps going to the remaining tools below,
# matching how every other step in this file degrades. No Invoke-WithTimeout
# here - that helper lives only in the installer template, not this script;
# plain Invoke-WebRequest inside try/catch instead.
# Pin: single source of truth is .chezmoidata.yaml guardrail.version - the
# installer templates render the same key; read it at runtime (this script
# already requires chezmoi - it is invoked through `chezmoi source-path`).
$guardrailEnabled = $false
$guardrailConfig = Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml'
if (Test-Path $guardrailConfig) {
    $inPackages = $false
    foreach ($line in [IO.File]::ReadAllLines($guardrailConfig)) {
        if ($line -match '^\s*\[data\.packages\]\s*$') { $inPackages = $true; continue }
        if ($inPackages -and $line -match '^\s*\[') { $inPackages = $false }
        if ($inPackages -and $line -match '^\s*guardrail\s*=\s*true\s*$') { $guardrailEnabled = $true; break }
    }
}
$guardrailExe = "$env:USERPROFILE\.local\bin\guardrail.exe"
$guardrailState = ""
if ($guardrailEnabled) {
    $guardrailState = "enabled"
} elseif (Test-Path $guardrailExe) {
    $guardrailState = "disabled"
}
$guardrailVersion = ""
if ($guardrailState) {
    try { $guardrailVersion = (chezmoi execute-template '{{ .guardrail.version }}' | Out-String).Trim() } catch { Write-Verbose "guardrail pin probe failed: $($_.Exception.Message)" }
}
if ($guardrailState -and -not $guardrailVersion) {
    Write-Host "  Warning: guardrail pin unavailable from chezmoi data - skipping guardrail steps" -ForegroundColor Red
} elseif (-not $guardrailState) {
    Write-Host "  guardrail disabled in config - nothing to do"
} else {
    $guardrailRepo = "CtrlCarlitos/agent-guardrails"
    # Unique per run (like agent-guardrails' own install.ps1), so a stale or
    # concurrent run's files can never be picked up; every path below removes it.
    $guardrailTmp  = Join-Path $env:TEMP ("guardrail-installer-" + [guid]::NewGuid().ToString('N'))
    $guardrailBase = "https://github.com/$guardrailRepo/releases/download/$guardrailVersion"
    New-Item -ItemType Directory -Force -Path $guardrailTmp | Out-Null
    try {
        # TLS 1.2 first: PS 5.1 defaults can still refuse GitHub's TLS.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "$guardrailBase/install.ps1" -OutFile "$guardrailTmp\install.ps1" -UseBasicParsing
        Invoke-WebRequest -Uri "$guardrailBase/SHA256SUMS" -OutFile "$guardrailTmp\SHA256SUMS" -UseBasicParsing
    } catch { Write-Verbose "guardrail installer download failed: $($_.Exception.Message)" }
    if (-not (Test-Path "$guardrailTmp\install.ps1") -or -not (Test-Path "$guardrailTmp\SHA256SUMS")) {
        Write-Host "  Warning: guardrail installer download failed - skipping" -ForegroundColor Red
        Remove-Item $guardrailTmp -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        # Anchor like the sh twin's `grep " install.sh$"`: file name at end of
        # line, so a longer name can't shadow it; \s*$ also tolerates a
        # trailing CR. try/catch: under this script's possible dot-sourced
        # $ErrorActionPreference=Stop, a Select-String/Get-FileHash failure
        # would otherwise become terminating instead of the warning-not-fatal
        # contract below.
        $want = ""
        $got = ""
        try {
            $m = Select-String -Path "$guardrailTmp\SHA256SUMS" -Pattern " install\.ps1\s*$" | Select-Object -First 1
            if ($m) { $want = ($m.Line.Trim() -split '\s+')[0] }
            $got = (Get-FileHash -Algorithm SHA256 "$guardrailTmp\install.ps1").Hash
        } catch { Write-Verbose "guardrail checksum read failed: $($_.Exception.Message)" }
        if (-not $want -or ($got.ToLower() -ne $want.ToLower())) {
            Write-Host "  Warning: guardrail installer CHECKSUM MISMATCH - not running it" -ForegroundColor Red
            Remove-Item $guardrailTmp -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "  Running agent-guardrails installer $guardrailVersion (-State $guardrailState); approval URL prints here if WebAuthn is required..." -ForegroundColor Yellow
            # Save/restore, not function-local: this block is not inside a
            # function, so an unrestored EAP would leak to the rest of the
            # script. Under EAP=Continue, native stderr from the launched
            # installer can't be promoted into a terminating error; $code is
            # the real signal, taken immediately after the call.
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $code = 1
            $launchFailed = $false
            $launchError = ""
            try {
                # Full output to the apply log (the installer's file); the console gets the
                # filtered view. Invoke-GuardrailInstallerProcess, not a native-command pipeline:
                # `| Tee-Object | Select-GuardrailConsoleLine` relies on PowerShell's own
                # native-command capture, which is RECORD-oriented and withholds a line until it
                # sees that line's newline - so the installer's approval prompt (no trailing
                # newline; the cursor sits after it) never reached the console until the
                # installer had already exited (confirmed live 2026-10-08). This bypasses that
                # capture and reads the installer's output at the byte level instead.
                $guardrailApplyLog = Join-Path $env:USERPROFILE ".local\state\guardrail\apply.log"
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $guardrailApplyLog) | Out-Null
                $code = Invoke-GuardrailInstallerProcess -FilePath 'powershell' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$guardrailTmp\install.ps1", '-Version', $guardrailVersion, '-State', $guardrailState) -LogPath $guardrailApplyLog
            } catch {
                # The native launch itself never started - distinct from a
                # non-zero exit below.
                $launchFailed = $true
                $launchError = $_
            } finally {
                $ErrorActionPreference = $prevEap
            }
            Remove-Item $guardrailTmp -Recurse -Force -ErrorAction SilentlyContinue
            if ($launchFailed) {
                Write-Host "  Warning: guardrail installer could not be started - $launchError - continuing" -ForegroundColor Red
            } elseif ($code -ne 0) {
                Write-Host "  Warning: guardrail installer exited with code $code - continuing" -ForegroundColor Red
            }
        }
    }
}
# guardrail-section: end

Add-DotTimingMark -Name 'Claude Code'
# 2. Claude Code (Native)
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host "$($G.brain) Updating Claude Code..." -ForegroundColor Yellow
    # Re-run strict native installer. URL from .chezmoidata.yaml
    # versions.claude_install_ps1 (#125) - the same key the installer template
    # renders - read at runtime like the guardrail pin below, so `dot upgrade`
    # can never install a different Claude than the installer did (the old
    # storage.googleapis.com URL here vs claude.ai in the installer was
    # exactly that drift).
    $claudeInstallUrl = ''
    try { $claudeInstallUrl = (chezmoi execute-template '{{ .versions.claude_install_ps1 }}' | Out-String).Trim() } catch { Write-Verbose "claude installer URL probe failed: $($_.Exception.Message)" }
    # Deliberately NOT `claude update`: dot upgrade is meant to run with every agent and
    # harness closed (codex and the others cannot be replaced while a session
    # runs, and Claude Code should not be replaced under one either), and with nothing
    # running the full installer is the simple, predictable path.
    # Already the latest? The installer took ~20 s on every run to change nothing. Its npm
    # package carries the same version numbers; an unknown answer re-runs it as before.
    $claudeHave = ''
    $claudeWant = ''
    try {
        $claudeHave = ((& claude --version 2>$null | Select-Object -First 1 | Out-String).Trim() -split '\s+')[0]
        $claudePkg = (chezmoi execute-template '{{ .agents.npm.claude_code_version }}' | Out-String).Trim()
        if ($claudePkg) { $claudeWant = (& npm view $claudePkg version 2>$null | Out-String).Trim() }
    } catch { Write-Verbose "claude version probe failed: $($_.Exception.Message)" }
    if ($claudeHave -and $claudeHave -eq $claudeWant) {
        Write-Host "  Claude Code is current ($claudeHave)"
    } elseif ($claudeInstallUrl) {
        # The installer prints a banner, a location and a "next steps" block on every run; the
        # version is the only news. Its whole output is shown only when it fails.
        $claudeOut = @(& powershell -c "`$ProgressPreference = 'SilentlyContinue'; irm $claudeInstallUrl | iex" 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -eq 0) {
            $claudeVersion = ''
            foreach ($claudeLine in $claudeOut) { if ($claudeLine -match '^\s*Version:\s*(\S+)') { $claudeVersion = $Matches[1] } }
            if (-not $claudeVersion) { $claudeVersion = 'installed' }
            Write-Host "  Claude Code $claudeVersion (installer re-run)"
        } else {
            $claudeOut | ForEach-Object { Write-Host $_ }
            Write-Host "  Claude Code installer failed - continuing" -ForegroundColor Red
        }
    } else {
        Write-Host "  claude installer URL unavailable from chezmoi data - skipping the reinstall" -ForegroundColor Red
    }

    # Superpowers skills plugin
    Write-Host "$($G.sparkles) Updating Superpowers (Claude Code)..." -ForegroundColor Yellow
    # Its "Checking for updates for plugin..." line said nothing on every run: shown only on failure.
    # Named with its marketplace: a machine can carry superpowers from several (project-local
    # installs from claude-plugins-official / superpowers-dev), and the bare name then fails
    # with "installed from more than one marketplace". dotfiles installs this one.
    $cpOut = @(& claude plugin update superpowers@superpowers-marketplace -y 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { $cpOut | ForEach-Object { Write-Host "  $_" }; Write-Host "  Superpowers update for Claude Code failed - continuing" -ForegroundColor Red }
}

Add-DotTimingMark -Name 'Superpowers (OpenCode)'
# 3. Superpowers (OpenCode) - separate from Claude Code's plugin above.
# Not a version-pinned npm dep, so re-running the install pulls the latest
# commit. Uses the same Windows-specific --prefix workaround as the installer.
if (Get-Command opencode -ErrorAction SilentlyContinue) {
    Write-Host "$($G.sparkles) Updating Superpowers (OpenCode)..." -ForegroundColor Yellow
    # --allow-git=all: npm 12+ blocks git-URL dependencies by default (EALLOWGIT)
    # Its "up to date, audited N packages / looking for funding" summary said nothing on every run.
    npm install "superpowers@git+https://github.com/obra/superpowers.git" --prefix "$env:USERPROFILE\.config\opencode" --allow-git=all --loglevel=error --no-progress --fund=false --audit=false 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  Superpowers not installed for OpenCode - skipping" -ForegroundColor Yellow }
}

Add-DotTimingMark -Name 'Playwright Chromium'
# 4. Playwright Chromium (headless browser for agent automation)
if (Get-Command npx -ErrorAction SilentlyContinue) {
    Write-Host "$($G.globe) Updating Playwright Chromium..." -ForegroundColor Yellow
    npx --yes playwright install chromium 2>$null
}

Add-DotTimingMark -Name 'agent-browser'
# 5. agent-browser. Playwright runs first so this CLI can reuse its Chromium.
if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Host "$($G.globe) Updating agent-browser..." -ForegroundColor Yellow
    # Skipped when already the registry's latest (the reinstall always printed "changed 1 package").
    # The browser setup and the verification below still run.
    $abInstalled = $true
    if (Test-NpmGlobalCurrent 'agent-browser') {
        Write-Host "   agent-browser is current ($script:NpmCurrentVersion)"
    } else {
        $abInstalled = Install-NpmGlobalLatest -Name 'agent-browser' -Version $script:NpmLatestVersion -Arguments @('--allow-scripts=agent-browser', 'agent-browser')
    }
    if (-not $abInstalled) {
        Write-Host "   agent-browser install failed - skipping" -ForegroundColor Red
    } else {
        $agentBrowser = Join-Path (npm prefix -g) 'agent-browser.cmd'
        if (Test-Path $agentBrowser) {
            $env:AGENT_BROWSER = $agentBrowser
            # Every run (Chrome updates on its own schedule), but quiet unless it fails - its
            # "Installing Chrome... already installed" printed on every upgrade; the bash twin is quiet.
            $installOutput = @(& $env:AGENT_BROWSER install 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $installOutput | ForEach-Object { Write-Host "   $_" }
                Write-Host "   agent-browser browser setup failed - skipping" -ForegroundColor Red
            }
            $doctorOutput = @(& $env:AGENT_BROWSER doctor --json)
            $doctorExit = $LASTEXITCODE
            Write-AgentBrowserDoctorSummary -Output ($doctorOutput | ForEach-Object { "$_" })
            if ($doctorExit -ne 0) { Write-Host "   agent-browser verification failed - continuing" -ForegroundColor Red }
            Remove-Item Env:\AGENT_BROWSER -ErrorAction SilentlyContinue
        }
    }
}

Add-DotTimingMark -Name 'Serena'
# 6. Serena (uv-managed). Defer-aware: uv recreates the package dir that live
# sessions resolve from (2026-09-20 live incidents).
if (Get-Command serena -ErrorAction SilentlyContinue) {
    if (Test-Deferred 'serena') {
        Write-Host "$($G.puzzle) Serena deferred - a serena process is live (dot upgrade reports it)." -ForegroundColor Yellow
    } else {
        Write-Host "$($G.puzzle) Updating Serena..." -ForegroundColor Yellow
        # uv's own news ("Nothing to upgrade" / "Upgraded serena-agent vX -> vY") prints to
        # stderr, not stdout (confirmed live, uv 0.12.24) - discarding it with 2>$null left
        # this step silent on every run, unlike every other tool here. Capture it instead.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $serenaOutput = @()
        $serenaCode = 1
        try {
            $serenaOutput = @(& uv tool upgrade serena-agent 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            $serenaCode = $LASTEXITCODE
        } catch {
            $serenaOutput = @("$($_.Exception.Message)")
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($serenaCode -ne 0) {
            Write-Host "  Warning: serena upgrade failed (exit $serenaCode) - continuing" -ForegroundColor Red
            $serenaOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        } else {
            $serenaOutput | ForEach-Object { Write-Host "  serena-agent: $_" }
        }
    }
}

Add-DotTimingMark -Name 'Graft retirement'
# 7. Graft was dropped from the dotfiles (2026-10-09): remove it where an earlier run
# installed it (Invoke-GraftRetirement, scripts/lib/ps-skills.ps1; quiet when there is
# nothing to do).
if (-not (Get-Command Invoke-GraftRetirement -ErrorAction SilentlyContinue) -and $PSScriptRoot) { . (Join-Path $PSScriptRoot 'lib\ps-skills.ps1') }
if (Get-Command Invoke-GraftRetirement -ErrorAction SilentlyContinue) { Invoke-GraftRetirement }

Write-DotTimingSummary -Title 'AI tools'
Write-Host "$($G.check) AI Tools Update Complete!" -ForegroundColor Green
