#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

template="$repo_root/run_onchange_install_packages.sh.tmpl"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"

cat > "$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "-k" ]]
shift 3
"$@"
EOF

cat > "$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dest="${!#}"
mkdir -p "$dest/skills/engineering/code-review"
printf '%s\n' '---' 'name: code-review' '---' > "$dest/skills/engineering/code-review/SKILL.md"
EOF

cat > "$tmp/bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
result=PASS

if [[ "${args[0]-}" != "--yes" || "${args[1]-}" != "--loglevel=error" || "${args[2]-}" != "skills@latest" ]]; then
    result=FAIL
fi

agents_found=false
for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[i]}" == "-a" ]]; then
        if [[ "${args[i + 1]-}" == "claude-code" && "${args[i + 2]-}" == "opencode" && "${args[i + 3]-}" == "codex" && "${args[i + 4]-}" == "-g" ]]; then
            agents_found=true
        fi
        break
    fi
done
[[ "$agents_found" == true ]] || result=FAIL

printf '%s\n' "$result" >> "$SKILLS_ARGUMENT_RESULTS"
[[ "$result" == PASS ]]
EOF

cat > "$tmp/bin/chezmoi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "source-path" ]]
printf '%s\n' "$CHEZMOI_SOURCE_PATH"
EOF

chmod +x "$tmp/bin/timeout" "$tmp/bin/git" "$tmp/bin/npx" "$tmp/bin/chezmoi"

# install_agent_skills now carries {{ }} expressions (the skills agent list
# renders from .chezmoidata/agents.yaml, #83), so the template must be
# rendered before its bash can be extracted. Empty config + override-data,
# never the host's own chezmoi.toml. The fake chezmoi in $tmp/bin is only on
# PATH for the harness run below, so this uses the real one.
command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed (needed to render the installer)"
: > "$tmp/chezmoi.toml"
groups="{$(grep -oE 'promptBoolOnce \. "packages\.[a-z_]+"' "$repo_root/.chezmoi.toml.tmpl" | sed -E 's/.*"packages\.([a-z_]+)"/"\1":true/' | paste -sd, -)}"
rendered="$tmp/installer.sh"
chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
    --override-data "{\"chezmoi\":{\"os\":\"linux\",\"kernel\":{\"osrelease\":\"6.8-generic\"}},\"packages\":$groups}" \
    --file "$template" > "$rendered"

harness="$tmp/harness.sh"
{
    # shellcheck disable=SC2016  # $1 expands when the generated harness runs.
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'info() { :; }' 'warn() { printf "WARN: %s\\n" "$1" >&2; }'
    awk '/^net_timeout\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$rendered"
    awk '/^install_agent_skills\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$rendered"
    printf '%s\n' 'install_agent_skills'
} > "$harness"

export SKILLS_ARGUMENT_RESULTS="$tmp/results"
export CHEZMOI_SOURCE_PATH="$repo_root"
PATH="$tmp/bin:$PATH" bash "$harness"

if [[ ! -f "$SKILLS_ARGUMENT_RESULTS" ]]; then
    fail 'controlled npx was never reached'
    exit 1
fi

results=()
while IFS= read -r result; do
    results+=("$result")
done < "$SKILLS_ARGUMENT_RESULTS"
if [[ "${#results[@]}" -ne 8 ]]; then
    fail "expected 8 controlled npx calls, got ${#results[@]}"
    exit 1
fi
if [[ "${results[*]}" != "PASS PASS PASS PASS PASS PASS PASS PASS" ]]; then
    fail "malformed npx argument vector: ${results[*]}"
    exit 1
fi

finish
