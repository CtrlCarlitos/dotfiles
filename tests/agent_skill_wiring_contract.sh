#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
catalog="$repo_root/scripts/curated-agent-skills.txt"
unix_files=(
    run_onchange_install_packages.sh.tmpl
    scripts/update_ai_tools.sh
)
windows_files=(
    run_onchange_install_packages.ps1.tmpl
    scripts/update_ai_tools.ps1
)
required_skills=(
    codebase-design domain-modeling grill-with-docs
    improve-codebase-architecture prototype research grilling handoff teach
    writing-for-agents resolving-merge-conflicts mp-code-review frontend-design
    find-skills agent-browser skill-creator
)
failed=false
scope="${AGENT_SKILL_WIRING_SCOPE:-all}"

if [[ "$scope" != "all" && "$scope" != "unix" && "$scope" != "windows" ]]; then
    printf 'FAIL: AGENT_SKILL_WIRING_SCOPE must be all, unix, or windows\n' >&2
    exit 2
fi

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failed=true
}

require_contains() {
    local file="$1"
    local expected="$2"

    if ! grep -Fq -- "$expected" "$repo_root/$file"; then
        fail "$file must contain $expected"
    fi
}

verify_windows_command_generation() {
    local fixture
    fixture="$(mktemp)"
    cat > "$fixture" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
trap { Write-Error $_; exit 1 }
$fixtureHome = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-skill-wiring-" + [guid]::NewGuid().ToString('N'))

try {
    $opencode = Join-Path (Join-Path $fixtureHome '.config') 'opencode'
    $skills = Join-Path $opencode 'skills'
    $commands = Join-Path $opencode 'commands'
    $handoffSkill = Join-Path $skills 'handoff'
    $teachSkill = Join-Path $skills 'teach'
    $handoffCommand = Join-Path $commands 'handoff.md'
    $teachCommand = Join-Path $commands 'teach.md'
    $researchCommand = Join-Path $commands 'research.md'
    New-Item -ItemType Directory -Force -Path $handoffSkill, $teachSkill, $commands | Out-Null
    Set-Content -LiteralPath (Join-Path $handoffSkill 'SKILL.md') -Value 'handoff skill'
    Set-Content -LiteralPath (Join-Path $teachSkill 'SKILL.md') -Value 'teach skill'
    [System.IO.File]::WriteAllText($handoffCommand, '<!-- managed-by: chezmoi-curated-skills -->stale')
    [System.IO.File]::WriteAllText($teachCommand, 'user owned command')
    [System.IO.File]::WriteAllText($researchCommand, '<!-- managed-by: chezmoi-curated-skills -->stale')
    if (-not (Test-Path -LiteralPath (Join-Path $handoffSkill 'SKILL.md'))) {
        throw 'fixture OpenCode skill was not created'
    }

    $marker = 'managed-by: chezmoi-curated-skills'
    foreach ($skill in 'handoff', 'teach', 'research') {
        $commandFile = Join-Path $commands "$skill.md"
        $source = Join-Path (Join-Path $skills $skill) 'SKILL.md'
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            if ((Test-Path -LiteralPath $commandFile -PathType Leaf) -and -not ((Get-Content -Raw -LiteralPath $commandFile) -like "*$marker*")) {
                continue
            }
            $command = "<!-- managed-by: chezmoi-curated-skills -->`r`n---`r`ndescription: Run the $skill skill`r`n---`r`nLoad the native ``$skill`` skill with the skill tool, then follow it for: `$ARGUMENTS`r`n"
            [System.IO.File]::WriteAllText($commandFile, $command, (New-Object System.Text.UTF8Encoding($false)))
        } elseif ((Test-Path -LiteralPath $commandFile -PathType Leaf) -and ((Get-Content -Raw -LiteralPath $commandFile) -like "*$marker*")) {
            Remove-Item -LiteralPath $commandFile -Force
        }
    }

    $expected = "<!-- managed-by: chezmoi-curated-skills -->`r`n---`r`ndescription: Run the handoff skill`r`n---`r`nLoad the native ``handoff`` skill with the skill tool, then follow it for: `$ARGUMENTS`r`n"
    $actual = [System.IO.File]::ReadAllText($handoffCommand)
    if ($actual -cne $expected) {
        throw "marker-owned OpenCode command content is malformed: $($actual.Replace("`r", '[CR]').Replace("`n", '[LF]'))"
    }
    if ([System.IO.File]::ReadAllText($teachCommand) -cne 'user owned command') {
        throw 'user-owned OpenCode command was overwritten'
    }
    if (Test-Path -LiteralPath $researchCommand) {
        throw 'stale marker-owned OpenCode command was not deleted'
    }
} finally {
    Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
}
POWERSHELL
    pwsh -NoProfile -File "$fixture"
    rm -f "$fixture"
}

if [[ ! -f "$catalog" ]]; then
    fail 'missing curated skill catalog'
else
    actual_skills=()
    while IFS= read -r skill || [[ -n "$skill" ]]; do
        if [[ -z "$skill" ]]; then
            fail 'curated skill catalog must not contain empty lines'
            continue
        fi
        actual_skills+=("$skill")
    done < "$catalog"

    if [[ "${actual_skills[*]}" != "${required_skills[*]}" ]]; then
        fail 'curated skill catalog must contain the required skills in order'
    fi
fi

if [[ "$scope" != "windows" ]]; then
    for file in "${unix_files[@]}"; do
        require_contains "$file" 'curated-agent-skills.txt'
        if grep -Fq -- '-a antigravity' "$repo_root/$file"; then
            fail "$file must not use the Antigravity skills CLI adapter"
        fi

        for target in \
            '$HOME/.claude/skills' \
            '$HOME/.config/opencode/skills' \
            '$HOME/.gemini/antigravity-cli/skills' \
            '$HOME/.codex/skills' \
            '$HOME/.config/opencode/commands'; do
            require_contains "$file" "$target"
        done

        require_contains "$file" 'managed-by: chezmoi-curated-skills'
        require_contains "$file" 'SKILL.md'
        require_contains "$file" '$ARGUMENTS'
        require_contains "$file" 'backup='
        require_contains "$file" 'mv "$target" "$backup"'
        require_contains "$file" 'mv "$backup" "$target"'
        require_contains "$file" 'rm -rf "$backup"'
    done
fi

if [[ "$scope" != "unix" ]]; then
    for file in "${windows_files[@]}"; do
        require_contains "$file" 'curated-agent-skills.txt'
        if grep -Fq -- '-a antigravity' "$repo_root/$file"; then
            fail "$file must not use the Antigravity skills CLI adapter"
        fi

        for target in \
            '$env:USERPROFILE\.claude\skills' \
            '$env:USERPROFILE\.config\opencode\skills' \
            '$env:USERPROFILE\.gemini\antigravity-cli\skills' \
            '$env:USERPROFILE\.codex\skills' \
            '$env:USERPROFILE\.config\opencode\commands'; do
            require_contains "$file" "$target"
        done

        require_contains "$file" "\$skAgents = @('claude-code', 'opencode', 'codex')"
        require_contains "$file" 'managed-by: chezmoi-curated-skills'
        require_contains "$file" '$ARGUMENTS'
        require_contains "$file" 'SKILL.md'
        if grep -Fq -- 'for: ```$ARGUMENTS' "$repo_root/$file"; then
            fail "$file must generate a literal $ARGUMENTS placeholder"
        fi
    done

    verify_windows_command_generation
fi

if [[ "$failed" == true ]]; then
    exit 1
fi

printf '%s\n' 'PASS: agent skill wiring contract'
