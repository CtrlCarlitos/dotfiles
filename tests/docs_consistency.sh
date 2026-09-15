#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require() {
    grep -Fq -- "$2" "$repo_root/$1" || fail "$1: missing '$2'"
}

require README.md "16-group taxonomy"
require README.md "Platform installers (16-group gated)"
require README.md "Config template (16 promptBoolOnce groups)"
require README.md "cloudflared only"
require README.md "Linux/macOS/WSL"
require README.md "select-packages.ps1"
require README.md "Join-Path (chezmoi source-path)"
require docs/menu-demo.md "opencode_cli"
require docs/menu-demo.md "opencode_desktop"

printf 'PASS: documentation package-group consistency\n'
