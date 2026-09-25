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
#   - bash 3.2-safe (macOS ships 3.2): indexed arrays only, renders for
#     darwin, parses under `bash --posix` (#113)
#   - stop kills what start spawned; no external pkill cleanup here (#113)

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
# One shared state dir, exported by the shell and honoured by the relay (#113).
grep -Fq 'export SSH_AGENT_RELAY_DIR=' "$zshrc" ||
    fail "dot_zshrc: must export SSH_AGENT_RELAY_DIR (single source for the state dir)"
grep -Fq 'SSH_AGENT_RELAY_DIR' "$tmpl" ||
    fail "relay must honour SSH_AGENT_RELAY_DIR (single source for the state dir)"
# The OMZ ssh-agent plugin would start a second agent that the relay's socket
# then shadows - it must be gated off when the relay is installed (#113).
grep -Fq 'if ! command -v ssh-agent-relay &>/dev/null && [[ ! -x "$HOME/.local/bin/ssh-agent-relay" ]]; then' "$zshrc" ||
    fail "dot_zshrc: OMZ ssh-agent plugin must be gated on the relay being absent"
grep -Fq 'ssh-agent-relay stop' "$doc" || fail "docs/ssh-agents.md: must document stop"

# The relay may ask an agent to load a local key (native mode), but must never
# read, copy or write key MATERIAL itself - it deals in sockets.
! grep -qE '(cat|cp|mv|tee|base64)[^|]*\$HOME/\.ssh/' "$tmpl" ||
    fail "relay must not read or copy key files"
! grep -qE '>[[:space:]]*"?\$HOME/\.ssh/' "$tmpl" ||
    fail "relay must not write into ~/.ssh (the identity generator owns that)"

# bash 3.2 has no associative arrays (the old `declare -A` maps died silently
# on macOS, whose /usr/bin/bash is 3.2 - zshrc discards the error) (#113).
! grep -Eq '^[[:space:]]*declare +-A' "$tmpl" ||
    fail "relay must not use associative arrays (macOS ships bash 3.2)"
! grep -q 'sock_alive' "$tmpl" || fail "sock_alive() had zero callers - dead code"

if command -v chezmoi >/dev/null && command -v shellcheck >/dev/null; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    : >"$tmp/chezmoi.toml"
    render_relay() {  # $1 = os ("linux"|"darwin"), $2 = accounts JSON
        chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
            --override-data "{\"chezmoi\":{\"os\":\"$1\",\"kernel\":{\"osrelease\":\"6.8-microsoft\"}},\"accounts\":$2}" \
            <"$tmpl"
    }
    two='[{"name":"A","email":"a@x.test","username":"alpha","provider":"github","key":"id_a"},
          {"name":"B","email":"b@x.test","username":"beta","provider":"github","key":"id_b","agent_key_comments":["custom-comment"]}]'
    out=$(render_relay linux "$two")
    printf '%s' "$out" >"$tmp/relay"
    bash -n "$tmp/relay" || fail "rendered relay is not valid bash"
    # bash --posix is the closest CI-runnable proxy for macOS's bash 3.2: it
    # rejects bash-4-isms at runtime and keeps the syntax dialect strict.
    bash --posix -n "$tmp/relay" || fail "rendered relay does not parse under bash --posix (bash 3.2 proxy)"
    shellcheck -s bash "$tmp/relay" >/dev/null || fail "rendered relay is not shellcheck-clean"

    # Parallel-array representation (bash 3.2-safe): every account appends one
    # aligned row to each of the three arrays.
    grep -Fq 'RELAY_ALIASES+=("github-alpha")' "$tmp/relay" || fail "alpha missing from the alias array"
    grep -Fq 'RELAY_COMMENTS+=("a@x.test|a@x.test-sign")' "$tmp/relay" ||
        fail "default key comments must be <email> and <email>-sign"
    grep -Fq 'RELAY_KEYS+=("id_a")' "$tmp/relay" || fail "auth key must render into the keys array"
    grep -Fq 'RELAY_ALIASES+=("github-beta")' "$tmp/relay" || fail "beta missing from the alias array"
    grep -Fq 'RELAY_COMMENTS+=("custom-comment")' "$tmp/relay" ||
        fail "agent_key_comments must override the default mapping"
    grep -Fq 'DEFAULT_ALIAS="${SSH_AGENT_RELAY_DEFAULT:-github-alpha}"' "$tmp/relay" ||
        fail "default account must be the first one, overridable by env"
    # The agent PID must be captured at start - cmd_stop kills it (#113).
    grep -Fq 'eval "$agent_env"' "$tmpl" || fail "relay must capture ssh-agent's shell code (PID) for stop"

    # darwin render gate: the file ships to macOS, so it must render and parse
    # there too - not just for the linux kernel the old test rendered (#113).
    out_darwin=$(render_relay darwin "$two")
    printf '%s' "$out_darwin" >"$tmp/relay-darwin"
    bash -n "$tmp/relay-darwin" || fail "darwin render is not valid bash"
    bash --posix -n "$tmp/relay-darwin" || fail "darwin render does not parse under bash --posix (bash 3.2 proxy)"

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
        # bash --posix as a bash-3.2 proxy, for real: the status path walks the
        # arrays (a `declare -A` regression fails right here, not silently).
        SSH_AGENT_RELAY_NATIVE=1 bash --posix "$tmp/relay" status >/dev/null 2>&1 ||
            fail "relay must run under bash --posix (bash 3.2 proxy)"

        # stop must kill what start spawned - this file used to pkill the
        # agents itself to work around stop's leak (#113). No more.
        SSH_AGENT_RELAY_NATIVE=1 "$tmp/relay" stop >/dev/null 2>&1 || fail "stop must succeed"
        [ -S "$a_sock" ] && fail "stop must remove the per-account socket"
        if command -v pgrep >/dev/null 2>&1; then
            pgrep -f "ssh-agent -a $XDG_RUNTIME_DIR" >/dev/null 2>&1 &&
                fail "stop must kill the per-account agents (the #113 leak)"
        fi
        # And start must come back cleanly afterwards.
        SSH_AGENT_RELAY_NATIVE=1 timeout 60 "$tmp/relay" start >/dev/null 2>&1 ||
            fail "start must work again after stop"
        SSH_AGENT_RELAY_NATIVE=1 "$tmp/relay" stop >/dev/null 2>&1 || true
    fi
fi

finish
