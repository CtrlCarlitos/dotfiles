#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
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
        if [[ "${args[i + 1]-}" == "claude-code" && "${args[i + 2]-}" == "opencode" && "${args[i + 3]-}" == "antigravity" && "${args[i + 4]-}" == "-g" ]]; then
            agents_found=true
        fi
        break
    fi
done
[[ "$agents_found" == true ]] || result=FAIL

printf '%s\n' "$result" >> "$SKILLS_ARGUMENT_RESULTS"
[[ "$result" == PASS ]]
EOF

chmod +x "$tmp/bin/timeout" "$tmp/bin/git" "$tmp/bin/npx"

harness="$tmp/harness.sh"
{
    # shellcheck disable=SC2016  # $1 expands when the generated harness runs.
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'info() { :; }' 'warn() { printf "WARN: %s\\n" "$1" >&2; }'
    awk '/^net_timeout\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$template"
    awk '/^install_agent_skills\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$template"
    printf '%s\n' 'install_agent_skills'
} > "$harness"

export SKILLS_ARGUMENT_RESULTS="$tmp/results"
PATH="$tmp/bin:$PATH" bash "$harness"

if [[ ! -f "$SKILLS_ARGUMENT_RESULTS" ]]; then
    printf '%s\n' 'FAIL: controlled npx was never reached' >&2
    exit 1
fi

results=()
while IFS= read -r result; do
    results+=("$result")
done < "$SKILLS_ARGUMENT_RESULTS"
if [[ "${#results[@]}" -ne 6 ]]; then
    printf 'FAIL: expected 6 controlled npx calls, got %s\n' "${#results[@]}" >&2
    exit 1
fi
if [[ "${results[*]}" != "PASS PASS PASS PASS PASS PASS" ]]; then
    printf 'FAIL: malformed npx argument vector: %s\n' "${results[*]}" >&2
    exit 1
fi

printf '%s\n' 'PASS: all skills CLI calls preserve command and agent argument boundaries'
