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

# docs/mobile-development.md skeleton: the anchor both sibling plans write into.
require "$repo_root/README.md" 'mobile-development.md'
require "$repo_root/docs/README.md" 'mobile-development.md'
[[ -f "$repo_root/docs/mobile-development.md" ]] || fail "docs/mobile-development.md missing"
for heading in '## Windows setup' '## WSL setup' '## Linux and macOS' '## VS Code' '## Troubleshooting'; do
    require "$repo_root/docs/mobile-development.md" "$heading"
done
require "$repo_root/docs/mobile-development.md" 'superpowers/specs/2026-10-10-mobile-dev-design.md'
require "$repo_root/docs/mobile-development.md" '#336'

# The 17-group count: every stale "16" spelling is gone and the 17 spelling is in place.
require "$repo_root/README.md" 'preset → 17 groups'
require "$repo_root/README.md" '17 package groups across 5 platforms'
require "$repo_root/README.md" 'The 17-group taxonomy'
require "$repo_root/README.md" 'Platform installers (17-group gated)'
require "$repo_root/docs/README.md" 'the 17 groups, presets'
require "$repo_root/docs/quickstart.md" 'the 17 groups, what each installs'
require "$repo_root/docs/menu-demo.md" 'The real menu lists the 17 group'
forbid "$repo_root/README.md" 'preset → 16 groups'
forbid "$repo_root/README.md" '16 package groups'
forbid "$repo_root/README.md" 'The 16-group taxonomy'
forbid "$repo_root/README.md" 'Platform installers (16-group gated)'
forbid "$repo_root/docs/README.md" 'the 16 groups'
forbid "$repo_root/docs/quickstart.md" 'the 16 groups'
forbid "$repo_root/docs/menu-demo.md" 'The real menu lists the 16 group'

finish
