#!/usr/bin/env bash
set -euo pipefail

# Curated-skill wiring contract across the four agent CLIs.
#
# This file was structurally broken from the commit that introduced it until
# 2026-09-22, in a way nothing could see:
#   - Two functions (verify_unix_skill_lifecycle, verify_windows_command_generation)
#     ended right after a heredoc; their closing lines had been displaced further
#     down the file (one left a stray `:` placeholder). Everything between was
#     therefore NESTED inside them, so the windows-scope functions only existed
#     if the unix scope had already run. `bash -n` is happy with this.
#   - The CI lint job had no chezmoi, so every rendering assertion early-returned
#     "PASS/SKIP: ... requires chezmoi". Green, validating only the greps.
# Both are fixed (ci.yml now installs the pinned chezmoi). When touching this
# file, verify the functions actually exist at runtime, not just on screen:
#   head -n <line before the main section> "$0" > /tmp/probe.sh
#   bash -c 'source /tmp/probe.sh; declare -F | grep -c verify_'   # expect 8

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

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
    design-taste-frontend redesign-existing-projects
    code-search
)
scope="${AGENT_SKILL_WIRING_SCOPE:-all}"
# On Windows (Git Bash) only the windows scope can hold: the unix half asserts
# POSIX file modes and runs the .sh twins. CI runs both scopes on Linux; an
# explicit AGENT_SKILL_WIRING_SCOPE still wins.
case "${OSTYPE:-}" in
    msys*|cygwin*|win32)
        if [[ -z "${AGENT_SKILL_WIRING_SCOPE:-}" ]]; then
            scope=windows
            printf 'NOTE: Windows host - running the windows scope (unix scope needs a Unix host)\n'
        fi
        ;;
esac

if [[ "$scope" != "all" && "$scope" != "unix" && "$scope" != "windows" ]]; then
    printf 'FAIL: AGENT_SKILL_WIRING_SCOPE must be all, unix, or windows\n' >&2
    exit 2
fi

require_contains() {
    local file="$1"
    local expected="$2"

    require "$repo_root/$file" "$expected"
}

verify_unix_no_npx_summaries() {
    local tmp harness output agent expected
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/bin"
    # The no-npx fallback derives its skipped count from the catalog next to
    # the script, so the fixture lays the file out the way the source repo does.
    cp "$repo_root/scripts/curated-agent-skills.txt" "$tmp/"
    expected="$(grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$repo_root/scripts/curated-agent-skills.txt")"
    harness="$tmp/updater.sh"

    awk '/^# 1b\. Curated third-party skills/{copy=1} /^# Superpowers for Codex/{exit} copy{print}' \
        "$repo_root/scripts/update_ai_tools.sh" > "$harness"
    output="$(PATH="$tmp/bin" "$BASH" "$harness")"

    for agent in 'Claude Code' OpenCode Antigravity Codex; do
        if ! grep -Fqx -- "   Curated skills: $agent installed=0 skipped=$expected failed=0" <<< "$output"; then
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

verify_unix_supported_target_counts() {
    local tmp config rendered harness updater_harness output agent
    if ! command -v chezmoi >/dev/null 2>&1; then
        printf '%s\n' 'PASS/SKIP: Unix target rendering requires chezmoi'
        return
    fi
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/bin" "$tmp/repo/scripts" "$tmp/home/.claude/skills/handoff"
    config="$tmp/chezmoi.toml"
    rendered="$tmp/installer.sh"
    : > "$config"
    # The scratch source needs the repo's data (guardrail.version, vscode, ...):
    # without it the installer template fails on `.guardrail.version`.
    cp "$repo_root/.chezmoidata.yaml" "$tmp/repo/"
    cp -r "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$tmp/repo/"   # catalog + fragments the installers include
    chezmoi execute-template --config "$config" --source "$tmp/repo" \
        --override-data '{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"packages":{"agent_toolkit":true}}' \
        < "$repo_root/run_onchange_install_packages.sh.tmpl" > "$rendered"
    printf '%s\n' handoff > "$tmp/repo/scripts/curated-agent-skills.txt"
    printf '%s\n' handoff > "$tmp/home/.claude/skills/handoff/SKILL.md"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$tmp/bin/npx"
    cat > "$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
dest="${!#}"
mkdir -p "$dest/skills/engineering/code-review"
printf '%s\n' '---' 'name: code-review' '---' > "$dest/skills/engineering/code-review/SKILL.md"
EOF
    chmod +x "$tmp/bin/npx" "$tmp/bin/git"
    harness="$tmp/lifecycle.sh"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
            'info() { printf "%s\\n" "$1"; }' 'warn() { :; }'
        awk '/^net_timeout\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$rendered"
        awk '/^install_agent_skills\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$rendered"
        printf '%s\n' 'install_agent_skills'
    } > "$harness"
    output="$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash "$harness")"
    if ! grep -Fqx -- 'Curated skills: Claude Code installed=1 skipped=0 failed=0' <<< "$output"; then
        fail 'Unix lifecycle must count only Claude skills with a supported SKILL.md target'
    fi
    for agent in OpenCode Codex; do
        if ! grep -Fqx -- "Curated skills: $agent installed=0 skipped=0 failed=1" <<< "$output"; then
            fail "Unix lifecycle must not count $agent installed when its shared SKILL.md target is missing"
        fi
    done

    updater_harness="$tmp/updater.sh"
    # The updater derives its catalog from its own directory (BASH_SOURCE),
    # not from the repo: place a copy next to the harness so its target
    # verification runs the same branch as in a real checkout.
    printf '%s\n' handoff > "$tmp/curated-agent-skills.txt"
    # The stub models both chezmoi calls the updater makes: `source-path`
    # (answered with the scratch repo) and, since #83, `execute-template` for
    # the agent list in .chezmoidata/agents.yaml - delegated to the real
    # chezmoi against the scratch source, which carries a copy of .chezmoidata.
    # HOME is a scratch dir here, so the real chezmoi would otherwise find no
    # source at all and the updater would run with an empty agent list.
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -e' \
            'chezmoi() { if [ "${1:-}" = execute-template ]; then shift; command chezmoi execute-template --source "'"$tmp/repo"'" "$@"; else printf "%s\\n" "'"$tmp/repo"'"; fi; }'
        # Capture from the catalog assignment (not the npx guard): the
        # verification below needs the catalog path, the fallback helper and
        # the derived total, all defined before the npx branch in the source.
        awk '/^catalog=/{copy=1} /^# Superpowers for Codex/{exit} copy{print}' "$repo_root/scripts/update_ai_tools.sh"
    } > "$updater_harness"
    output="$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash "$updater_harness")"
    if ! grep -Fqx -- '   Curated skills: Claude Code installed=1 skipped=0 failed=0' <<< "$output"; then
        fail 'Unix updater must count only Claude skills with a supported SKILL.md target'
    fi
    for agent in OpenCode Codex; do
        if ! grep -Fqx -- "   Curated skills: $agent installed=0 skipped=0 failed=1" <<< "$output"; then
            fail "Unix updater must not count $agent installed when its shared SKILL.md target is missing"
        fi
    done
}

verify_unix_skill_lifecycle() {
    local tmp config rendered harness output target
    if ! command -v chezmoi >/dev/null 2>&1; then
        printf '%s\n' 'PASS/SKIP: Unix lifecycle rendering requires chezmoi'
        return
    fi
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/bin" "$tmp/repo/scripts" "$tmp/home/.claude/skills/handoff" \
        "$tmp/home/.gemini/antigravity-cli/skills/handoff"
    config="$tmp/chezmoi.toml"
    : > "$config"
    cp "$repo_root/.chezmoidata.yaml" "$tmp/repo/"
    cp -r "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$tmp/repo/"   # catalog + fragments the installers include
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

verify_unix_claude_attribution() {
    local tmp config rendered harness settings warnings mode
    if ! command -v chezmoi >/dev/null 2>&1; then
        printf '%s\n' 'PASS/SKIP: Unix attribution rendering requires chezmoi'
        return
    fi
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
        rm -rf "${tmp:?}/$fixture"
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
    if ! command -v chezmoi >/dev/null 2>&1; then
        printf '%s\n' 'PASS/SKIP: PowerShell attribution rendering requires chezmoi'
        return
    fi

    local fixture config rendered render_dir
    fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"  # pwsh -File needs .ps1
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
# The writer is a direct BOM-less WriteAllText on every platform. The previous
# temp-file + File.Replace/Move dance threw "The path is not of a legal form" on
# real Windows/.NET Framework (see the comment on the function itself), so it
# must not come back. These assertions used to require that dance and therefore
# failed wherever pwsh actually exists - they were checking a removed design.
if ($match.Value -notmatch '\[System\.IO\.File\]::WriteAllText\(\$settings, \$merged, \(New-Object System\.Text\.UTF8Encoding\(\$false\)\)\)') { throw 'Claude attribution must write settings with a BOM-less WriteAllText' }
if ($match.Value -match '\[System\.IO\.File\]::(Replace|Move)\(') { throw 'Claude attribution must not reintroduce the temp-file Replace/Move dance' }
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

verify_windows_command_generation() {
    if ! command -v pwsh >/dev/null 2>&1; then
        printf '%s\n' 'PASS/SKIP: PowerShell runtime generator assertions require pwsh'
        return
    fi
    if ! command -v chezmoi >/dev/null 2>&1; then
        printf '%s\n' 'PASS/SKIP: PowerShell lifecycle rendering requires chezmoi'
        return
    fi

    local fixture
    fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"  # pwsh -File needs .ps1
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

            # The updater derives its catalog path from $curatedCatalog
            # (scripts/update_ai_tools.ps1 keeps it next to $curatedSkillTotal,
            # both outside the extracted region): the prelude seeds the fixture's
            # catalog so the lifecycle takes its real branch, not the
            # missing-catalog fallback that calls an undefined helper in this
            # isolated scope. The prelude is prefixed to EVERY execution of the
            # captured region - the second, assertion-only run below included.
            $fixturePrelude = "`$skAgents = @('claude-code', 'opencode')`n" +
                "`$curatedCatalog = Join-Path '$catalogDir' 'curated-agent-skills.txt'`n" +
                "`$curatedSkillTotal = 3`n"
            $lifecycleBody = $fixturePrelude + ($match.Value -replace '(?m)^    \$catalog =', @'
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
            & ([scriptblock]::Create($fixturePrelude + $match.Value)) | Out-Null
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

verify_windows_summary_fallbacks() {
    if ! command -v pwsh >/dev/null 2>&1; then
        printf '%s\n' 'PASS/SKIP: PowerShell lifecycle fallback fixtures require pwsh'
        return
    fi
    if ! command -v chezmoi >/dev/null 2>&1; then
        printf '%s\n' 'PASS/SKIP: PowerShell summary rendering requires chezmoi'
        return
    fi

    local fixture render_dir config rendered
    fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"  # pwsh -File needs .ps1
    render_dir="$(mktemp -d)"
    config="$render_dir/chezmoi.toml"
    rendered="$render_dir/installer.ps1"
    cp "$repo_root/.chezmoidata.yaml" "$render_dir/"   # sourceDir stays the scratch dir (catalog-unavailable mode) but data must resolve
    cp -r "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$render_dir/"   # catalog + fragments the installers include
    : > "$config"
    chezmoi execute-template --config "$config" --source "$render_dir" \
        --override-data '{"chezmoi":{"os":"windows"},"packages":{"agent_toolkit":true}}' \
        < "$repo_root/run_onchange_install_packages.ps1.tmpl" > "$rendered"
    cat > "$fixture" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
# The fallback summaries derive their count from the catalog (or report 0 when
# it is unavailable), so the rows are matched by shape, not by a literal count.
$summaryRows = @(
    'Claude Code', 'OpenCode', 'Antigravity', 'Codex' | ForEach-Object {
        "Curated skills: $_ installed=0 skipped=\d+ failed=0"
    }
)

function Invoke-Lifecycle {
    param([string]$Script, [string]$Mode)
    $source = Get-Content -Raw -LiteralPath $Script
    if ($Script -like '*installer.ps1') {
        # The lifecycle runs from its summary function up to the guardrail
        # section marker - NOT to end of file. `.*\z` used to be safe only
        # because everything after the lifecycle rendered empty with the
        # fixture's groups; since #102 the guardrail section renders an
        # else-branch that runs the REAL agent-guardrails installer whenever a
        # guardrail binary exists on the host. CI runners have none, so CI
        # cannot catch this; a developer machine can, and did.
        $match = [regex]::Match($source, '(?ms)^function Write-CuratedSkillsSkippedSummary \{.*?(?=^# guardrail-section: begin|\z)')
    } else {
        $match = [regex]::Match($source, '(?ms)^# 1b\. Curated third-party skills.*?^}\s*else\s*\{.*?^\}')
    }
    if (-not $match.Success) { throw "curated lifecycle not found: $Script" }
    # Belt and braces: a fixture must never execute the real installer. If the
    # marker moves or the regex regresses, fail here instead of on the host.
    if ($match.Value -match 'Invoke-GuardrailInstaller|install\.ps1 -Version') {
        throw "fixture captured the guardrail section from $Script - refusing to execute the real agent-guardrails installer in a test"
    }

    function Get-Command {
        param([string]$Name)
        if ($Name -eq 'npx') {
            if ($Mode -eq 'no-npx') { return $null }
            return [PSCustomObject]@{ Name = 'npx' }
        }
        return $null
    }
    function npx { $global:LASTEXITCODE = 0 }
    function git { $global:LASTEXITCODE = 0 }
    function chezmoi { $env:TEMP }
    function Invoke-WithTimeout {
        param([string]$Description, [int]$Seconds, [scriptblock]$Action)
        & $Action
    }

    $output = & ([scriptblock]::Create($match.Value)) 6>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.InformationRecord]) { $_.MessageData } else { $_ }
    }
    foreach ($row in $summaryRows) {
        if (($output -join "`n") -notmatch $row) {
            throw "missing summary row '$row' for $Script ($Mode)"
        }
    }
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('agent-skills-no-catalog-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $temporary | Out-Null
    $env:TEMP = $temporary
    Invoke-Lifecycle $args[0] 'no-npx'
    Invoke-Lifecycle $args[0] 'catalog-unavailable'
    Invoke-Lifecycle $args[1] 'no-npx'
    Invoke-Lifecycle $args[1] 'catalog-unavailable'
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
POWERSHELL
    pwsh -NoProfile -File "$fixture" "$repo_root/scripts/update_ai_tools.ps1" "$rendered"
    rm -rf "$render_dir"
    rm -f "$fixture"
}

if [[ ! -f "$catalog" ]]; then
    fail 'missing curated skill catalog'
else
    actual_skills=()
    while IFS= read -r skill || [[ -n "$skill" ]]; do
        # Header/comments are legal: the installer and updater readers skip
        #-prefixed lines, so the contract must too.
        [[ "$skill" == \#* ]] && continue
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
    verify_unix_supported_target_counts
    verify_unix_skill_lifecycle
    if command -v chezmoi >/dev/null 2>&1; then
        verify_unix_claude_attribution
    fi

    for file in "${unix_files[@]}"; do
        require_contains "$file" 'curated-agent-skills.txt'
        # The agent list renders from .chezmoidata/agents.yaml (#83): the file
        # must read it, and the catalog must still name the three CLIs.
        require_contains "$file" '.agents.skills.agents'
        require_contains .chezmoidata/agents.yaml 'agents: [claude-code, opencode, codex]'
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

        # Every $skAgents array comes from .chezmoidata/agents.yaml (#83). A
        # literal array here would be a copy that can drift from the catalog -
        # which is where codex's membership is asserted (see the unix branch).
        if grep -F -- "\$skAgents = @(" "$repo_root/$file" | grep -Fvq -- ".agents.skills.agents"; then
            fail "$file must build every skills CLI agent array from .agents.skills.agents, not a literal"
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
    if command -v chezmoi >/dev/null 2>&1; then
        verify_windows_claude_attribution
        verify_windows_summary_fallbacks
    fi
    require_contains 'run_onchange_install_packages.ps1.tmpl' '{{- if or $claude_cli $antigravity_cli $agent_toolkit $opencode_cli $chatgpt_cli }}'
    require_contains 'run_onchange_install_packages.ps1.tmpl' "{{ .chezmoi.sourceDir | replace \"'\" \"''\" }}"
    require_contains 'run_onchange_install_packages.ps1.tmpl' 'claude mcp get serena'
fi

# skill-creator comes from our drop-in fork (CtrlCarlitos/skills, Windows fixes,
# docs/skills-install-strategy.md), never from anthropics/skills, in all four
# consumers regardless of scope: the source is a wiring fact, not an OS one.
for file in run_onchange_install_packages.sh.tmpl scripts/update_ai_tools.sh run_onchange_install_packages.ps1.tmpl scripts/update_ai_tools.ps1; do
    require_contains "$file" 'CtrlCarlitos/skills -s skill-creator'
    if grep -Fq -- 'anthropics/skills -s skill-creator' "$repo_root/$file"; then
        fail "$file must install skill-creator from CtrlCarlitos/skills, not anthropics/skills"
    fi
done

finish
