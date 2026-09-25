<#
update_ai_tools.ps1 - refresh the AI coding tools and curated skills, no
package-manager sweep (Windows twin of scripts/update_ai_tools.sh). Upgrades
the AI CLIs (Claude Code, Codex, OpenCode, agy, Serena, Graft, act) and
re-runs the curated-skill install, honoring DOTUPGRADE_DEFER. Entry points:
`dot upgrade` (which exports the defer list) or direct: .\update_ai_tools.ps1
#>
Write-Host "🤖 Updating AI Coding Tools..." -ForegroundColor Cyan

# Defer protocol: scripts/dotupgrade.ps1 (the ONLY entry point - `dot
# upgrade`) exports DOTUPGRADE_DEFER with the tools whose package dirs
# cannot be recreated while live agent sessions resolve from them.
function Test-Deferred([string]$Tool) { return (@($env:DOTUPGRADE_DEFER -split ',') -contains $Tool) }

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
        Write-Host "📦 Updating NPM packages..." -ForegroundColor Yellow
        # Package name from .chezmoidata/agents.yaml, read at runtime like the
        # guardrail pin below. No literal fallback - that would be a copy.
        $codexPkg = ''
        try { $codexPkg = (chezmoi execute-template '{{ .agents.npm.codex }}' | Out-String).Trim() } catch {}
        if (-not $codexPkg) {
            Write-Host "  codex package name unavailable from chezmoi data - skipping" -ForegroundColor Red
        } else {
            npm install -g "$($codexPkg)@latest" --loglevel=error --no-progress --fetch-timeout=120000 --fetch-retries=2 2>$null
        }
    }
} else {
    Write-Host "⚠️  npm not found. Skipping npm packages." -ForegroundColor Red
}
if (Get-Command choco -ErrorAction SilentlyContinue) {
    if (Test-Deferred 'opencode') {
        Write-Host "  opencode deferred - an opencode session is live (upgrading it races the running binary)." -ForegroundColor Yellow
    } else {
        Write-Host "📦 Updating OpenCode (choco)..." -ForegroundColor Yellow
        choco upgrade opencode -y --no-progress 2>$null
    }
    # Remove any legacy npm-global opencode-ai shim (dead binary) so it can't
    # shadow choco's binary - the PS profile prepends %APPDATA%\npm to PATH.
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        npm rm -g opencode-ai --loglevel=error --no-progress 2>$null
    }
}

# 1a. Superpowers plugin for Antigravity CLI (agy). agy self-updates
# (checksum verify each run); this just refreshes the plugin.
if (Get-Command agy -ErrorAction SilentlyContinue) {
    Write-Host "✨ Updating Superpowers (Antigravity)..." -ForegroundColor Yellow
    agy plugin install https://github.com/obra/superpowers 2>$null
}

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
        Write-Host "  Curated skills: $agent installed=0 skipped=19 failed=0"
    }
}

if (Get-Command npx -ErrorAction SilentlyContinue) {
    Write-Host "✨ Updating curated agent skills (Matt Pocock + Anthropic + Vercel Labs)..." -ForegroundColor Yellow
    # From .chezmoidata/agents.yaml, read at runtime (see $codexPkg above).
    try { $skAgents = @(((chezmoi execute-template '{{ join "," .agents.skills.agents }}' | Out-String).Trim()) -split ',') } catch { $skAgents = @() }
    npx --yes --loglevel=error skills@latest add mattpocock/skills -s codebase-design domain-modeling grill-with-docs improve-codebase-architecture prototype research grilling handoff teach writing-for-agents resolving-merge-conflicts -a $skAgents -g -y --copy 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "⚠️  Matt Pocock skills update failed (exit $LASTEXITCODE)" -ForegroundColor Red }

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
        if ($LASTEXITCODE -ne 0) { Write-Host "⚠️  mp-code-review update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
    }
    Remove-Item $skRepo, $skStage -Recurse -Force -ErrorAction SilentlyContinue

    npx --yes --loglevel=error skills@latest add anthropics/skills -s frontend-design -a $skAgents -g -y --copy 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "⚠️  frontend-design update failed (exit $LASTEXITCODE)" -ForegroundColor Red }

    # find-skills (vercel-labs/skills, 3.4M installs) - search/install skills from skills.sh mid-session
    npx --yes --loglevel=error skills@latest add vercel-labs/skills -s find-skills -a $skAgents -g -y --copy 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "⚠️  find-skills update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
    # agent-browser (vercel-labs/agent-browser, 843.8K installs) - navigate, click, fill, scrape, screenshot
    npx --yes --loglevel=error skills@latest add vercel-labs/agent-browser -s agent-browser -a $skAgents -g -y --copy 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "⚠️  agent-browser update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
    # skill-creator (CtrlCarlitos/skills) - our drop-in fork of Anthropic's skill-creator with Windows fixes (pipe reader, UTF-8 file I/O, --project-root); pinned upstream commit + patch queue in that repo, drop when anthropics/skills#1827 lands
    npx --yes --loglevel=error skills@latest add CtrlCarlitos/skills -s skill-creator -a $skAgents -g -y --copy 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "⚠️  skill-creator update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
    # taste skills (Leonxlnx/taste-skill) - design-taste-frontend (new-page visual direction) + redesign-existing-projects (audit + fix existing UI)
    npx --yes --loglevel=error skills@latest add Leonxlnx/taste-skill -s design-taste-frontend redesign-existing-projects -a $skAgents -g -y --copy 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "⚠️  taste skills update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
    # code-search (CtrlCarlitos/skills) - search-tool escalation: graft > serena > rg > grep, probed once per session
    npx --yes --loglevel=error skills@latest add CtrlCarlitos/skills -s code-search -a $skAgents -g -y --copy 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "⚠️  code-search update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
    # (writing-great-skills removed 2026-09-14: mattpocock renamed it upstream to
    #  writing-for-agents, which is already in the batch above — the old name
    #  failed silently on every run.)

    $catalog = Join-Path (chezmoi source-path) 'scripts\curated-agent-skills.txt'
    if (-not (Test-Path -LiteralPath $catalog -PathType Leaf)) {
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
                } elseif ($agent -ne 'Codex' -or $skAgents -contains 'codex') {
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

# Superpowers for Codex CLI: not automated - see run_onchange_install_packages.ps1.tmpl
# for why (the only scriptable option is structurally incompatible with this
# plugin's manifest format, confirmed via an isolated test, not just an
# interactive-prompt issue). Update it via Codex's own `/plugins` UI.

# guardrail-section: begin
# 1c. Agent guardrails: single opt-in desired-state flag read from
# ~/.config/chezmoi/chezmoi.toml [data.packages] guardrail (default false,
# same semantics as the installer template). Installation itself lives in
# agent-guardrails (its install.ps1, ADR-0029 there) - binary download,
# checksum, Mark-of-the-Web unblock, user-PATH persistence, the Defender
# exclusion, self-update of an older binary, and `guardrail setup` (plane
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
    try { $guardrailVersion = (chezmoi execute-template '{{ .guardrail.version }}' | Out-String).Trim() } catch {}
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
    } catch {}
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
        } catch {}
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
                & powershell -NoProfile -ExecutionPolicy Bypass -File "$guardrailTmp\install.ps1" -Version $guardrailVersion -State $guardrailState
                $code = $LASTEXITCODE
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

# 2. Claude Code (Native)
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host "🧠 Updating Claude Code..." -ForegroundColor Yellow
    # Re-run strict native installer
    & powershell -c "irm https://storage.googleapis.com/claude-code/install.ps1 | iex"

    # Superpowers skills plugin
    Write-Host "✨ Updating Superpowers (Claude Code)..." -ForegroundColor Yellow
    claude plugin update superpowers -y 2>$null
}

# 3. Superpowers (OpenCode) - separate from Claude Code's plugin above.
# Not a version-pinned npm dep, so re-running the install pulls the latest
# commit. Uses the same Windows-specific --prefix workaround as the installer.
if (Get-Command opencode -ErrorAction SilentlyContinue) {
    Write-Host "✨ Updating Superpowers (OpenCode)..." -ForegroundColor Yellow
    # --allow-git=all: npm 12+ blocks git-URL dependencies by default (EALLOWGIT)
    npm install "superpowers@git+https://github.com/obra/superpowers.git" --prefix "$env:USERPROFILE\.config\opencode" --allow-git=all --loglevel=error --no-progress 2>$null
}

# 4. Playwright Chromium (headless browser for agent automation)
if (Get-Command npx -ErrorAction SilentlyContinue) {
    Write-Host "🌐 Updating Playwright Chromium..." -ForegroundColor Yellow
    npx --yes playwright install chromium 2>$null
}

# 5. agent-browser. Playwright runs first so this CLI can reuse its Chromium.
if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Host "🌐 Updating agent-browser..." -ForegroundColor Yellow
    npm install -g --allow-scripts=agent-browser agent-browser --loglevel=error --no-progress 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "   agent-browser install failed - skipping" -ForegroundColor Red
    } else {
        $agentBrowser = Join-Path (npm prefix -g) 'agent-browser.cmd'
        if (Test-Path $agentBrowser) {
            $env:AGENT_BROWSER = $agentBrowser
            & $env:AGENT_BROWSER install
            if ($LASTEXITCODE -ne 0) { Write-Host "   agent-browser browser setup failed - skipping" -ForegroundColor Red }
            & $env:AGENT_BROWSER doctor --json
            if ($LASTEXITCODE -ne 0) { Write-Host "   agent-browser verification failed - continuing" -ForegroundColor Red }
            Remove-Item Env:\AGENT_BROWSER -ErrorAction SilentlyContinue
        }
    }
}

# 6. Serena (uv-managed) + Graft (self-upgrading via `graft upgrade`).
# Both are defer-aware: uv/graft recreate package dirs that live sessions
# resolve from (2026-09-20 live incidents).
if (Get-Command serena -ErrorAction SilentlyContinue) {
    if (Test-Deferred 'serena') {
        Write-Host "🧩 Serena deferred - a serena process is live (dot upgrade reports it)." -ForegroundColor Yellow
    } else {
        Write-Host "🧩 Updating Serena..." -ForegroundColor Yellow
        try {
            uv tool upgrade serena-agent 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Host "  Warning: serena upgrade failed (exit $LASTEXITCODE) - continuing" -ForegroundColor Red }
        } catch {
            Write-Host "  Warning: serena upgrade failed - continuing" -ForegroundColor Red
        }
    }
}
if (Get-Command graft -ErrorAction SilentlyContinue) {
    if (Test-Deferred 'graft') {
        Write-Host "🌱 Graft deferred - agent session(s) are live; graft's dir is resolved by every hook event (dot upgrade reports it)." -ForegroundColor Yellow
    } else {
        Write-Host "🌱 Updating Graft..." -ForegroundColor Yellow
        try {
            graft upgrade 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Host "  Warning: graft upgrade failed (exit $LASTEXITCODE) - continuing" -ForegroundColor Red }
        } catch {
            Write-Host "  Warning: graft upgrade failed - continuing" -ForegroundColor Red
        }
    }
}

Write-Host "✅ AI Tools Update Complete!" -ForegroundColor Green
