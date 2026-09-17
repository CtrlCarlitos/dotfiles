#!/usr/bin/env bash
set -euo pipefail

# Guardrail pin single-source contract:
#   - .chezmoidata.yaml guardrail.version is the ONLY place the release tag
#     lives; bumps touch one line there.
#   - Installer templates render the key at apply time; manual updaters read
#     it at runtime via `chezmoi execute-template`.
#   - No literal vX.Y.Z-dev pins scattered in the four consumers, and the
#     auto-version script never rewrites the guardrail pin (never "latest").

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
data_file="$repo_root/.chezmoidata.yaml"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_updater="$repo_root/scripts/update_ai_tools.sh"
ps1_updater="$repo_root/scripts/update_ai_tools.ps1"
version_script="$repo_root/scripts/update-versions.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# 1. Single source of truth carries exactly one valid exact-version pin.
[ -f "$data_file" ] || fail ".chezmoidata.yaml missing - the pin has no home"
pin="$(sed -n 's/^  version: \(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\(-[A-Za-z0-9.]\+\)\?\)$/\1/p' "$data_file")"
[ -n "$pin" ] || fail ".chezmoidata.yaml: no 'guardrail: version: vX.Y.Z[-suffix]' pin found"

# 2. Templates consume the data key (rendered by chezmoi at apply time).
for file in "$sh_installer" "$ps1_installer"; do
    grep -Fq -- '{{ .guardrail.version }}' "$file" ||
        fail "$file: does not render {{ .guardrail.version }}"
done

# 3. Manual updaters read the same key at runtime (chezmoi is already a
#    hard prerequisite of both scripts - they are invoked via source-path).
for file in "$sh_updater" "$ps1_updater"; do
    grep -Fq -- "chezmoi execute-template '{{ .guardrail.version }}'" "$file" ||
        fail "$file: does not read the pin via chezmoi execute-template"
done

# 4. No stray literal pins anywhere in the four consumers. The one allowed
#    literal is GUARDRAIL_UPDATE_FLOOR - a fixed historical fact (the first
#    release shipping `guardrail update`), not a pin that ever gets bumped.
#    awk (not grep -Ev | grep -q) so the scan is deterministic: a -q early
#    exit can SIGPIPE the first grep and nondeterministically drop lines.
for file in "$sh_installer" "$ps1_installer" "$sh_updater" "$ps1_updater"; do
    awk '/GUARDRAIL_UPDATE_FLOOR/ {next} /v[0-9]+\.[0-9]+\.[0-9]+-dev/ {bad = 1} END {exit bad ? 1 : 0}' "$file" ||
        fail "$file: contains a hardcoded vX.Y.Z-dev pin - bump .chezmoidata.yaml instead"
done

# 5. The auto-version script must never touch the guardrail pin.
! grep -Fq -- 'GUARDRAIL_VERSION' "$version_script" ||
    fail "scripts/update-versions.sh still references GUARDRAIL_VERSION - guardrail is pinned by hand in .chezmoidata.yaml"

# 6. Behavioral sanity when chezmoi is available: the template really renders
#    the data pin into the script (skipped where chezmoi is absent).
if command -v chezmoi >/dev/null 2>&1; then
    rendered="$(chezmoi execute-template < "$sh_installer")"
    grep -Fq -- "GUARDRAIL_VERSION=\"$pin\"" <<<"$rendered" ||
        fail "rendered installer does not carry GUARDRAIL_VERSION=\"$pin\""
fi

printf 'PASS: guardrail pin lives only in .chezmoidata.yaml (%s)\n' "$pin"
