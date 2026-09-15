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
    if ! command -v pwsh >/dev/null 2>&1; then
        printf '%s\n' 'PASS/SKIP: PowerShell runtime generator assertions require pwsh'
        return
    fi

    local fixture
    fixture="$(mktemp)"
    cat > "$fixture" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
trap { Write-Error $_; exit 1 }
$fixtureHome = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-skill-wiring-" + [guid]::NewGuid().ToString('N'))
$expected = "<!-- managed-by: chezmoi-curated-skills -->`r`n---`r`ndescription: Run the handoff skill`r`n---`r`nLoad the native ``handoff`` skill with the skill tool, then follow it for: `$ARGUMENTS`r`n"

try {
    foreach ($generator in $args) {
        $line = (Select-String -Path $generator -Pattern '^\s+\$command = ').Line
        if (-not $line) { throw "command generator not found: $generator" }
        $skill = 'handoff'
        $ARGUMENTS = 'must remain literal'
        Invoke-Expression $line
        if ($command -cne $expected) { throw "malformed command from: $generator" }
    }

    $commands = Join-Path $fixtureHome 'commands'
    New-Item -ItemType Directory -Force -Path $commands | Out-Null
    $marker = 'managed-by: chezmoi-curated-skills'
    $owned = Join-Path $commands 'handoff.md'
    $user = Join-Path $commands 'teach.md'
    $stale = Join-Path $commands 'research.md'
    [IO.File]::WriteAllText($owned, "<!-- $marker -->stale")
    [IO.File]::WriteAllText($user, 'user owned command')
    [IO.File]::WriteAllText($stale, "<!-- $marker -->stale")
    if ((Get-Content -Raw $owned) -like "*$marker*") { [IO.File]::WriteAllText($owned, $expected) }
    if (-not ((Get-Content -Raw $user) -like "*$marker*")) { } else { throw 'user-owned command was not preserved' }
    if ((Get-Content -Raw $stale) -like "*$marker*") { Remove-Item $stale -Force }
    if ([IO.File]::ReadAllText($owned) -cne $expected) { throw 'marker-owned command was not refreshed' }
    if ([IO.File]::ReadAllText($user) -cne 'user owned command') { throw 'user-owned command was overwritten' }
    if (Test-Path $stale) { throw 'stale marker-owned command was not deleted' }
} finally {
    Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
}
POWERSHELL
    pwsh -NoProfile -File "$fixture" "$repo_root/run_onchange_install_packages.ps1.tmpl" "$repo_root/scripts/update_ai_tools.ps1"
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
