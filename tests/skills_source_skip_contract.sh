#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2317  # AGENTS / record_cli_result are consumed by the sourced library
set -euo pipefail

# `skills add` re-fetches every curated skill on every `dot upgrade`, and a cold `npx
# skills@latest` costs 30+ s even when nothing upstream moved. skills_add_all now skips a
# source whose upstream HEAD is the commit it last installed from (recorded per source +
# skill list + agent list under the XDG state dir), provided every skill is still present.
# Why not `skills update`? Measured: it has no --copy/-a flags and re-links the Claude copy
# as a symlink into ~/.agents (the installers deliberately install copies), so it cannot
# replace `add --copy`. This is the version check instead; unknown never skips.
#
# scripts/lib/agent-skills.sh is sourced and skills_add_all EXECUTED against a fake npx and
# a fake git (ls-remote answers $FAKE_HEAD, empty = unreachable):
#   a. fresh state        -> every group installs (8 adds)
#   b. same head          -> nothing installs, but the CLI-phase tally is unchanged (19)
#   c. head moved         -> every group installs again (mp-code-review re-staged)
#   d. one skill missing  -> only its group installs
#   e. head unreachable   -> installs every run, nothing recorded
#   f. DOT_SKILLS_FORCE=1 -> installs
#   g. a failed add       -> not recorded, so the next run installs
#   h. agent list changed -> installs (the key includes it)
#   i. mp-code-review missing, head same -> only it installs
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-k" ]]
shift 3
"$@"
EOF
cat >"$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    ls-remote)
        [ -n "${FAKE_HEAD:-}" ] || exit 2
        printf '%s\tHEAD\n' "$FAKE_HEAD"
        ;;
    clone)
        dest="${!#}"
        mkdir -p "$dest/skills/engineering/code-review"
        printf '%s\n' '---' 'name: code-review' '---' >"$dest/skills/engineering/code-review/SKILL.md"
        ;;
    *) exit 1 ;;
esac
EOF
cat >"$tmp/bin/npx" <<'EOF'
#!/usr/bin/env bash
# args: --yes --loglevel=error skills@latest add <src> -s <names...> -a <agents...> -g -y --copy
[ "${FAKE_NPX_FAIL:-}" != 1 ] || { echo "ADD-FAILED" >>"$NPX_LOG"; exit 1; }
args=("$@")
names=()
take=0
for a in "${args[@]:4}"; do
    case "$a" in
        -s) take=1 ;;
        -*) take=0 ;;
        *) [ "$take" = 1 ] && names+=("$a") ;;
    esac
done
printf 'ADD %s\n' "${names[*]}" >>"$NPX_LOG"
for n in "${names[@]}"; do
    mkdir -p "$HOME/.claude/skills/$n" "$HOME/.agents/skills/$n"
    : >"$HOME/.claude/skills/$n/SKILL.md"
    : >"$HOME/.agents/skills/$n/SKILL.md"
done
EOF
chmod +x "$tmp/bin/"*

# run_all <label>: one skills_add_all pass in a subshell; prints "adds=<n> installed=<n>".
home="$tmp/home"
run_all() {
    : >"$tmp/npx.log"
    (
        export HOME="$home" PATH="$tmp/bin:$PATH" NPX_LOG="$tmp/npx.log"
        unset XDG_STATE_HOME
        # shellcheck disable=SC1091
        . "$repo_root/scripts/lib/agent-skills.sh"
        installed_total=0
        record_cli_result() { [ "$1" != installed ] || installed_total=$((installed_total + $2)); }
        if [ -z "${AGENTS_OVERRIDE:-}" ]; then AGENTS=(claude-code opencode codex); else read -ra AGENTS <<<"$AGENTS_OVERRIDE"; fi
        skills_add_all >"$tmp/last-run.txt" 2>&1
        printf 'adds=%s installed=%s\n' "$(grep -c '^ADD ' "$tmp/npx.log" || true)" "$installed_total"
    )
}

export FAKE_HEAD=aaaaaaa
[ "$(run_all)" = 'adds=8 installed=18' ] || fail "a: fresh state must install all 8 groups (got $(run_all))"
# one line per source: an installing run says "Installing ..." (7 groups; mp-code-review's
# clone-and-add is silent) and never "up to date"; a skipped one says "<name>: up to date" only.
[ "$(grep -c 'Installing ' "$tmp/last-run.txt" || true)" = 7 ] || fail "a: a fresh run must print one 'Installing ...' per group (got: $(grep -c 'Installing ' "$tmp/last-run.txt" || true))"
if grep -q 'up to date' "$tmp/last-run.txt"; then fail "a: a fresh run must not say 'up to date'"; else pass; fi

[ "$(run_all)" = 'adds=0 installed=18' ] || fail "b: unchanged head must install nothing and still report 18 (got $(run_all))"
[ "$(grep -c ': up to date' "$tmp/last-run.txt" || true)" = 8 ] || fail "b: every source must say '<name>: up to date' exactly once (got: $(grep -c ': up to date' "$tmp/last-run.txt" || true))"
if grep -q 'Installing ' "$tmp/last-run.txt"; then fail "b: a skipped source must not print 'Installing ...' first (the duplicate-message bug)"; else pass; fi

FAKE_HEAD=bbbbbbb
[ "$(run_all)" = 'adds=8 installed=18' ] || fail "c: a moved head must reinstall every group (got $(run_all))"

rm -rf "$home/.claude/skills/code-search"
[ "$(run_all)" = 'adds=1 installed=18' ] || fail "d: one missing skill must reinstall only its group (got $(run_all))"
[ "$(run_all)" = 'adds=0 installed=18' ] || fail "d: and be quiet again afterwards"

rm -rf "$home/.claude/skills/mp-code-review"
[ "$(run_all)" = 'adds=1 installed=18' ] || fail "i: a missing mp-code-review must reinstall only it (got $(run_all))"

DOT_SKILLS_FORCE=1 run_all | grep -q '^adds=8 ' || fail "f: DOT_SKILLS_FORCE=1 must install everything"

AGENTS_OVERRIDE='claude-code opencode'
run_all | grep -q '^adds=8 ' || fail "h: a changed agent list must reinstall everything"
unset AGENTS_OVERRIDE

# e. unreachable head: installs every run and records nothing
home="$tmp/home-offline"
FAKE_HEAD=''
run_all | grep -q '^adds=8 ' || fail "e: unreachable head must install (first run)"
run_all | grep -q '^adds=8 ' || fail "e: unreachable head must keep installing (nothing recorded)"

# g. failed adds are not recorded
home="$tmp/home-failing"
FAKE_HEAD=ccccccc
FAKE_NPX_FAIL=1 run_all >/dev/null
[ "$(run_all)" = 'adds=8 installed=18' ] || fail "g: failed adds must not be recorded (got $(run_all))"

# --- the PowerShell twin (scripts/lib/ps-skills.ps1), same scenarios, run under pwsh ------
if command -v pwsh >/dev/null 2>&1; then
    winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$UserDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $UserDir
Remove-Item Env:XDG_STATE_HOME -ErrorAction SilentlyContinue
Remove-Item Env:DOT_SKILLS_FORCE -ErrorAction SilentlyContinue
. $Lib
$script:head = 'aaa'
$script:ok = $true
$script:installs = 0
function Get-SkillsRemoteHead { param([string]$Repo) return $script:head }
function Add-FakeSkill([string]$n) {
    foreach ($d in '.claude', '.agents') {
        $p = Join-Path $UserDir "$d\skills\$n"
        New-Item -Force -ItemType Directory $p | Out-Null
        Set-Content -LiteralPath (Join-Path $p 'SKILL.md') -Value ''
    }
}
$agents = @('claude-code', 'opencode', 'codex')
function Step([string]$label, [string[]]$Agents = $agents) {
    $script:installs = 0
    Invoke-SkillsSource -Label 'x' -Repo 'o/r' -Skills 'a', 'b' -Agents $Agents -Install { $script:installs++; Add-FakeSkill 'a'; Add-FakeSkill 'b'; $script:ok } | Out-Null
    Write-Output "$label=$script:installs"
}
Step 'fresh'
Step 'same'
$script:head = 'bbb'; Step 'moved'
Remove-Item -Recurse -Force (Join-Path $UserDir '.claude\skills\a'); Step 'missing'
$env:DOT_SKILLS_FORCE = '1'; Step 'force'; Remove-Item Env:DOT_SKILLS_FORCE
$script:head = ''; Step 'offline1'; Step 'offline2'
$script:head = 'bbb'; Step 'back'
$script:head = 'ccc'; $script:ok = $false; Step 'failed'; $script:ok = $true; Step 'afterfail'
Step 'agents' @('claude-code', 'opencode')
Write-Output ("state=" + (Test-Path -LiteralPath (Get-SkillsSourceStatePath)))
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" -UserDir "$(winpath "$tmp/ps-home")" 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' '))"; }
    expect 'fresh=1'
    expect 'same=0'
    expect 'moved=1'
    expect 'missing=1'
    expect 'force=1'
    expect 'offline1=1'
    expect 'offline2=1'
    expect 'back=0'
    expect 'failed=1'
    expect 'afterfail=1'
    expect 'agents=1'
    expect 'state=True'
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

finish
