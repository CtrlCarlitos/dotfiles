#!/usr/bin/env bash
set -euo pipefail

# Agent sessions run GitHub as the bot account (ADR-0038, #277 follow-up):
# per-plane env injection of GH_TOKEN, which gh honors over hosts.yml, so the
# operator's terminal (gh auth switch is machine-global state) is never touched.
# GH_TOKEN alone only governs `gh` API calls, though - a bare `git commit` in
# the same session still falls back to ~/.gitconfig's [user] (the operator's
# identity) without GIT_AUTHOR_NAME/EMAIL and GIT_COMMITTER_NAME/EMAIL forced
# too (confirmed by a live check: commits silently defaulted to the operator).
# Both halves are forced together, gated on the same [data.githubBot] table -
# the token lives ONLY in that machine-local config, preserved across
# chezmoi init by the same hasKey re-emit pattern as [data.backup] - and flow
# into two merge-not-own modify templates:
#   Claude Code: ~/.claude/settings.json "env" (documented, stable)
#   Codex:       ~/.codex/config.toml [shell_environment_policy.set]
#                ("Explicit environment values injected after exclusions")
# The bot's name/email are fixed literals in those templates, not read from
# [data.githubBot]: one bot account for every wired machine, not per-machine
# data. opencode and agy are SKIPPED: their config surfaces expose no env
# mechanism (verified against the live opencode.ai/config.json schema - no
# top-level env - and agy's installed ~/.gemini config files), and the only
# other injection point would be a shell profile, which this repo forbids
# for secrets.
#
# Executed: both modify templates run against fixture stdin with and without
# the local data, the machine-local plumbing (ignore exception, config
# re-emit, installer wording) is asserted literally, and the Codex output is
# parsed as real TOML - a table header emitted once per forced key instead of
# once per table is a "cannot declare twice" error no grep would catch.
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
    bot_name="c20260202"
    bot_email="258988202+c20260202@users.noreply.github.com"
    run_tmpl() { # $1 template, $2 override-json, stdin fixture
        chezmoi execute-template --config "$tmp/cfg.toml" --source "$repo_root" \
            --with-stdin --file "$1" --override-data "$2"
    }
    printf '// c\n{"env":{"OTHER":"keep"},"permissions":{"allow":["Bash(make:*)"]},}\n' \
        | run_tmpl "$claude_tmpl" '{"githubBot":{"token":"ghfake_TESTTOKEN_1234567890"}}' \
        | jq -e '.env.GH_TOKEN == "ghfake_TESTTOKEN_1234567890" and .env.OTHER == "keep" and .permissions.allow[0] == "Bash(make:*)"' >/dev/null \
        || fail "claude: env.GH_TOKEN must merge without clobbering env or other keys"
    printf '// c\n{"env":{"OTHER":"keep"},"permissions":{"allow":["Bash(make:*)"]},}\n' \
        | run_tmpl "$claude_tmpl" '{"githubBot":{"token":"ghfake_TESTTOKEN_1234567890"}}' \
        | jq -e --arg name "$bot_name" --arg email "$bot_email" \
            '.env.GIT_AUTHOR_NAME == $name and .env.GIT_AUTHOR_EMAIL == $email and .env.GIT_COMMITTER_NAME == $name and .env.GIT_COMMITTER_EMAIL == $email' >/dev/null \
        || fail "claude: env.GIT_AUTHOR_*/GIT_COMMITTER_* must be forced to the bot identity alongside GH_TOKEN"
    printf '{"env":{"OTHER":"keep"}}\n' \
        | run_tmpl "$claude_tmpl" '{}' \
        | jq -e '(.env.GH_TOKEN // "") == "" and .env.OTHER == "keep"' >/dev/null \
        || fail "claude: without [data.githubBot] no GH_TOKEN may appear, existing env kept"
    printf '{"env":{"OTHER":"keep"}}\n' \
        | run_tmpl "$claude_tmpl" '{}' \
        | jq -e '(.env.GIT_AUTHOR_NAME // "") == "" and (.env.GIT_AUTHOR_EMAIL // "") == "" and (.env.GIT_COMMITTER_NAME // "") == "" and (.env.GIT_COMMITTER_EMAIL // "") == ""' >/dev/null \
        || fail "claude: without [data.githubBot] no GIT_AUTHOR_*/GIT_COMMITTER_* may appear"
    # --- Codex: the set-section forced, exotic content preserved; absent secret = absent ------
    cat >"$tmp/codex-in.toml" <<'EOF'
[projects.'C:\Users\lab\repo']
trust_level = "trusted"

[tui]
copy_on_select = "auto"
EOF
    run_tmpl "$codex_tmpl" '{"githubBot":{"token":"ghfake_TESTTOKEN_1234567890"}}' <"$tmp/codex-in.toml" >"$tmp/codex-out.toml"
    # A forced key = value line may be padded to share its block's "=" column
    # (docs/invariants.md #15): match the padded key with -E, the literal
    # value with -F so a "+"/"." in the email is never read as a metachar.
    forced_kv() { grep -E "^$1[ ]+=" "$tmp/codex-out.toml" | grep -Fq "$2"; } # $1=key regex $2=literal value
    forced_kv 'GH_TOKEN' '"ghfake_TESTTOKEN_1234567890"' \
        || fail "codex: [shell_environment_policy.set] GH_TOKEN must be forced"
    grep -Fq "[shell_environment_policy.set]" "$tmp/codex-out.toml" \
        || fail "codex: the set table header must be present"
    grep -Fq 'trust_level = "trusted"' "$tmp/codex-out.toml" \
        || fail "codex: existing project trust entries must survive the merge"
    grep -Fq "[projects.'C:\\Users\\lab\\repo']" "$tmp/codex-out.toml" \
        || fail "codex: the exotic backslash table header must survive byte-for-byte"
    forced_kv 'GIT_AUTHOR_NAME' "\"$bot_name\"" \
        || fail "codex: [shell_environment_policy.set] GIT_AUTHOR_NAME must be forced"
    forced_kv 'GIT_AUTHOR_EMAIL' "\"$bot_email\"" \
        || fail "codex: [shell_environment_policy.set] GIT_AUTHOR_EMAIL must be forced"
    forced_kv 'GIT_COMMITTER_NAME' "\"$bot_name\"" \
        || fail "codex: [shell_environment_policy.set] GIT_COMMITTER_NAME must be forced"
    forced_kv 'GIT_COMMITTER_EMAIL' "\"$bot_email\"" \
        || fail "codex: [shell_environment_policy.set] GIT_COMMITTER_EMAIL must be forced"
    run_tmpl "$codex_tmpl" '{"githubBot":{"token":"ghfake_TESTTOKEN_1234567890"}}' <"$tmp/codex-out.toml" >"$tmp/codex-out2.toml"
    diff -u "$tmp/codex-out.toml" "$tmp/codex-out2.toml" >/dev/null \
        || fail "codex: re-rendering the forced output must be idempotent"
    run_tmpl "$codex_tmpl" '{}' <"$tmp/codex-in.toml" >"$tmp/codex-off.toml"
    if grep -Fq 'GH_TOKEN' "$tmp/codex-off.toml"; then
        fail "codex: without [data.githubBot] no GH_TOKEN may be written"
    fi
    if grep -Eq 'GIT_AUTHOR_|GIT_COMMITTER_' "$tmp/codex-off.toml"; then
        fail "codex: without [data.githubBot] no GIT_AUTHOR_*/GIT_COMMITTER_* may be written"
    fi
    grep -Fq 'trust_level = "trusted"' "$tmp/codex-off.toml" \
        || fail "codex: passthrough without the secret must still preserve content"
    # Literal-string checks above describe intent; this is the one that catches
    # output that merely looks right - e.g. the same table header emitted once
    # per forced key (a real TOML "duplicate table" error no grep would see).
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
        for f in "$tmp/codex-out.toml" "$tmp/codex-off.toml"; do
            python3 - "$f" <<'PY' || fail "codex: rendered output is not valid TOML: see above"
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    try:
        tomllib.load(fh)
    except Exception as exc:
        print(f"{sys.argv[1]}: {exc}", file=sys.stderr)
        raise SystemExit(1)
PY
        done
        # docs/invariants.md #15: a block of two+ "key = value" lines shares one
        # "=" column. GH_TOKEN and the four GIT_AUTHOR_*/GIT_COMMITTER_* lines
        # all land in the same forced block and must stay aligned on every apply.
        python3 - "$tmp/codex-out.toml" <<'PY' || fail "codex: [shell_environment_policy.set] forced block must share one '=' column (docs/invariants.md #15)"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"\[shell_environment_policy\.set\]\n((?:[^\n\[]*\n?)*)", text)
assert m, "shell_environment_policy.set table not found"
block = [l for l in m.group(1).splitlines() if l.strip()]
cols = {l.index("=") for l in block if "=" in l}
assert len(cols) == 1, f"ragged '=' columns: {cols}\n" + "\n".join(block)
PY
    fi
    pass
fi

finish
