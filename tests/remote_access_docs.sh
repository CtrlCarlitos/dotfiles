#!/usr/bin/env bash
set -euo pipefail

guide="docs/remote-access.md"
non_goals="No Caddy, code-server, Tailscale Funnel, or public agent backends."
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

anchors=(
  "Tailscale Serve"
  "OPENCODE_SERVER_PASSWORD"
  "Claude Remote Control"
  "Codex Remote"
  "Antigravity Remote Control"
  "Windows :22"
  "WSL :2222"
  "http_status:404"
)

validate_guide() {
  local candidate=$1
  local anchor

  for anchor in "${anchors[@]}"; do
    grep -Fq "$anchor" "$candidate" || return 1
  done

  [[ $(grep -Fxc "$non_goals" "$candidate" || true) == 1 ]] || return 1

  # Banned tools are valid only in the exact, standalone non-goals statement.
  if grep -E 'Caddy|code-server|Funnel' "$candidate" | grep -Fvx "$non_goals" >/dev/null; then
    return 1
  fi

  ! grep -Eqi 'Cloudflare.*OpenCode|OpenCode.*Cloudflare' "$candidate"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

write_fixture() {
  local path=$1
  local statement=$2
  printf '%s\n' "${anchors[@]}" "$statement" >"$path"
}

write_fixture "$tmp/allowed.md" "$non_goals"
validate_guide "$tmp/allowed.md" || fail "valid non-goals fixture rejected"

for tool in Caddy code-server Funnel; do
  write_fixture "$tmp/recommends-$tool.md" "$non_goals; use $tool later"
  if validate_guide "$tmp/recommends-$tool.md"; then
    fail "$tool recommendation hidden on non-goals line accepted"
  fi
done

validate_guide "$guide" || fail "guide violates remote-access documentation contract"

finish
