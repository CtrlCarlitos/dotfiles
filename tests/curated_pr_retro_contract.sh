#!/usr/bin/env bash
# shellcheck disable=SC2034  # tallies are read by the sourced library through dynamic scope
set -euo pipefail

# Matt Pocock's `pr` and `retro` joined the curated catalog (#269). What must hold:
#   1. The as-is Matt list is written in four places (the shell library, both Windows
#      installers' Invoke-SkillsSource and their npx arguments); they must name the same
#      skills, all of them in the catalog, with pr and retro among them. A list that drifts
#      installs a skill the verification pass then calls missing, or the reverse.
#   2. Whole skill directories survive the install and the Antigravity fan-out - not just
#      SKILL.md: pr ships CREDITS.md and agents/openai.yaml, retro ships agents/openai.yaml
#      carrying `allow_implicit_invocation: false` (Codex), and SKILL.md carries
#      `disable-model-invocation: true` (Claude Code). retro is run on request, never
#      implicitly, so that metadata is the whole contract.
#   3. The OpenCode command shims are generated for both, and a command the user wrote
#      themselves (a /pr of their own) is left alone.
# The Unix verification pass is EXECUTED against the upstream file layout; the Windows
# twins are held to the same lists by (1) and to the same copy semantics by their
# Copy-Item -Recurse (asserted below).
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

catalog="$repo_root/scripts/curated-agent-skills.txt"
in_catalog() { grep -qx -- "$1" "$catalog"; }

# --- 1. one list, four sites ---------------------------------------------------------------
# The extractors below stop reading early (grep -m1, awk ... exit), which closes the pipe on
# their producer: under pipefail that SIGPIPE (141) would abort the script on Linux.
set +o pipefail
in_catalog pr || fail "pr must be in scripts/curated-agent-skills.txt"
in_catalog retro || fail "retro must be in scripts/curated-agent-skills.txt"
[ "$(grep -cx -e pr -e retro "$catalog")" = 2 ] || fail "pr and retro must each appear once in the catalog"

sh_list="$(tr -d '\r' <"$repo_root/scripts/lib/agent-skills.sh" \
    | awk '/local -a mp_skills=\(/{f=1} f{print} f && /\)/{exit}' | sed 's/.*=(//; s/)//' | tr -s ' \n' '\n' | sed '/^$/d' | sort)"
ps_inline() { # $1 = file: the -Skills @('a', 'b') list of the 'Matt Pocock skills' Invoke-SkillsSource
    tr -d '\r' <"$1" | grep -m1 "Invoke-SkillsSource -Label ['\"]Matt Pocock skills['\"]" \
        | sed "s/.*-Skills @(//; s/).*//" | tr -d "' " | tr ',' '\n' | sort
}
ps_npx() { # $1 = file: the names after `add mattpocock/skills -s ` up to ` -a`
    tr -d '\r' <"$1" | grep -m1 'skills@latest add mattpocock/skills -s ' \
        | sed 's/.*add mattpocock\/skills -s //; s/ -a .*//' | tr ' ' '\n' | sort
}
[ -n "$sh_list" ] || fail "could not read mp_skills from scripts/lib/agent-skills.sh"
for f in run_onchange_install_packages.ps1.tmpl scripts/update_ai_tools.ps1; do
    [ "$(ps_inline "$repo_root/$f")" = "$sh_list" ] || fail "$f: the Invoke-SkillsSource skill list differs from the shell library's mp_skills"
    [ "$(ps_npx "$repo_root/$f")" = "$sh_list" ] || fail "$f: the npx -s skill list differs from the shell library's mp_skills"
done
printf '%s\n' "$sh_list" | grep -qx pr || fail "mp_skills must include pr"
printf '%s\n' "$sh_list" | grep -qx retro || fail "mp_skills must include retro"
[ "$(printf '%s\n' "$sh_list" | wc -l | tr -d ' ')" = 12 ] || fail "expected 12 as-is Matt skills (10 + pr + retro), got $(printf '%s\n' "$sh_list" | wc -l | tr -d ' ')"
while IFS= read -r s; do in_catalog "$s" || fail "Matt skill '$s' is installed but not in the catalog (the verification pass would never check it)"; done <<<"$sh_list"
pass

set -o pipefail

# --- 2. + 3. the Unix verification pass over the upstream layout ------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
mkdir -p "$home/.config/opencode/commands"
for root in .claude/skills .agents/skills; do
    mkdir -p "$home/$root/pr/agents" "$home/$root/retro/agents"
    printf '%s\n' '---' 'name: pr' 'description: "Use when writing a PR body."' '---' 'body' >"$home/$root/pr/SKILL.md"
    printf '%s\n' '# Credits' >"$home/$root/pr/CREDITS.md"
    printf '%s\n' 'interface:' '  display_name: "PR"' >"$home/$root/pr/agents/openai.yaml"
    printf '%s\n' '---' 'name: retro' 'description: "Conduct a retrospective on a coding session."' 'disable-model-invocation: true' '---' 'body' >"$home/$root/retro/SKILL.md"
    printf '%s\n' 'interface:' '  display_name: "Retro"' 'policy:' '  allow_implicit_invocation: false' >"$home/$root/retro/agents/openai.yaml"
done
printf '%s\n' 'my own /pr command' >"$home/.config/opencode/commands/pr.md"
printf '%s\n' pr retro >"$tmp/catalog.txt"

out="$(
    HOME="$home" bash -c '
        set -euo pipefail
        . "$1/scripts/lib/agent-skills.sh"
        info() { printf "%s\n" "$1"; }
        warn() { printf "WARN %s\n" "$1"; }
        catalog="$2"
        claude_installed=0 opencode_installed=0 codex_installed=0
        antigravity_installed=0 antigravity_skipped=0 antigravity_failed=0
        verify_curated_skill_targets 2 2 2
        printf "tally claude=%s opencode=%s codex=%s antigravity=%s/%s/%s\n" "$claude_installed" "$opencode_installed" "$codex_installed" "$antigravity_installed" "$antigravity_skipped" "$antigravity_failed"
    ' _ "$repo_root" "$tmp/catalog.txt" 2>&1
)"
printf '%s\n' "$out" | grep -Fxq 'tally claude=2 opencode=2 codex=2 antigravity=2/0/0' \
    || fail "the verification pass must count pr and retro installed for every agent (got: $(printf '%s' "$out" | tr '\n' '|'))"

ag="$home/.gemini/antigravity-cli/skills"
for f in pr/SKILL.md pr/CREDITS.md pr/agents/openai.yaml retro/SKILL.md retro/agents/openai.yaml; do
    [ -f "$ag/$f" ] || fail "the Antigravity fan-out must copy the whole skill directory: $f is missing"
done
grep -Fq 'disable-model-invocation: true' "$ag/retro/SKILL.md" || fail "retro must keep disable-model-invocation: true in the Antigravity copy"
grep -Fq 'allow_implicit_invocation: false' "$ag/retro/agents/openai.yaml" || fail "retro must keep allow_implicit_invocation: false (Codex) in the Antigravity copy"

cmd="$home/.config/opencode/commands"
[ "$(cat "$cmd/pr.md")" = 'my own /pr command' ] || fail "a user-written OpenCode /pr command must be left unchanged"
printf '%s\n' "$out" | grep -Fq 'user-managed' || fail "leaving a user-written command alone must say so"
grep -Fq 'managed-by: chezmoi-curated-skills' "$cmd/retro.md" || fail "an OpenCode command shim must be generated for retro"
grep -Fq 'Load the native `retro` skill' "$cmd/retro.md" || fail "the retro shim must load the native retro skill"
pass

# --- Windows twins copy directories recursively (nested agents/ metadata) -----------------------
for f in run_onchange_install_packages.ps1.tmpl scripts/update_ai_tools.ps1; do
    grep -q 'Copy-Item -Destination \$temporary -Recurse' "$repo_root/$f" \
        || fail "$f: the Antigravity fan-out must Copy-Item -Recurse (agents/openai.yaml lives one level down)"
done
pass

finish
