#!/usr/bin/env bash
# scripts/remote-access.sh - `dot remote` Unix twin: the machine-local
# plumbing for private remote access (Tailscale as the primary path, SSH/RDP
# as the transport, tmux as session persistence, Cloudflare Tunnel + Access
# as the optional browser path). Runs natively on Linux and macOS, and
# inside WSL for the WSL-local arm; the Windows host is driven by
# scripts/remote-access.ps1. Called by the `dot` dispatchers
# (`dot remote <subcommand>`) or directly from scripts/. Configuration comes
# from `chezmoi data` ([data.remote_access], machine-local, never
# committed); provider-side steps (tailnet enrollment, `cloudflared tunnel
# login`, Access policies) stay manual and are never automated here.

set -euo pipefail

ra_usage() {
    cat <<'EOF'
usage: remote-access.sh <subcommand> [args]

dot remote - personal remote access plumbing (#165). Tailscale provides
connectivity; SSH/RDP provide remote access; tmux provides session
persistence. Cloudflare Tunnel is the optional browser path, only behind
Cloudflare Access.

subcommands:
  setup             idempotently configure this host's remote-access plumbing
  status            read-only doctor: report the current state
  fix               repair deterministic machine-local state only
  harden-ssh        flip sshd to key-only (guarded; needs --confirmed)
  wsl-reconcile     re-sync the :2222 portproxy (Windows host only)
  tunnel render     write the machine-local cloudflared config.yml
  tunnel validate   validate the local cloudflared config.yml

Config: [data.remote_access] in your machine-local chezmoi config.
Manual provider steps are never automated by this script.
EOF
}

ra_die() {
    printf 'remote-access: %s\n' "$1" >&2
    exit 1
}

# Implemented by follow-up tasks against this same harness; the dispatch and
# config load land first so each arm grows one at a time. Never claim success
# silently.
ra_todo() {
    printf 'dot remote %s: not implemented yet\n' "$1" >&2
    return 1
}

cmd_setup()           { ra_todo setup; }
cmd_fix()             { ra_todo fix; }
cmd_harden_ssh()      { ra_todo harden-ssh; }
cmd_tunnel_render()   { ra_todo "tunnel render"; }
cmd_tunnel_validate() { ra_todo "tunnel validate"; }

cmd_wsl_reconcile() {
    # The :2222 portproxy rule lives on the Windows host (wsl.exe +
    # netsh interface portproxy land); the Unix twin owns nothing here.
    printf 'not applicable on this platform - run on the Windows host\n'
}

cmd_status() {
    # Read-only doctor; the full sections land with the status task. Until
    # the host declares [data.remote_access] with enabled=true there is
    # nothing to doctor.
    local enabled
    enabled="$(ra_cfg enabled false)"
    if [ "$enabled" != "true" ]; then
        printf 'not configured\n'
        return 0
    fi
    printf 'remote access: enabled\n'
}

ra_data_json() {
    # The [data.remote_access] object from `chezmoi data`, as compact JSON;
    # an empty object when the key is absent. jq first, python3 fallback
    # (both are present in WSL and CI).
    local data
    data="$(chezmoi data --format json)"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$data" | jq -c '.remote_access // {}'
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$data" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
print(json.dumps(doc.get("remote_access") or {}))
'
    else
        ra_die "need jq or python3 to read chezmoi data"
    fi
}

# ra_cfg DOTTED.PATH DEFAULT: read [data.remote_access.PATH], yielding
# DEFAULT when the path is absent or false (jq `//` semantics). The lookup
# path is built by joining the dotted segments, so `ra_cfg linux.ssh false`
# reads .remote_access.linux.ssh through the same resolver as ra_data_json.
ra_cfg() {
    local dotted="$1" default="$2" json="" seg jqpath=""
    json="$(ra_data_json)"
    while [ -n "$dotted" ]; do
        seg="${dotted%%.*}"
        jqpath="${jqpath}[\"${seg}\"]"
        [ "$dotted" = "$seg" ] && break
        dotted="${dotted#*.}"
    done
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r --arg default "$default" "${jqpath} // \$default"
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
cur = doc
for seg in sys.argv[1].split("."):
    if not isinstance(cur, dict) or seg not in cur:
        cur = None
        break
    cur = cur[seg]
if cur is None or cur is False:
    print(sys.argv[2])
elif cur is True:
    print("true")
else:
    print(cur)
' "$1" "$default"
    else
        ra_die "need jq or python3 to read chezmoi data"
    fi
}

main() {
    local cmd="${1:-}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        setup)         cmd_setup "$@" ;;
        status)        cmd_status "$@" ;;
        fix)           cmd_fix "$@" ;;
        harden-ssh)    cmd_harden_ssh "$@" ;;
        wsl-reconcile) cmd_wsl_reconcile "$@" ;;
        tunnel)
            case "${1:-}" in
                render)  shift; cmd_tunnel_render "$@" ;;
                validate) shift; cmd_tunnel_validate "$@" ;;
                *) ra_usage >&2; exit 2 ;;
            esac
            ;;
        *) ra_usage >&2; exit 2 ;;
    esac
}

main "$@"
