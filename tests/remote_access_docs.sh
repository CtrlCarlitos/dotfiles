#!/usr/bin/env bash
set -euo pipefail

guide="docs/remote-access.md"
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

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for anchor in "${anchors[@]}"; do
  grep -Fq "$anchor" "$guide" || fail "missing required anchor: $anchor"
done

# These tools may only appear in the explicit non-goals statement.
if grep -Ein 'Caddy|code-server|Tailscale Funnel' "$guide" | grep -Eiv 'no Caddy, code-server, Tailscale Funnel|never provide Caddy, code-server, Funnel'; then
  fail "guide recommends a prohibited public-access tool"
fi

if grep -Eqi 'Cloudflare.*OpenCode|OpenCode.*Cloudflare' "$guide"; then
  fail "guide routes OpenCode through Cloudflare"
fi

printf 'PASS: remote-access documentation contract\n'
