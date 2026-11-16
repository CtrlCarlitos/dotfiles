#!/bin/sh
# The agent GitHub identity (ADR-0038) lands GH_TOKEN in ~/.claude/settings.json
# and ~/.codex/config.toml through modify templates. A freshly created target
# gets chezmoi's default 0644 (the private_ attribute does not combine with
# modify_ scripts), so this pins both to 0600 on every apply - before Claude or
# Codex ever rewrite the files themselves. Idempotent; a no-op when either file
# is absent. No Windows twin: %USERPROFILE% ACLs default to user-only.
set -eu
for f in "$HOME/.claude/settings.json" "$HOME/.codex/config.toml"; do
    if [ -f "$f" ]; then
        chmod 600 "$f"
    fi
done
