#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2317  # the sourced library consumes these
set -euo pipefail

# A skill dropped upstream (resolving-merge-conflicts left mattpocock/skills on
# 2026-09-24) used to linger forever: the installers only add, and the verify pass only
# looks at the live catalog. scripts/retired-agent-skills.txt lists `<skill> <source>`
# pairs, and the installers now remove a retired skill from every agent directory AND
# from the skills CLI's lock, but only when that lock says the skill came from the listed
# source - a skill of the same name you wrote yourself is never touched.
#
# Both twins are EXECUTED against a fixture HOME: skills_remove_retired in
# scripts/lib/agent-skills.sh and Invoke-RetiredSkillsCleanup in scripts/lib/ps-skills.ps1.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v jq >/dev/null 2>&1 || skip 'jq not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

list_file="$repo_root/scripts/retired-agent-skills.txt"
[ -f "$list_file" ] || fail "scripts/retired-agent-skills.txt is missing"
grep -Eq '^resolving-merge-conflicts[[:space:]]+mattpocock/skills$' "$list_file" ||
    fail "the retired list must name resolving-merge-conflicts from mattpocock/skills"

# fixture(home): a retired skill (ours), the same name from another source (not ours), a
# live skill, and OpenCode command shims (one managed, one the user wrote).
make_home() {
    local h="$1"
    mkdir -p "$h/.claude/skills/old" "$h/.agents/skills/old" "$h/.gemini/antigravity-cli/skills/old" \
        "$h/.claude/skills/keep" "$h/.agents/skills/keep" "$h/.config/opencode/commands"
    for d in "$h/.claude/skills/old" "$h/.agents/skills/old" "$h/.gemini/antigravity-cli/skills/old" "$h/.claude/skills/keep" "$h/.agents/skills/keep"; do
        printf 'x\n' >"$d/SKILL.md"
    done
    printf '<!-- managed-by: chezmoi-curated-skills -->\nbody\n' >"$h/.config/opencode/commands/old.md"
    printf '%s\n' '{"version":3,"skills":{"old":{"source":"mattpocock/skills"},"keep":{"source":"mattpocock/skills"}},"dismissed":{}}' >"$h/.agents/.skill-lock.json"
}

printf '%s\n' '# comment' '' 'old mattpocock/skills' '../escape mattpocock/skills' 'keep someone/else' >"$tmp/retired.txt"

# --- bash twin -----------------------------------------------------------------------------
home="$tmp/home-sh"
make_home "$home"
(
    export HOME="$home"
    # shellcheck disable=SC1091
    . "$repo_root/scripts/lib/agent-skills.sh"
    skills_remove_retired "$tmp/retired.txt" >/dev/null
    skills_remove_retired "$tmp/retired.txt" >/dev/null   # idempotent
)
for d in .claude/skills/old .agents/skills/old .gemini/antigravity-cli/skills/old .config/opencode/commands/old.md; do
    [ ! -e "$home/$d" ] || fail "bash: retired skill left behind: $d"
done
for d in .claude/skills/keep .agents/skills/keep; do
    [ -f "$home/$d/SKILL.md" ] || fail "bash: a skill whose lock source differs ('keep' is from someone/else in the list) must survive: $d"
done
[ "$(jq -r '.skills | keys | join(",")' "$home/.agents/.skill-lock.json")" = keep ] || fail "bash: the retired lock entry must go and the others stay"
[ "$(jq -r '.version' "$home/.agents/.skill-lock.json")" = 3 ] || fail "bash: the rest of the lock must be preserved"

# a user-written skill of the same name (no lock entry, or another source) is left alone
home2="$tmp/home-sh-own"
make_home "$home2"
printf '%s\n' '{"version":3,"skills":{"old":{"source":"me/mine"}},"dismissed":{}}' >"$home2/.agents/.skill-lock.json"
printf 'user shim\n' >"$home2/.config/opencode/commands/old.md"
(
    export HOME="$home2"
    # shellcheck disable=SC1091
    . "$repo_root/scripts/lib/agent-skills.sh"
    skills_remove_retired "$tmp/retired.txt" >/dev/null
)
[ -f "$home2/.claude/skills/old/SKILL.md" ] || fail "bash: a skill from a different source must not be removed"
[ -f "$home2/.config/opencode/commands/old.md" ] || fail "bash: a user-written command shim must not be removed"

# an unmanaged shim survives even when the skill is removed
home3="$tmp/home-sh-shim"
make_home "$home3"
printf 'user shim\n' >"$home3/.config/opencode/commands/old.md"
(
    export HOME="$home3"
    # shellcheck disable=SC1091
    . "$repo_root/scripts/lib/agent-skills.sh"
    skills_remove_retired "$tmp/retired.txt" >/dev/null
)
[ ! -e "$home3/.claude/skills/old" ] || fail "bash: the skill itself must still be removed"
[ -f "$home3/.config/opencode/commands/old.md" ] || fail "bash: a shim without the managed-by marker must survive"

# --- PowerShell twin -----------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$UserDir, [string]$List)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $UserDir
. $Lib
Invoke-RetiredSkillsCleanup -ListPath $List | Out-Null
Invoke-RetiredSkillsCleanup -ListPath $List | Out-Null   # idempotent
foreach ($p in '.claude\skills\old', '.agents\skills\old', '.gemini\antigravity-cli\skills\old', '.config\opencode\commands\old.md', '.claude\skills\keep\SKILL.md') {
    Write-Output ("exists[$p]=" + (Test-Path -LiteralPath (Join-Path $UserDir $p)))
}
$lock = Get-Content -Raw -LiteralPath (Join-Path $UserDir '.agents\.skill-lock.json') | ConvertFrom-Json
Write-Output ("lock=" + (($lock.skills.PSObject.Properties.Name) -join ','))
Write-Output ("version=" + $lock.version)
PSEOF
    homeps="$tmp/home-ps"
    make_home "$homeps"
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" -UserDir "$(winpath "$homeps")" -List "$(winpath "$tmp/retired.txt")" 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' '))"; }
    expect 'exists[.claude\skills\old]=False'
    expect 'exists[.agents\skills\old]=False'
    expect 'exists[.gemini\antigravity-cli\skills\old]=False'
    expect 'exists[.config\opencode\commands\old.md]=False'
    expect 'exists[.claude\skills\keep\SKILL.md]=True'
    expect 'lock=keep'
    expect 'version=3'
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

finish
