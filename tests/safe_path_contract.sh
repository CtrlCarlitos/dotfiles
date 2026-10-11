#!/usr/bin/env bash
set -euo pipefail

# safe_path (tests/lib.sh): the test harness's own PATH hygiene. Several test files
# assume "no <tool> on PATH" to exercise a real install path (install_maestro's
# download, the licenses-first ordering in mobile_dev_install_contract.sh, the
# mobile_dev sweep in agent_tool_upgrade_contract.sh) - true on a clean CI runner,
# false on a dev machine that has run `dot up`/`dot upgrade` for real: this
# machine's genuine ~/.local/bin/maestro leaked through the old
# `PATH="$tmp/bin:$PATH"` prepend and broke every one of those scenarios
# (2026-10-11), since nothing stopped `command -v maestro` from falling through
# the untouched tail of $PATH to the real install.
#
# The contract: safe_path strips $HOME/.local/bin and every $HOME/.local/opt/*/bin
# (the directories this repo's own installers manage a tool in) from $PATH, reads
# $HOME at call time (call it BEFORE overriding HOME for the subprocess under
# test), and leaves every other directory - including ones that merely look
# similar - untouched.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lib="$repo_root/tests/lib.sh"
. "$lib"

bash_bin="$(command -v bash)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.local/bin" "$tmp/home/.local/opt/maestro/bin" "$tmp/home/.local/opt/other/bin" "$tmp/keep-a" "$tmp/keep-b"

# Exported, not re-sourced: the subprocess's PATH is deliberately pared down to
# exactly the directories under test, too narrow to resolve lib.sh's own
# dirname/cd (its usual bootstrap, fine under a real $PATH, not this one).
export -f safe_path
got="$(HOME="$tmp/home" PATH="$tmp/keep-a:$tmp/home/.local/bin:$tmp/home/.local/opt/maestro/bin:$tmp/keep-b:$tmp/home/.local/opt/other/bin" \
    "$bash_bin" -c 'safe_path')"

case ":$got:" in
    *":$tmp/home/.local/bin:"*) fail "safe_path: must strip \$HOME/.local/bin (got: $got)" ;;
    *) pass ;;
esac
case ":$got:" in
    *":$tmp/home/.local/opt/maestro/bin:"*) fail "safe_path: must strip \$HOME/.local/opt/*/bin (got: $got)" ;;
    *) pass ;;
esac
case ":$got:" in
    *":$tmp/home/.local/opt/other/bin:"*) fail "safe_path: must strip every \$HOME/.local/opt/*/bin, not just the first match (got: $got)" ;;
    *) pass ;;
esac
case ":$got:" in
    *":$tmp/keep-a:"*) pass ;;
    *) fail "safe_path: must keep an unrelated directory before a stripped one (got: $got)" ;;
esac
case ":$got:" in
    *":$tmp/keep-b:"*) pass ;;
    *) fail "safe_path: must keep an unrelated directory after a stripped one (got: $got)" ;;
esac

finish
