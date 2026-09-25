#!/usr/bin/env bash
set -euo pipefail

# ssh-agent-relay contract: one key vault (the Windows agent), one FILTERED
# socket per account. The security property is that a socket handed to a
# devcontainer exposes only that account's keys - verified live with two
# accounts' keys in one agent, not assumed.
#
# Pinned behaviors:
#   - one socket per [[data.accounts]] entry, keys selected by comment
#     (devprofile's convention: <email> and <email>-sign), overridable
#   - a missing ssh-agent-filter degrades to the unfiltered agent WITH a warning
#   - idempotent start, clear errors, no key material anywhere
#   - the tooling it needs is actually installed by the package groups

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpl="$repo_root/dot_local/bin/executable_ssh-agent-relay.tmpl"
zshrc="$repo_root/dot_zshrc"
doc="$repo_root/docs/ssh-agents.md"

. "$repo_root/tests/lib.sh"

[ -f "$tmpl" ] || { fail "ssh-agent-relay template missing"; exit 1; }
[ -f "$doc" ] || { fail "docs/ssh-agents.md missing"; exit 1; }

# The relay is useless without its tooling, and each piece has a distinct job.
# The core apt line renders from the package catalog (#83), so the requirement
# is on the catalog: both tools must be core apt packages there.
grep -Fq 'apt: socat' "$repo_root/.chezmoidata/packages.yaml" ||
    fail ".chezmoidata/packages.yaml: core must install socat (WSL relay)"
grep -Fq 'apt: ssh-agent-filter' "$repo_root/.chezmoidata/packages.yaml" ||
    fail ".chezmoidata/packages.yaml: core must install ssh-agent-filter (per-account isolation)"
grep -Fq 'choco: npiperelay' "$repo_root/.chezmoidata/packages.yaml" ||
    fail ".chezmoidata/packages.yaml: core must install npiperelay on Windows (agent pipe -> WSL)"

# The shell hook must never block a prompt or hard-depend on the relay existing.
grep -Fq 'ssh-agent-relay start' "$zshrc" || fail "dot_zshrc: no ssh-agent-relay startup"
grep -Fq 'command -v ssh-agent-relay' "$zshrc" || fail "dot_zshrc: relay startup must be guarded"
grep -Fq 'default.sock' "$zshrc" || fail "dot_zshrc: must read the relay's fixed default socket path"

# The relay may ask an agent to load a local key (native mode), but must never
# read, copy or write key MATERIAL itself - it deals in sockets.
! grep -qE '(cat|cp|mv|tee|base64)[^|]*\$HOME/\.ssh/' "$tmpl" ||
    fail "relay must not read or copy key files"
! grep -qE '>[[:space:]]*"?\$HOME/\.ssh/' "$tmpl" ||
    fail "relay must not write into ~/.ssh (the identity generator owns that)"

if command -v chezmoi >/dev/null && command -v shellcheck >/dev/null; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    : >"$tmp/chezmoi.toml"
    render_relay() {  # $1 = accounts JSON (lib.sh's render is the no-override default)
        chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
            --override-data "{\"chezmoi\":{\"os\":\"linux\",\"kernel\":{\"osrelease\":\"6.8-microsoft\"}},\"accounts\":$1}" \
            <"$tmpl"
    }
    two='[{"name":"A","email":"a@x.test","username":"alpha","provider":"github","key":"id_a"},
          {"name":"B","email":"b@x.test","username":"beta","provider":"github","key":"id_b","agent_key_comments":["custom-comment"]}]'
    out=$(render_relay "$two")
    printf '%s' "$out" >"$tmp/relay"
    bash -n "$tmp/relay" || fail "rendered relay is not valid bash"
    shellcheck -s bash "$tmp/relay" >/dev/null || fail "rendered relay is not shellcheck-clean"

    grep -Fq 'ACCOUNT_COMMENTS["github-alpha"]="a@x.test|a@x.test-sign"' "$tmp/relay" ||
        fail "default key comments must be <email> and <email>-sign"
    grep -Fq 'ACCOUNT_COMMENTS["github-beta"]="custom-comment"' "$tmp/relay" ||
        fail "agent_key_comments must override the default mapping"
    grep -Fq 'DEFAULT_ALIAS="${SSH_AGENT_RELAY_DEFAULT:-github-alpha}"' "$tmp/relay" ||
        fail "default account must be the first one, overridable by env"

    # The WSL half is static-only here (CI is not WSL): the filter must be used
    # with the account's comments, from a native TMPDIR, and must degrade loudly.
    grep -Fq 'ssh-agent-filter --name' "$tmpl" || fail "relay must drive ssh-agent-filter in relay mode"
    grep -Fq 'TMPDIR="$runtime_dir"' "$tmpl" ||
        fail "the filter needs a native TMPDIR (a /mnt/c path fails with 'bind: Operation not supported')"
    grep -Fq 'UNFILTERED' "$tmpl" || fail "a missing ssh-agent-filter must warn that isolation is lost"

    # Native mode behaviour, exercised for real: each account's socket must hold
    # ONLY that account's keys, and a passphrase-protected key must not block.
    if command -v ssh-agent >/dev/null && command -v ssh-keygen >/dev/null; then
        export XDG_RUNTIME_DIR="$tmp/run"; mkdir -p "$XDG_RUNTIME_DIR"
        export HOME="$tmp/home"; mkdir -p "$HOME/.ssh"
        chmod +x "$tmp/relay"
        ssh-keygen -q -t ed25519 -N '' -C a@x.test -f "$HOME/.ssh/id_a"
        ssh-keygen -q -t ed25519 -N '' -C b@x.test -f "$HOME/.ssh/id_b"
        # A third account whose key has a passphrase: must not hang the start.
        ssh-keygen -q -t ed25519 -N 'hunter2' -C c@x.test -f "$HOME/.ssh/id_c"

        SSH_AGENT_RELAY_NATIVE=1 timeout 60 "$tmp/relay" start 2>"$tmp/err" ||
            fail "native start failed: $(cat "$tmp/err")"
        a_sock=$(SSH_AGENT_RELAY_NATIVE=1 "$tmp/relay" use github-alpha | sed 's/^export SSH_AUTH_SOCK=//')
        b_sock=$(SSH_AGENT_RELAY_NATIVE=1 "$tmp/relay" use github-beta | sed 's/^export SSH_AUTH_SOCK=//')
        [ -n "$a_sock" ] && [ "$a_sock" != "$b_sock" ] ||
            fail "each account needs its own socket (got '$a_sock' and '$b_sock')"
        SSH_AUTH_SOCK="$a_sock" ssh-add -l 2>/dev/null | grep -q 'a@x.test' ||
            fail "alpha's socket must hold alpha's key"
        SSH_AUTH_SOCK="$a_sock" ssh-add -l 2>/dev/null | grep -q 'b@x.test' &&
            fail "SECURITY: beta's key is reachable through alpha's socket"
        SSH_AUTH_SOCK="$b_sock" ssh-add -l 2>/dev/null | grep -q 'a@x.test' &&
            fail "SECURITY: alpha's key is reachable through beta's socket"

        SSH_AGENT_RELAY_NATIVE=1 "$tmp/relay" use nope >/dev/null 2>&1 &&
            fail "use <unknown alias> must fail"
        SSH_AGENT_RELAY_NATIVE=1 "$tmp/relay" start >/dev/null 2>&1 ||
            fail "start must be idempotent"
        SSH_AGENT_RELAY_NATIVE=1 "$tmp/relay" stop >/dev/null 2>&1 || true
        pkill -f "ssh-agent -a $XDG_RUNTIME_DIR" >/dev/null 2>&1 || true
    fi
fi

finish
