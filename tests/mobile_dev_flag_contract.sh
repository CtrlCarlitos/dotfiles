#!/usr/bin/env bash
set -euo pipefail

# mobile_dev is the 17th package group: listed in the canonical PKG_GROUPS taxonomy and
# prompted from .chezmoi.toml.tmpl, default false, never prompted in a devcontainer.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

require "$repo_root/scripts/lib/chezmoi-config.sh" 'mobile_dev'
require "$repo_root/.chezmoi.toml.tmpl" 'packages.mobile_dev'
require "$repo_root/.chezmoi.toml.tmpl" 'mobile_dev (opt-in Expo/Android mobile development tooling)'

if command -v chezmoi >/dev/null 2>&1; then
    # Devcontainer: must render false without prompting (promptBoolOnce would hang without a
    # TTY). CI=1 also keeps $interactive false, so the render never prompts on any runner.
    empty_config="$(mktemp -d)/empty.toml"
    : >"$empty_config"
    out="$(DEVCONTAINER=true CI=1 chezmoi execute-template --init --config "$empty_config" \
        --source "$repo_root" <"$repo_root/.chezmoi.toml.tmpl" 2>&1)" ||
        fail "devcontainer render of .chezmoi.toml.tmpl failed: $out"
    printf '%s\n' "$out" | grep -Eq '^[[:space:]]*mobile_dev = false[[:space:]]*$' ||
        fail "devcontainer render must set packages.mobile_dev = false"
else
    skip "chezmoi not installed"
fi

finish
