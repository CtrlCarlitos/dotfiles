#!/usr/bin/env bash
set -euo pipefail

# Guards against the outage class that has broken CI twice already (see PR #16):
# .chezmoi.toml.tmpl gains a new promptBoolOnce toggle, but the static chezmoi
# configs pre-seeded in the workflows are not updated. On Linux/macOS the
# missing key makes promptBoolOnce abort with "could not open a new TTY"; on
# Windows it blocks forever (an 88-minute job hang was observed).
# promptBoolOnce
# only prompts when the key is ABSENT from the config, so every seeded config
# must contain every key the template can ask for.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/.chezmoi.toml.tmpl"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[[ -f "$template" ]] || fail "missing $template"

# Every package toggle the config template can prompt for,
# e.g. promptBoolOnce . "packages.install_core" -> packages.install_core
mapfile -t keys < <(grep -oE 'promptBoolOnce \. "[^"]+"' "$template" | sed -E 's/promptBoolOnce \. "([^"]+)"/\1/' | sort -u)
[[ ${#keys[@]} -gt 0 ]] || fail "no promptBoolOnce keys found in template (extractor broken?)"

for wf in .github/workflows/ci.yml .github/workflows/full-install-test.yml; do
    f="$repo_root/$wf"
    [[ -f "$f" ]] || fail "missing $f"

    # Each pre-seeded config contains exactly one [data.packages] table.
    blocks=$(grep -cE '^[[:space:]]*\[data\.packages\]' "$f" || true)
    [[ "$blocks" -gt 0 ]] || fail "$wf: no seeded [data.packages] configs found"

    # promptStringOnce's first-run account prompts are bypassed by seeding
    # [[data.accounts]] - every config must have at least one (integration
    # tests legitimately seed several).
    accounts=$(grep -cE '^[[:space:]]*\[\[data\.accounts\]\]' "$f" || true)
    [[ "$accounts" -ge "$blocks" ]] ||
        fail "$wf: $blocks configs but only $accounts seed [[data.accounts]]"

    for key in "${keys[@]}"; do
        name="${key#packages.}"
        found=$(grep -cE "^[[:space:]]*${name}[[:space:]]*=" "$f" || true)
        [[ "$found" -eq "$blocks" ]] ||
            fail "$wf: '${name} =' appears ${found}x but there are ${blocks} seeded configs - a config is missing a key promptBoolOnce would ask for interactively (the install_guardrail outage class)"
    done
done

printf 'PASS: every prompted config key is seeded in every workflow config\n'
