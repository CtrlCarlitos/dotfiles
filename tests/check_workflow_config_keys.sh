#!/usr/bin/env bash
set -euo pipefail

# Guards against the outage class that has broken CI twice already (see PR #16):
# .chezmoi.toml.tmpl gains a new promptBoolOnce toggle, but the chezmoi configs
# CI seeds are not updated. On Linux/macOS the missing key makes promptBoolOnce
# abort with "could not open a new TTY"; on Windows it blocks forever (an
# 88-minute job hang was observed). promptBoolOnce only prompts when the key is
# ABSENT from the config, so every seeded config must contain every key the
# template can ask for.
#
# Where the seeded configs live changed with #83: the workflows no longer carry
# inline heredocs, every job composes its chezmoi.toml from
# tests/fixtures/chezmoi/ (see the README there). So the check has two halves:
# every packages-*.toml fixture carries every prompted key, and every composer
# call in the workflows names a fixture that exists - a job cannot seed a
# config this test has not seen.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/.chezmoi.toml.tmpl"
fx="$repo_root/tests/fixtures/chezmoi"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[[ -f "$template" ]] || fail "missing $template"
[[ -d "$fx" ]] || fail "missing $fx - the CI fixtures directory"

# Every package toggle the config template can prompt for,
# e.g. promptBoolOnce . "packages.core" -> packages.core
mapfile -t keys < <(grep -oE 'promptBoolOnce \. "[^"]+"' "$template" | sed -E 's/promptBoolOnce \. "([^"]+)"/\1/' | sort -u)
[[ ${#keys[@]} -gt 0 ]] || fail "no promptBoolOnce keys found in template (extractor broken?)"

# 1. Every packages fixture seeds every prompted key, exactly once.
shopt -s nullglob
pkg_fixtures=("$fx"/packages-*.toml)
[[ ${#pkg_fixtures[@]} -gt 0 ]] || fail "no packages-*.toml fixtures found in $fx"
for f in "${pkg_fixtures[@]}"; do
    base="$(basename -- "$f")"
    blocks=$(grep -cE '^[[:space:]]*\[data\.packages\]' "$f" || true)
    [[ "$blocks" -eq 1 ]] || fail "$base: expected exactly one [data.packages] table, found $blocks"
    for key in "${keys[@]}"; do
        name="${key#packages.}"
        found=$(grep -cE "^[[:space:]]*${name}[[:space:]]*=" "$f" || true)
        [[ "$found" -eq 1 ]] ||
            fail "$base: '${name} =' appears ${found}x - a key promptBoolOnce would ask for interactively is missing (the install_guardrail outage class)"
    done
done

# promptStringOnce's first-run account prompts are bypassed by seeding
# [[data.accounts]] - every accounts fixture must have at least one.
acc_fixtures=("$fx"/accounts-*.toml)
[[ ${#acc_fixtures[@]} -gt 0 ]] || fail "no accounts-*.toml fixtures found in $fx"
for f in "${acc_fixtures[@]}"; do
    n=$(grep -cE '^[[:space:]]*\[\[data\.accounts\]\]' "$f" || true)
    [[ "$n" -ge 1 ]] || fail "$(basename -- "$f"): seeds no [[data.accounts]] - promptStringOnce would prompt"
done

# 2. Every workflow config comes from those fixtures. An inline block would be
#    a config this test cannot see; a composer call naming a missing fixture
#    would fail at runtime, after the job has already been scheduled.
for wf in .github/workflows/ci.yml .github/workflows/full-install-test.yml; do
    f="$repo_root/$wf"
    [[ -f "$f" ]] || fail "missing $f"
    if grep -qE '^[[:space:]]*\[data\.packages\]|^[[:space:]]*\[\[data\.accounts\]\]' "$f"; then
        fail "$wf: seeds a config inline - compose it from tests/fixtures/chezmoi so this check covers it"
    fi
    mapfile -t calls < <(grep -oE 'compose\.sh +[a-z]+ +[a-z]+' "$f")
    [[ ${#calls[@]} -gt 0 ]] || fail "$wf: no compose.sh calls - how does it seed its config?"
    for call in "${calls[@]}"; do
        read -r _ acc pkg <<<"$call"
        [[ -f "$fx/accounts-$acc.toml" ]] || fail "$wf: composes accounts-$acc, which does not exist"
        [[ -f "$fx/packages-$pkg.toml" ]]  || fail "$wf: composes packages-$pkg, which does not exist"
    done
done

printf 'PASS: every prompted config key is seeded in every CI fixture, and every workflow composes from them\n'
