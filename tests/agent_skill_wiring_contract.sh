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

verify_unix_no_npx_summaries() {
    local tmp harness output agent
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/bin"
    harness="$tmp/updater.sh"

    awk '/^if command -v npx/{copy=1} /^# Superpowers for Codex/{exit} copy{print}' \
        "$repo_root/scripts/update_ai_tools.sh" > "$harness"
    output="$(PATH="$tmp/bin" "$BASH" "$harness")"

    for agent in 'Claude Code' OpenCode Antigravity Codex; do
        if ! grep -Fqx -- "   Curated skills: $agent installed=0 skipped=16 failed=0" <<< "$output"; then
            fail "Unix updater must report skipped curated skills without npx for $agent"
        fi
    done
}

verify_unix_summary_targets() {
    local file harness output

    for file in "${unix_files[@]}"; do
        harness="$(mktemp)"
        {
            printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
                'AGENTS=(claude-code opencode)' \
                'claude_installed=0; claude_skipped=0; claude_failed=0' \
                'opencode_installed=0; opencode_skipped=0; opencode_failed=0' \
                'codex_installed=0; codex_skipped=0; codex_failed=0'
            awk '/^    record_cli_result\(\) \{/{copy=1} copy{print} copy && /^    }$/{exit}' "$repo_root/$file"
            printf '%s\n' 'record_cli_result installed 1' \
                'printf "%s %s %s\\n" "$claude_installed" "$opencode_installed" "$codex_installed"'
        } > "$harness"
        output="$(bash "$harness")"
        rm -f "$harness"

        if [[ "$output" != '1 1 0' ]]; then
            fail "$file must not count Codex for a skills CLI operation that did not target it"
        fi
    done
}

verify_unix_skill_lifecycle() {
    local tmp config rendered harness output target
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/bin" "$tmp/repo/scripts" "$tmp/home/.claude/skills/handoff" \
        "$tmp/home/.gemini/antigravity-cli/skills/handoff"
    config="$tmp/chezmoi.toml"
    : > "$config"
    rendered="$tmp/installer.sh"
    chezmoi execute-template --config "$config" --source "$tmp/repo" \
        --override-data '{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"packages":{"agent_toolkit":true}}' \
        < "$repo_root/run_onchange_install_packages.sh.tmpl" > "$rendered"
    printf '%s\n' handoff > "$tmp/repo/scripts/curated-agent-skills.txt"
    printf '%s\n' fresh > "$tmp/home/.claude/skills/handoff/SKILL.md"
    printf '%s\n' stale > "$tmp/home/.gemini/antigravity-cli/skills/handoff/SKILL.md"

    cat > "$tmp/bin/npx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
dest="${!#}"
mkdir -p "$dest/skills/engineering/code-review"
printf '%s\n' '---' 'name: code-review' '---' > "$dest/skills/engineering/code-review/SKILL.md"
EOF
    cat > "$tmp/bin/chezmoi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "FAIL: nested chezmoi invocation: $*" >&2
exit 99
EOF
    chmod +x "$tmp/bin/npx" "$tmp/bin/git" "$tmp/bin/chezmoi"

    harness="$tmp/lifecycle.sh"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
            'info() { printf "%s\\n" "$1"; }' 'warn() { printf "WARN: %s\\n" "$1" >&2; }'
        awk '/^net_timeout\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$rendered"
        cat <<'EOF'
mv() {
    if [[ "$1" == *'.handoff.tmp.'* && "$2" == "$HOME/.gemini/antigravity-cli/skills/handoff" ]]; then
        return 1
    fi
    command mv "$@"
}

EOF
verify_unix_claude_attribution() {
    local tmp config rendered harness settings warnings mode
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    config="$tmp/chezmoi.toml"
    rendered="$tmp/installer.sh"
    harness="$tmp/attribution.sh"
    : > "$config"
    chezmoi execute-template --config "$config" --source "$repo_root" \
        --override-data '{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"packages":{"claude_cli":true}}' \
        < "$repo_root/run_onchange_install_packages.sh.tmpl" > "$rendered"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
            'warn() { printf "WARN: %s\\n" "$1" >&2; }' 'SUDO=' \
            'PATH="'"$PATH"'"' \
            'chmod() { [[ "$1" != --reference=* ]] || return 64; command chmod "$@"; }' \
            'uname() { [[ "${CLAUDE_TEST_UNAME:-}" ]] && printf "%s\\n" "$CLAUDE_TEST_UNAME" || command uname "$@"; }' \
            'stat() { if [[ "${CLAUDE_TEST_UNAME:-}" == Darwin && "$1" == -f && "$2" == %Lp ]]; then command stat -c "%a" "$3"; else command stat "$@"; fi; }'
        awk '/^    configure_claude_attribution\(\) \{/{copy=1} copy{print} copy && /^    }$/{exit}' "$rendered"
        printf '%s\n' 'configure_claude_attribution'
    } > "$harness"

    for fixture in new empty zero-byte nested malformed mode; do
        rm -rf "$tmp/$fixture"
        mkdir -p "$tmp/$fixture"
        settings="$tmp/$fixture/.claude/settings.json"
        case "$fixture" in
            empty)
                mkdir -p "${settings%/*}"
                printf '%s\n' '{}' > "$settings"
                ;;
            zero-byte)
                mkdir -p "${settings%/*}"
                : > "$settings"
                ;;
            nested)
                mkdir -p "${settings%/*}"
                printf '%s\n' '{"permissions":{"allow":["Bash(graft:*)"]},"attribution":{"commit":"custom","extra":"keep"}}' > "$settings"
                ;;
            malformed)
                mkdir -p "${settings%/*}"
                printf '%s\n' '{not json' > "$settings"
                cp "$settings" "$settings.original"
                ;;
            mode)
                mkdir -p "${settings%/*}"
                printf '%s\n' '{}' > "$settings"
                chmod 640 "$settings"
                ;;
        esac
        if [[ "$fixture" == malformed ]]; then
            warnings="$(HOME="$tmp/$fixture" bash "$harness" 2>&1)"
            cmp -s "$settings" "$settings.original" || fail 'Unix malformed Claude settings must remain byte-for-byte unchanged'
            grep -Fq 'Could not parse Claude Code settings - leaving them untouched' <<< "$warnings" \
                || fail 'Unix malformed Claude settings must emit a warning'
            continue
        fi
        HOME="$tmp/$fixture" bash "$harness"
        jq -e '.attribution.commit == "" and .attribution.pr == "" and .attribution.sessionUrl == false' "$settings" >/dev/null \
            || fail "Unix Claude attribution must be disabled for $fixture settings"
    done

    mode="$(stat -c '%a' "$tmp/mode/.claude/settings.json")"
    [[ "$mode" == 640 ]] || fail 'Unix Claude attribution merge must preserve the original settings mode'
    mode="$(stat -c '%a' "$tmp/new/.claude/settings.json")"
    [[ "$mode" == 600 ]] || fail 'Unix Claude attribution must create restrictive new settings files'

    settings="$tmp/darwin/.claude/settings.json"
    mkdir -p "${settings%/*}"
    printf '%s\n' '{}' > "$settings"
    chmod 640 "$settings"
    HOME="$tmp/darwin" CLAUDE_TEST_UNAME=Darwin bash "$harness"
    mode="$(stat -c '%a' "$settings")"
    [[ "$mode" == 640 ]] || fail 'Unix Claude attribution merge must preserve the original settings mode on macOS'

    settings="$tmp/nested/.claude/settings.json"
    jq -e '.permissions.allow == ["Bash(graft:*)"] and .attribution.extra == "keep"' "$settings" >/dev/null \
        || fail 'Unix Claude attribution merge must preserve nested settings'
}

verify_windows_claude_attribution() {
    if ! command -v pwsh >/dev/null 2>&1; then
        printf '%s\n' 'PASS/SKIP: PowerShell Claude attribution fixtures require pwsh'
        return
    fi

    local fixture config rendered render_dir
    fixture="$(mktemp)"
    render_dir="$(mktemp -d)"
    config="$render_dir/chezmoi.toml"
    rendered="$render_dir/installer.ps1"
    : > "$config"
    chezmoi execute-template --config "$config" --source "$repo_root" \
        --override-data '{"chezmoi":{"os":"windows"},"packages":{"claude_cli":true}}' \
        < "$repo_root/run_onchange_install_packages.ps1.tmpl" > "$rendered"
    cat > "$fixture" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$source = Get-Content -Raw -LiteralPath $args[0]
$match = [regex]::Match($source, '(?ms)^function Set-ClaudeAttribution \{.*?^\}')
if (-not $match.Success) { throw 'Claude attribution merger not found' }
$usesWindowsReplace = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($usesWindowsReplace -and $match.Value -notmatch '\[System\.IO\.File\]::Replace\(\$temporary, \$settings, \$null\)') { throw 'Windows Claude attribution must atomically replace existing settings' }
if (-not $usesWindowsReplace -and $match.Value -notmatch '\[System\.IO\.File\]::Move\(\$temporary, \$settings, \$true\)') { throw 'non-Windows Claude attribution must safely replace existing settings' }
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-attribution-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($fixture in 'new', 'empty', 'zero-byte', 'nested', 'malformed') {
        $fixtureHome = Join-Path $fixtureRoot $fixture
        $settings = Join-Path $fixtureHome '.claude\settings.json'
        if ($fixture -eq 'empty') {
            New-Item -ItemType Directory -Force -Path (Split-Path $settings) | Out-Null
            [IO.File]::WriteAllText($settings, '{}')
        } elseif ($fixture -eq 'zero-byte') {
            New-Item -ItemType Directory -Force -Path (Split-Path $settings) | Out-Null
            [IO.File]::WriteAllText($settings, '')
        } elseif ($fixture -eq 'nested') {
            New-Item -ItemType Directory -Force -Path (Split-Path $settings) | Out-Null
            [IO.File]::WriteAllText($settings, '{"permissions":{"allow":["Bash(graft:*)"]},"attribution":{"commit":"custom","extra":"keep"}}')
        } elseif ($fixture -eq 'malformed') {
            New-Item -ItemType Directory -Force -Path (Split-Path $settings) | Out-Null
            [IO.File]::WriteAllText($settings, '{not json')
            Copy-Item -LiteralPath $settings -Destination "$settings.original"
        }
        $env:USERPROFILE = $fixtureHome
        $warnings = & ([scriptblock]::Create($match.Value + "`nSet-ClaudeAttribution")) 3>&1 2>&1
        if ($fixture -eq 'malformed') {
            if ((Get-Content -Raw -LiteralPath $settings) -cne (Get-Content -Raw -LiteralPath "$settings.original")) { throw 'malformed settings changed' }
            if ($warnings -notmatch 'Could not parse Claude Code settings - leaving them untouched') { throw 'malformed settings warning missing' }
            continue
        }
        $json = Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json
        if ($json.attribution.commit -ne '' -or $json.attribution.pr -ne '' -or $json.attribution.sessionUrl -ne $false) { throw "attribution not disabled: $fixture" }
    }
    $nested = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'nested\.claude\settings.json') | ConvertFrom-Json
    if ($nested.permissions.allow -cne 'Bash(graft:*)' -or $nested.attribution.extra -cne 'keep') { throw 'nested settings not preserved' }
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
POWERSHELL
    pwsh -NoProfile -File "$fixture" "$rendered"
    rm -rf "$render_dir"
    rm -f "$fixture"
}
:
        awk '/^install_agent_skills\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$rendered"
        printf '%s\n' 'install_agent_skills'
    } > "$harness"

    output="$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash "$harness")"
    if ! grep -Fqx -- 'Curated skills: Antigravity installed=0 skipped=0 failed=1' <<< "$output"; then
        fail 'Unix lifecycle must report a failed Antigravity promotion'
    fi
    target="$tmp/home/.gemini/antigravity-cli/skills/handoff/SKILL.md"
    if [[ ! -f "$target" || "$(<"$target")" != stale ]]; then
        fail 'Unix lifecycle must restore the stale Antigravity target after promotion failure'
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

    $fixtureRepo = Join-Path $fixtureHome 'repo'
    $catalogDir = Join-Path $fixtureRepo 'scripts'
    $claudeSkill = Join-Path $fixtureHome '.claude\skills\handoff'
    $openCodeSkill = Join-Path $fixtureHome '.agents\skills\handoff'
    $teachSkill = Join-Path $fixtureHome '.agents\skills\teach'
    $antigravitySkill = Join-Path $fixtureHome '.gemini\antigravity-cli\skills\handoff'
    $commands = Join-Path $fixtureHome '.config\opencode\commands'
    $owned = Join-Path $commands 'handoff.md'
    $user = Join-Path $commands 'teach.md'
    $stale = Join-Path $commands 'research.md'
    New-Item -ItemType Directory -Force -Path $catalogDir, $claudeSkill, $openCodeSkill, $teachSkill, $antigravitySkill, $commands | Out-Null
    [IO.File]::WriteAllText((Join-Path $catalogDir 'curated-agent-skills.txt'), "handoff`nteach`nresearch`n")
    [IO.File]::WriteAllText((Join-Path $claudeSkill 'SKILL.md'), 'claude handoff')
    [IO.File]::WriteAllText((Join-Path $claudeSkill '.hidden'), 'must be copied')
    [IO.File]::WriteAllText((Join-Path $openCodeSkill 'SKILL.md'), 'opencode handoff')
    [IO.File]::WriteAllText((Join-Path $teachSkill 'SKILL.md'), 'opencode teach')
    [IO.File]::WriteAllText((Join-Path $antigravitySkill 'SKILL.md'), 'stale antigravity handoff')
    [IO.File]::WriteAllText($owned, "<!-- managed-by: chezmoi-curated-skills -->`nstale")
    [IO.File]::WriteAllText($user, 'user text mentioning managed-by: chezmoi-curated-skills is not an ownership marker')
    [IO.File]::WriteAllText($stale, "<!-- managed-by: chezmoi-curated-skills -->`nstale")

    function chezmoi {
        param([string]$Command)
        if ($Command -ne 'source-path') { throw "unexpected chezmoi command: $Command" }
        if ($script:rejectNestedChezmoi) { throw 'nested chezmoi invocation' }
        $fixtureRepo
    }

    $previousHome = $env:USERPROFILE
    try {
        $env:USERPROFILE = $fixtureHome
        foreach ($lifecycle in $args) {
            $script:rejectNestedChezmoi = ($lifecycle -eq $args[0])
            $source = Get-Content -Raw -LiteralPath $lifecycle
            $match = [regex]::Match($source, '(?ms)^    \$catalog =.*?^    \}\r?$(?=\r?\n\})')
            if (-not $match.Success) { throw "curated skill lifecycle not found in $lifecycle" }

            $lifecycleBody = "`$skAgents = @('claude-code', 'opencode')`n" + ($match.Value -replace '(?m)^    \$catalog =', @'
    function Move-Item {
        param($LiteralPath, $Destination, $ErrorAction)
        if ($LiteralPath -like '*.handoff.tmp.*' -and $Destination -eq $antigravitySkill) {
            throw 'simulated Antigravity promotion failure'
        }
        Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    }
    $catalog =
'@
            )
            $output = & ([scriptblock]::Create($lifecycleBody)) 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { $_.MessageData } else { $_ }
            }
            if (($output -join "`n") -notmatch 'Curated skills: Codex installed=0 skipped=0 failed=0') {
                throw "Codex summary counted a shared OpenCode skill for an OpenCode-only operation: $lifecycle"
            }
            if (($output -join "`n") -notmatch 'Curated skills: Antigravity installed=0 .* failed=1') {
                throw "Antigravity summary reported stale skill as installed: $lifecycle"
            }
            & ([scriptblock]::Create($match.Value)) | Out-Null
        }
    } finally {
        $env:USERPROFILE = $previousHome
    }

    if ([IO.File]::ReadAllText($owned) -cne $expected) { throw 'marker-owned command was not refreshed' }
    if ([IO.File]::ReadAllText($user) -ne 'user text mentioning managed-by: chezmoi-curated-skills is not an ownership marker') { throw 'substring marker command was overwritten' }
    if (Test-Path $stale) { throw 'stale marker-owned command was not deleted' }
    if (-not (Test-Path (Join-Path $fixtureHome '.gemini\antigravity-cli\skills\handoff\.hidden'))) { throw 'hidden Antigravity skill file was not copied' }
} finally {
    Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
}
POWERSHELL
    local config rendered
    local render_dir
    render_dir="$(mktemp -d)"
    config="$render_dir/chezmoi.toml"
    rendered="$render_dir/installer.ps1"
    : > "$config"
    chezmoi execute-template --config "$config" --source "$repo_root" \
        --override-data '{"chezmoi":{"os":"windows"},"packages":{"agent_toolkit":true}}' \
        < "$repo_root/run_onchange_install_packages.ps1.tmpl" > "$rendered"
    pwsh -NoProfile -File "$fixture" "$rendered" "$repo_root/scripts/update_ai_tools.ps1"
    rm -rf "$render_dir"
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
    verify_unix_no_npx_summaries
    verify_unix_summary_targets
    verify_unix_skill_lifecycle
    verify_unix_claude_attribution

    for file in "${unix_files[@]}"; do
        require_contains "$file" 'curated-agent-skills.txt'
        require_contains "$file" 'AGENTS=(claude-code opencode codex)'
        if grep -Fq -- '-a antigravity' "$repo_root/$file"; then
            fail "$file must not use the Antigravity skills CLI adapter"
        fi

        for target in \
            '$HOME/.claude/skills' \
            '$HOME/.agents/skills' \
            '$HOME/.gemini/antigravity-cli/skills' \
            '$HOME/.config/opencode/commands'; do
            require_contains "$file" "$target"
        done

        require_contains "$file" 'managed-by: chezmoi-curated-skills'
        require_contains "$file" 'SKILL.md'
        require_contains "$file" '$ARGUMENTS'
        require_contains "$file" '$HOME/.agents/skills/$skill'
        require_contains "$file" 'backup='
        require_contains "$file" 'mv "$target" "$backup"'
        require_contains "$file" 'mv "$backup" "$target"'
        require_contains "$file" 'rm -rf "$backup"'
        for agent in 'Claude Code' OpenCode Antigravity Codex; do
        require_contains "$file" "Curated skills: $agent installed="
        done
    done
    require_contains 'run_onchange_install_packages.sh.tmpl' "{{ .chezmoi.sourceDir | replace \"'\" \"'\\\"'\\\"'\" }}"
    require_contains 'run_onchange_install_packages.sh.tmpl' 'claude mcp get serena'
fi

if [[ "$scope" != "unix" ]]; then
    for file in "${windows_files[@]}"; do
        require_contains "$file" 'curated-agent-skills.txt'
        if grep -Fq -- '-a antigravity' "$repo_root/$file"; then
            fail "$file must not use the Antigravity skills CLI adapter"
        fi

        for target in \
            '$env:USERPROFILE\.claude\skills' \
            '$env:USERPROFILE\.agents\skills' \
            '$env:USERPROFILE\.gemini\antigravity-cli\skills' \
            '$env:USERPROFILE\.config\opencode\commands'; do
            require_contains "$file" "$target"
        done

        if grep -F -- "\$skAgents = @(" "$repo_root/$file" | grep -Fvq -- "'codex'"; then
            fail "$file must include codex in every skills CLI agent array"
        fi
        require_contains "$file" 'managed-by: chezmoi-curated-skills'
        require_contains "$file" "\$markerPattern = '(?m)^<!-- managed-by: chezmoi-curated-skills -->\\r?$'"
        require_contains "$file" 'Get-ChildItem -Force -LiteralPath $source | Copy-Item'
        require_contains "$file" 'Curated skills: $agent installed='
        require_contains "$file" '$ARGUMENTS'
        require_contains "$file" 'SKILL.md'
        require_contains "$file" '$env:USERPROFILE\.agents\skills\$skill'
        if grep -Fq -- 'for: ```$ARGUMENTS' "$repo_root/$file"; then
            fail "$file must generate a literal $ARGUMENTS placeholder"
        fi
    done

    verify_windows_command_generation
    verify_windows_claude_attribution
    require_contains 'run_onchange_install_packages.ps1.tmpl' '{{- if or $claude_cli $antigravity_cli $agent_toolkit $opencode_cli $chatgpt_cli }}'
    require_contains 'run_onchange_install_packages.ps1.tmpl' "{{ .chezmoi.sourceDir | replace \"'\" \"''\" }}"
    require_contains 'run_onchange_install_packages.ps1.tmpl' 'claude mcp get serena'
fi

if [[ "$failed" == true ]]; then
    exit 1
fi

printf '%s\n' 'PASS: agent skill wiring contract'
