Write-Host "🤖 Updating AI Coding Tools..." -ForegroundColor Cyan

# 1. NPM Packages (Codex) + OpenCode via choco
# OpenCode is NOT npm on Windows anymore: opencode-ai's npm package only
# fetches its real platform binary in a postinstall script, and installs
# where that didn't run leave a dead exe that fails with "not a valid
# application for this OS platform" (confirmed live 2026-08-31). choco is
# the Windows route opencode's own README documents - see
# run_onchange_install_packages.ps1.tmpl #3 for the full story.
if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Host "📦 Updating NPM packages..." -ForegroundColor Yellow
    npm update -g @openai/codex
} else {
    Write-Host "⚠️  npm not found. Skipping npm packages." -ForegroundColor Red
}
if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Host "📦 Updating OpenCode (choco)..." -ForegroundColor Yellow
    choco upgrade opencode -y --no-progress 2>$null
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
if (Get-Command npx -ErrorAction SilentlyContinue) {
    Write-Host "✨ Updating curated agent skills (Matt Pocock + Anthropic + Vercel Labs)..." -ForegroundColor Yellow
    $skAgents = @('claude-code', 'opencode', 'codex')
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
    # skill-creator (anthropics/skills, 380K installs) - skill-authoring lifecycle with benchmarks + eval viewer
    npx --yes --loglevel=error skills@latest add anthropics/skills -s skill-creator -a $skAgents -g -y --copy 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "⚠️  skill-creator update failed (exit $LASTEXITCODE)" -ForegroundColor Red }
    # (writing-great-skills removed 2026-09-14: mattpocock renamed it upstream to
    #  writing-for-agents, which is already in the batch above — the old name
    #  failed silently on every run.)

    $catalog = Join-Path (chezmoi source-path) 'scripts\curated-agent-skills.txt'
    if (-not (Test-Path -LiteralPath $catalog -PathType Leaf)) {
        Write-Host "  Warning: curated skill catalog is unavailable: $catalog" -ForegroundColor Yellow
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
}

# Superpowers for Codex CLI: not automated - see run_onchange_install_packages.ps1.tmpl
# for why (the only scriptable option is structurally incompatible with this
# plugin's manifest format, confirmed via an isolated test, not just an
# interactive-prompt issue). Update it via Codex's own `/plugins` UI.

# 1c. Agent guardrails (agent-guardrails release binary + Claude gen-config).
# Manual-updater twin of the installer's guardrail block: pinned release
# download, checksum-verified, fail-closed on mismatch (never installs an
# unverified binary). Keep $guardrailVersion in sync with
# run_onchange_install_packages.ps1.tmpl (and the .sh pair).
$guardrailVersion = "v0.18.0-dev"
$guardrailRepo    = "CtrlCarlitos/agent-guardrails"
$guardrailDir     = "$env:USERPROFILE\.local\bin"
$guardrailExe     = "$guardrailDir\guardrail.exe"
$guardrailTmp     = "$env:TEMP\guardrail-dl"
$guardrailBase    = "https://github.com/$guardrailRepo/releases/download/$guardrailVersion"

$haveVer = ""
if (Get-Command guardrail -ErrorAction SilentlyContinue) {
    # try/catch, not a bare `2>$null`: under $ErrorActionPreference=Stop a
    # native command's stderr becomes a terminating error the redirect can't
    # prevent (same shape as the installer's version validity check).
    try { $haveVer = (guardrail version 2>&1 | Out-String).Trim() } catch { $haveVer = "" }
}
if ($haveVer -eq "guardrail $guardrailVersion") {
    Write-Host "  guardrail $guardrailVersion already installed" -ForegroundColor Green
} else {
    Write-Host "  Updating guardrail to $guardrailVersion..." -ForegroundColor Yellow
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
    $asset = "guardrail_windows_$arch.exe"
    # No Invoke-WithTimeout here - that helper lives in the installer template,
    # not this script. Plain Invoke-WebRequest inside try/catch, the repo's
    # warning-not-fatal contract.
    try {
        Remove-Item $guardrailTmp -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $guardrailTmp | Out-Null
        Invoke-WebRequest -Uri "$guardrailBase/$asset" -OutFile "$guardrailTmp\$asset" -UseBasicParsing
        Invoke-WebRequest -Uri "$guardrailBase/SHA256SUMS" -OutFile "$guardrailTmp\SHA256SUMS" -UseBasicParsing
        # Anchor like the sh updater's grep: asset name at end-of-line, so a
        # longer name can't shadow this one; \s*$ tolerates a trailing CR. The
        # $m guard fail-closes on an asset-less SHA256SUMS (partial download)
        # instead of crashing.
        $m = Select-String -Path "$guardrailTmp\SHA256SUMS" -Pattern (" " + [regex]::Escape($asset) + "\s*$")
        $want = if ($m) { $m.Line.Split(" ")[0].Trim() } else { "" }
        $got  = (Get-FileHash -Algorithm SHA256 "$guardrailTmp\$asset").Hash.ToLower()
        if ($want -and ($got -eq $want.ToLower())) {
            New-Item -ItemType Directory -Force -Path $guardrailDir | Out-Null
            Copy-Item "$guardrailTmp\$asset" $guardrailExe -Force
            Unblock-File $guardrailExe
            # User-PATH persistence, same contract as the installer.
            $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
            if ($userPath -notlike "*$guardrailDir*") {
                [System.Environment]::SetEnvironmentVariable("Path", "$userPath;$guardrailDir", "User")
            }
            Write-Host "  guardrail updated to $guardrailVersion" -ForegroundColor Green
        } else {
            Write-Host "  Warning: guardrail CHECKSUM MISMATCH for $asset - not installing" -ForegroundColor Red
        }
    } catch {
        Write-Host "  Warning: guardrail update failed or checksum mismatch - skipping" -ForegroundColor Red
    }
    Remove-Item $guardrailTmp -Recurse -Force -ErrorAction SilentlyContinue
}

# Wire into Claude Code (no-op-safe if claude is absent or already wired).
# $LASTEXITCODE - not stderr silence - is the success signal: gen-config
# prints its SUCCESS message to stderr, so this mirrors the installer's
# exit-code-throw contract, but non-fatally (a warning, not a throw).
if ((Test-Path $guardrailExe) -and (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "  Configuring guardrail for Claude Code..." -ForegroundColor Yellow
    try {
        # Captured and printed only on failure (gen-config's SUCCESS message
        # goes to stderr; this script runs at default EAP, so 2>&1 capture
        # cannot trip the PS 5.1 native-stderr trap).
        $gwOut = & $guardrailExe gen-config claude --merge "$env:USERPROFILE\.claude\settings.json" --binary $guardrailExe 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    gen-config said: $($gwOut.Trim())" -ForegroundColor DarkGray
            throw "gen-config exited with code $LASTEXITCODE"
        }
    } catch {
        Write-Host "  Warning: guardrail gen-config claude --merge failed - continuing" -ForegroundColor Red
    }
}

# Same wiring for OpenCode + Antigravity, one guarded block per plane so an
# absent tool skips only its own gen-config. Same contract as the Claude
# block above ($LASTEXITCODE - not stderr silence - is the success signal,
# reported as a warning, not a throw).
if ((Test-Path $guardrailExe) -and (Get-Command opencode -ErrorAction SilentlyContinue)) {
    Write-Host "  Configuring guardrail for OpenCode..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.local\share\guardrail" | Out-Null
    try {
        $gwOut = & $guardrailExe gen-config opencode --merge "$env:USERPROFILE\.config\opencode\opencode.json" --binary $guardrailExe --plugin-dir "$env:USERPROFILE\.local\share\guardrail" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    gen-config said: $($gwOut.Trim())" -ForegroundColor DarkGray
            throw "gen-config exited with code $LASTEXITCODE"
        }
    } catch {
        Write-Host "  Warning: guardrail gen-config opencode --merge failed - continuing" -ForegroundColor Red
    }
}
if ((Test-Path $guardrailExe) -and (Get-Command agy -ErrorAction SilentlyContinue)) {
    Write-Host "  Configuring guardrail for Antigravity..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.gemini\config" | Out-Null
    try {
        $gwOut = & $guardrailExe gen-config antigravity --merge "$env:USERPROFILE\.gemini\config\hooks.json" --binary $guardrailExe 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    gen-config said: $($gwOut.Trim())" -ForegroundColor DarkGray
            throw "gen-config exited with code $LASTEXITCODE"
        }
    } catch {
        Write-Host "  Warning: guardrail gen-config antigravity --merge failed - continuing" -ForegroundColor Red
    }
}

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

# 5. Serena (uv-managed) + Graft (self-upgrading via `graft upgrade`)
if (Get-Command serena -ErrorAction SilentlyContinue) {
    Write-Host "🧩 Updating Serena..." -ForegroundColor Yellow
    try {
        uv tool upgrade serena-agent 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  Warning: serena upgrade failed (exit $LASTEXITCODE) - continuing" -ForegroundColor Red }
    } catch {
        Write-Host "  Warning: serena upgrade failed - continuing" -ForegroundColor Red
    }
}
if (Get-Command graft -ErrorAction SilentlyContinue) {
    Write-Host "🌱 Updating Graft..." -ForegroundColor Yellow
    try {
        graft upgrade 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  Warning: graft upgrade failed (exit $LASTEXITCODE) - continuing" -ForegroundColor Red }
    } catch {
        Write-Host "  Warning: graft upgrade failed - continuing" -ForegroundColor Red
    }
}

Write-Host "✅ AI Tools Update Complete!" -ForegroundColor Green
