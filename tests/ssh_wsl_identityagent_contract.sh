#!/usr/bin/env bash
set -euo pipefail

# WSL ssh_hosts agent contract: on WSL the shell's SSH_AUTH_SOCK is a
# per-account FILTERED relay socket (Git keys only), so a server key pinned by
# its .pub half (IdentityFile ~/.ssh/<id>.pub + IdentitiesOnly) never matches
# there. The Host blocks must therefore point at the relay's UPSTREAM socket -
# on WSL only. Native Linux, macOS and Windows have no upstream socket and must
# not get the line.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

tmpl="$repo_root/private_dot_ssh/private_config.tmpl"
[ -f "$tmpl" ] || { fail "private_dot_ssh/private_config.tmpl missing"; finish; }

hosts='"ssh_hosts":[{"name":"pinned","hostname":"p.example.com","identity":"id_pinned"},{"name":"plain","hostname":"q.example.com"}]'

# render_cfg <os> <osrelease> [XDG_RUNTIME_DIR] -> rendered ssh config on stdout
render_cfg() {
    local os="$1" rel="$2" xdg="${3:-}" data
    data="{\"chezmoi\":{\"os\":\"$os\",\"kernel\":{\"osrelease\":\"$rel\"}},$hosts}"
    if [ -n "$xdg" ]; then
        XDG_RUNTIME_DIR="$xdg" render --override-data "$data" <"$tmpl"
    else
        env -u XDG_RUNTIME_DIR bash -c '. "$1/tests/lib.sh"; render --override-data "$2" <"$3"' _ "$repo_root" "$data" "$tmpl"
    fi
}

# Host block of a given alias (from its Host line up to the next Host line).
host_block() { awk -v n="$1" '$1=="Host" { on = ($2==n) } on' ; }

# 1. WSL with XDG_RUNTIME_DIR: the pinned host gets the upstream agent, via the
#    env var ssh expands itself; the key-less host gets nothing.
out="$(render_cfg linux "5.15.153.1-microsoft-standard-WSL2" /run/user/1000)"
pinned="$(printf '%s\n' "$out" | host_block pinned)"
plain="$(printf '%s\n' "$out" | host_block plain)"
if printf '%s\n' "$pinned" | grep -Fq 'IdentityAgent ${XDG_RUNTIME_DIR}/ssh-agent.upstream.sock'; then pass; else
    fail "WSL: pinned host must point IdentityAgent at \${XDG_RUNTIME_DIR}/ssh-agent.upstream.sock"
fi
if printf '%s\n' "$pinned" | grep -Fq 'IdentityFile ~/.ssh/id_pinned.pub'; then pass; else
    fail "WSL: pinned host must keep referencing the .pub half"
fi
if printf '%s\n' "$plain" | grep -q 'IdentityAgent'; then
    fail "WSL: a host without an identity must not get an IdentityAgent line"
else pass; fi

# 2. WSL without XDG_RUNTIME_DIR: fall back to the relay's own /tmp path (%i = uid).
out="$(render_cfg linux "5.15.153.1-microsoft-standard-WSL2")"
if printf '%s\n' "$out" | host_block pinned | grep -Fq 'IdentityAgent /tmp/ssh-agent-relay-%i/ssh-agent.upstream.sock'; then pass; else
    fail "WSL without XDG_RUNTIME_DIR: expected the /tmp/ssh-agent-relay-%i fallback path"
fi

# 3. Hosts with no upstream socket must not get the line.
for case in "linux|6.8.0-45-generic|native Linux" "darwin|23.6.0|macOS" "windows|10.0.26200|Windows"; do
    IFS='|' read -r os rel label <<<"$case"
    out="$(render_cfg "$os" "$rel" /run/user/1000)"
    if printf '%s\n' "$out" | grep -q 'IdentityAgent'; then
        fail "$label: no relay upstream exists, IdentityAgent must not be emitted"
    else pass; fi
done

finish
