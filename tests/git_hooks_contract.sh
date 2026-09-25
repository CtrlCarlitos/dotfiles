#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# The shared commit-msg hook (core.hooksPath = ~/.config/git/hooks) exists
# because a Claude Code session added an agent co-author trailer to a commit on
# 2026-09-24 while the attribution setting that should have prevented it was
# not yet applied on that machine. GitHub's squash merge then copied the
# trailer a second time. A git-level guard does not depend on any agent's
# settings being in effect, so it holds on every machine and for every agent.
#
# Each check builds on the previous one (a missing hook makes every later
# assertion meaningless), so stop at the first failure.
export TESTS_FAILFAST=1

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
hook="$repo_root/dot_config/git/hooks/executable_commit-msg"

#-------------------------------------------------------------------------------
# 1. Wiring: the hook ships, gitconfig points at its directory, the doc says so.
#-------------------------------------------------------------------------------
[ -f "$hook" ] || fail "dot_config/git/hooks/executable_commit-msg is missing"
pass
head -1 "$hook" | grep -q '^#!/bin/sh$' || fail 'commit-msg must be POSIX sh (#!/bin/sh) - Git for Windows runs hooks with its bundled sh'
pass
if tr -cd '\r' < "$hook" | grep -q .; then
    fail 'commit-msg contains CR bytes - sh would reject the shebang line'
fi
pass
require "$repo_root/dot_gitconfig.tmpl" 'hooksPath = ~/.config/git/hooks'
require "$repo_root/docs/git.md" 'hooksPath'
require "$repo_root/docs/git.md" 'pre-commit install'
if grep -q 'rev-parse --git-path hooks' "$hook"; then
    fail '--git-path hooks honours core.hooksPath and would resolve to this very file (infinite recursion); use --git-common-dir'
fi
pass

#-------------------------------------------------------------------------------
# 2. Behaviour, run directly against message files inside a scratch repo.
#-------------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" config user.name test
git -C "$tmp" config user.email test@example.com
git -C "$tmp" config commit.gpgsign false

run_hook() { (cd "$tmp" && sh "$hook" "$1"); }

# 2a. Both spellings go (the agent writes Co-Authored-By, GitHub's squash merge
#     adds Co-authored-by); a human co-author and the body stay byte-identical.
cat > "$tmp/msg" <<'MSG'
feat: something

Body line one.
Body line two.

Co-authored-by: Jane Doe <jane@example.com>
Co-Authored-By: Claude <noreply@anthropic.com>
Co-authored-by: Claude <noreply@anthropic.com>
MSG
cat > "$tmp/want" <<'MSG'
feat: something

Body line one.
Body line two.

Co-authored-by: Jane Doe <jane@example.com>
MSG
err="$(run_hook "$tmp/msg" 2>&1 >/dev/null)" || fail "hook exited non-zero on a message with the trailer"
cmp -s "$tmp/msg" "$tmp/want" || { diff "$tmp/want" "$tmp/msg" >&2 || true; fail "trailer removal changed more than the Claude lines"; }
printf '%s' "$err" | grep -qi 'claude' || fail "hook must say on stderr that it removed the trailer (got: $err)"
pass

# 2b. A message without the trailer is untouched and the hook stays silent.
printf 'fix: plain\n\nNo trailers here.\n' > "$tmp/msg"
cp "$tmp/msg" "$tmp/want"
err="$(run_hook "$tmp/msg" 2>&1 >/dev/null)" || fail "hook exited non-zero on a clean message"
cmp -s "$tmp/msg" "$tmp/want" || fail "hook modified a message that had no trailer"
[ -z "$err" ] || fail "hook must be silent on a clean message (got: $err)"
pass

# 2c. core.hooksPath silences .git/hooks; the shared hook must chain to the
#     repository's own commit-msg, pass the message path through, and
#     propagate its exit status.
mkdir -p "$tmp/.git/hooks"
cat > "$tmp/.git/hooks/commit-msg" <<'LOCAL'
#!/bin/sh
printf '%s\n' "$1" > "$(dirname "$0")/../../local-ran"
exit "${LOCAL_HOOK_RC:-0}"
LOCAL
chmod +x "$tmp/.git/hooks/commit-msg"
printf 'chore: chain\n' > "$tmp/msg"
run_hook "$tmp/msg" 2>/dev/null || fail "hook failed while chaining to a passing local hook"
[ -f "$tmp/local-ran" ] || fail "repository-local .git/hooks/commit-msg was not invoked"
grep -Fq -- "$tmp/msg" "$tmp/local-ran" || fail "local hook did not receive the message path"
if LOCAL_HOOK_RC=3 run_hook "$tmp/msg" 2>/dev/null; then
    fail "a failing local hook must fail the commit (exit status not propagated)"
fi
pass
rm -f "$tmp/.git/hooks/commit-msg" "$tmp/local-ran"

#-------------------------------------------------------------------------------
# 3. End to end through git itself, with core.hooksPath set the way the
#    rendered gitconfig sets it.
#-------------------------------------------------------------------------------
hooks_dir="$tmp/hooks"
mkdir -p "$hooks_dir"
cp "$hook" "$hooks_dir/commit-msg"
chmod +x "$hooks_dir/commit-msg"
git -C "$tmp" config core.hooksPath "$hooks_dir"
printf 'x\n' > "$tmp/file"
git -C "$tmp" add file
git -C "$tmp" commit -q -m 'feat: end to end' -m 'Co-Authored-By: Claude <noreply@anthropic.com>' 2>/dev/null ||
    fail "git commit failed with the hook installed via core.hooksPath"
if git -C "$tmp" log -1 --format=%B | grep -qi 'claude'; then
    fail "trailer survived a real git commit"
fi
[ "$(git -C "$tmp" log -1 --format=%s)" = 'feat: end to end' ] || fail "subject changed during a real git commit"
pass

finish
