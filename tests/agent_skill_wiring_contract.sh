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
    done
fi

if [[ "$failed" == true ]]; then
    exit 1
fi

printf '%s\n' 'PASS: agent skill wiring contract'
