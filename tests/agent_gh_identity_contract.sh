#!/usr/bin/env bash
set -euo pipefail

# Agent sessions run GitHub as the bot account (ADR-0038, #277 follow-up):
# per-plane env injection of GH_TOKEN, which gh honors over hosts.yml, so the
# operator's terminal (gh auth switch is machine-global state) is never touched.
# The token lives ONLY in the machine-local config's [data.githubBot] table -
# preserved across chezmoi init by the same hasKey re-emit pattern as
# [data.backup] - and flows into two merge-not-own modify templates:
#   Claude Code: ~/.claude/settings.json "env" (documented, stable)
#   Codex:       ~/.codex/config.toml [shell_environment_policy.set]
#                ("Explicit environment values injected after exclusions")
# opencode and agy are SKIPPED: their config surfaces expose no env mechanism
# (verified against the live opencode.ai/config.json schema - no top-level env -
# and agy's installed ~/.gemini config files), and the only other injection
# point would be a shell profile, which this repo forbids for secrets.
#
# Executed: both modify templates run against fixture stdin with and without
# the local data, and the machine-local plumbing (ignore exception, config
# re-emit, installer wording) is asserted literally.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

claude_tmpl="$repo_root/dot_claude/modify_settings.json"
codex_tmpl="$repo_root/dot_codex/modify_private_config.toml"
[ -f "$claude_tmpl" ] || fail "dot_claude/modify_settings.json is missing"
[ -f "$codex_tmpl" ] || fail "dot_codex/modify_private_config.toml is missing"
pass

# --- wiring, asserted literally -------------------------------------------------------------
require "$repo_root/.chezmoiignore" '!.claude/settings.json'
require "$repo_root/.chezmoi.toml.tmpl" '[data.githubBot]'
require "$repo_root/.chezmoi.toml.tmpl" '"githubBot" .githubBot'
require "$repo_root/run_after_agent-gh-identity-permissions.sh.tmpl" 'chmod 600 "$f"'
require "$repo_root/install.ps1" "guardrail operator enroll"
if grep -Fq "Run 'guardrail setup' to enroll" "$repo_root/install.ps1"; then
    fail "install.ps1: the enrollment hint must name 'guardrail operator enroll', not 'guardrail setup'"
fi
require "$repo_root/install.ps1" 'Passkey approval mode only'
pass

# --- no token literal in any tracked file ---------------------------------------------------
if git -C "$repo_root" grep -qIE 'gh[pousr]_[A-Za-z0-9]{20,}' HEAD -- . 2>/dev/null; then
    fail "a GitHub token literal is committed in the tree"
fi
pass

# --- Claude Code: env.GH_TOKEN merged, existing keys kept; absent secret = untouched ---------
if command -v chezmoi >/dev/null && command -v jq >/dev/null; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    : >"$tmp/cfg.toml"
    run_tmpl() { # $1 template, $2 override-json, stdin fixture
        chezmoi execute-template --config "$tmp/cfg.toml" --source "$repo_root" \
            --with-stdin --file "$1" --override-data "$2"
    }
    printf '// c\n{"env":{"OTHER":"keep"},"permissions":{"allow":["Bash(make:*)"]},}\n' \
        | run_tmpl "$claude_tmpl" '{"githubBot":{"token":"ghfake_TESTTOKEN_1234567890"}}' \
        | jq -e '.env.GH_TOKEN == "ghfake_TESTTOKEN_1234567890" and .env.OTHER == "keep" and .permissions.allow[0] == "Bash(make:*)"' >/dev/null \
        || fail "claude: env.GH_TOKEN must merge without clobbering env or other keys"
    printf '{"env":{"OTHER":"keep"}}\n' \
        | run_tmpl "$claude_tmpl" '{}' \
        | jq -e '(.env.GH_TOKEN // "") == "" and .env.OTHER == "keep"' >/dev/null \
        || fail "claude: without [data.githubBot] no GH_TOKEN may appear, existing env kept"
    # --- Codex: the set-section forced, exotic content preserved; absent secret = absent ------
    cat >"$tmp/codex-in.toml" <<'EOF'
[projects.'C:\Users\lab\repo']
trust_level = "trusted"

[tui]
copy_on_select = "auto"
EOF
    run_tmpl "$codex_tmpl" '{"githubBot":{"token":"ghfake_TESTTOKEN_1234567890"}}' <"$tmp/codex-in.toml" >"$tmp/codex-out.toml"
    grep -Fq 'GH_TOKEN = "ghfake_TESTTOKEN_1234567890"' "$tmp/codex-out.toml" \
        || fail "codex: [shell_environment_policy.set] GH_TOKEN must be forced"
    grep -Fq "[shell_environment_policy.set]" "$tmp/codex-out.toml" \
        || fail "codex: the set table header must be present"
    grep -Fq 'trust_level = "trusted"' "$tmp/codex-out.toml" \
        || fail "codex: existing project trust entries must survive the merge"
    grep -Fq "[projects.'C:\\Users\\lab\\repo']" "$tmp/codex-out.toml" \
        || fail "codex: the exotic backslash table header must survive byte-for-byte"
    run_tmpl "$codex_tmpl" '{}' <"$tmp/codex-in.toml" >"$tmp/codex-off.toml"
    if grep -Fq 'GH_TOKEN' "$tmp/codex-off.toml"; then
        fail "codex: without [data.githubBot] no GH_TOKEN may be written"
    fi
    grep -Fq 'trust_level = "trusted"' "$tmp/codex-off.toml" \
        || fail "codex: passthrough without the secret must still preserve content"
    pass
fi

finish
