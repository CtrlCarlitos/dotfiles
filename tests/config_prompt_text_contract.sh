#!/usr/bin/env bash
set -euo pipefail

# The package prompts in .chezmoi.toml.tmpl must not end in a question mark:
# chezmoi's promptBool/promptString append their own, so a string that carries
# one renders as "Install mobile_dev (...)??" - which is what the first unanswered
# prompt in months showed on a WSL `dot up` (2026-10-11). Every one of the 17
# prompts carried the extra mark; nobody saw it because each is asked once and
# then read back from the config. A grep, because chezmoi's prompt rendering
# cannot be executed without a terminal.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmpl="$repo_root/.chezmoi.toml.tmpl"
[ -f "$tmpl" ] || { fail "$tmpl missing"; finish; }

bad="$(grep -nE 'prompt(Bool|String|Int)Once?[[:space:]]+\.[[:space:]]+"[^"]*"[[:space:]]+"[^"]*\?"' "$tmpl" || true)"
if [ -n "$bad" ]; then
    fail "prompt strings must not end in '?' (chezmoi adds one): $(printf '%s' "$bad" | cut -c1-120 | tr '\n' '|')"
else
    pass
fi
# ... and there are still prompts to check (the pattern did not simply stop matching).
n="$(grep -cE 'prompt(Bool|String|Int)Once?[[:space:]]+\.' "$tmpl" || true)"
[ "$n" -ge 17 ] || fail "expected at least 17 prompts in $tmpl, found $n"

finish
