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

cmd_fix()             { ra_todo fix; }
cmd_harden_ssh()      { ra_todo harden-ssh; }
cmd_tunnel_render()   { ra_tunnel_render; }
cmd_tunnel_validate() { ra_tunnel_validate; }

cmd_wsl_reconcile() {
    # The :2222 portproxy rule lives on the Windows host (wsl.exe +
    # netsh interface portproxy land); the Unix twin owns nothing here.
    printf 'not applicable on this platform - run on the Windows host\n'
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
        # The leading dot matters: without it jq reads ["a"]["b"] as array
        # construction, not indexing, and every lookup returns the path.
        printf '%s' "$json" | jq -r --arg default "$default" ".${jqpath} // \$default"
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

# ---------------------------------------------------------------------------
# status - the read-only doctor (spec §7). One section per area, ✓ verified /
# ○ absent-or-manual-action / ✗ FAIL lines, exit 0 always. FAIL lines name
# what `fix` would repair; WARN lines name the manual action. Never prints
# secrets: probes that could echo configuration (cloudflared validate) run
# quietly and only the verdict is printed.
# ---------------------------------------------------------------------------

# The doctor's markers: ✓ verified, ○ absent / skipped / WARN (the line names
# the manual action), ✗ FAIL.
ra_ok()   { printf '✓ %s\n' "$1"; }
ra_warn() { printf '○ %s\n' "$1"; }
ra_fail() { printf '✗ %s\n' "$1"; }

# ra_json_str RAWJSON DOTTED.PATH DEFAULT: scalar lookup inside an arbitrary
# JSON document, DEFAULT when the path is absent, null/false, or a non-scalar
# (a dict/array is never repr'd). Numeric segments index arrays
# (Self.TailscaleIPs.0). jq first, python3 fallback - the same split
# ra_data_json and ra_cfg use.
ra_json_str() {
    local json="$1" dotted="$2" default="$3" orig="$2" seg jqpath="" out=""
    [ -n "$json" ] || { printf '%s' "$default"; return 0; }
    while [ -n "$dotted" ]; do
        seg="${dotted%%.*}"
        case "$seg" in
            *[!0-9]*) jqpath="${jqpath}[\"${seg}\"]" ;;
            *)        jqpath="${jqpath}[${seg}]" ;;
        esac
        [ "$dotted" = "$seg" ] && break
        dotted="${dotted#*.}"
    done
    if command -v jq >/dev/null 2>&1; then
        # Leading dot: see the note in ra_cfg.
        out="$(printf '%s' "$json" | jq -r --arg default "$default" ".${jqpath} // \$default" 2>/dev/null)" || out=""
        [ -n "$out" ] || out="$default"
    elif command -v python3 >/dev/null 2>&1; then
        out="$(printf '%s' "$json" | python3 -c '
import json, sys
cur = json.load(sys.stdin)
for seg in sys.argv[1].split("."):
    if isinstance(cur, dict) and seg in cur:
        cur = cur[seg]
    elif isinstance(cur, list) and seg.isdigit() and int(seg) < len(cur):
        cur = cur[int(seg)]
    else:
        cur = None
        break
if cur is None or cur is False or isinstance(cur, (dict, list)):
    print(sys.argv[2])
elif cur is True:
    print("true")
else:
    print(cur)
' "$orig" "$default" 2>/dev/null)" || out=""
        [ -n "$out" ] || out="$default"
    else
        ra_die "need jq or python3 to read chezmoi data"
    fi
    printf '%s' "$out"
}

# ra_cfg_keys DOTTED.PATH: child keys of the object at
# [data.remote_access.PATH], one per line; empty when absent or not an
# object. Same jq/python3 split as ra_cfg.
ra_cfg_keys() {
    local dotted="$1" json seg jqpath=""
    json="$(ra_data_json)"
    while [ -n "$dotted" ]; do
        seg="${dotted%%.*}"
        jqpath="${jqpath}[\"${seg}\"]"
        [ "$dotted" = "$seg" ] && break
        dotted="${dotted#*.}"
    done
    if command -v jq >/dev/null 2>&1; then
        # Leading dot: see the note in ra_cfg.
        printf '%s' "$json" | jq -r ".${jqpath} // {} | keys[]?" 2>/dev/null || true
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
for seg in sys.argv[1].split("."):
    if not isinstance(doc, dict) or seg not in doc:
        doc = None
        break
    doc = doc[seg]
if isinstance(doc, dict):
    for key in doc:
        print(key)
' "$1" 2>/dev/null || true
    else
        ra_die "need jq or python3 to read chezmoi data"
    fi
}

# ra_os: the running platform (uname -s), cached per process.
ra_os() {
    [ -n "${_RA_OS:-}" ] || _RA_OS="$(uname -s)"
    printf '%s\n' "$_RA_OS"
}

# ra_in_wsl: true when this shell runs inside WSL. RA_PROC_VERSION overrides
# the /proc/version content so tests pin either side of the branch on any
# host (the same seam ra_desktop_detected will use for setup).
ra_in_wsl() {
    local pv="${RA_PROC_VERSION:-}"
    if [ -z "$pv" ] && [ -r /proc/version ]; then
        pv="$(cat /proc/version)"
    fi
    case "$pv" in
        *microsoft* | *Microsoft*) return 0 ;;
        *) return 1 ;;
    esac
}

# ra_tcp_probe HOST PORT: best-effort TCP connect through bash /dev/tcp,
# 1s timeout when `timeout` exists. rc 0 = something accepted the connect.
ra_tcp_probe() {
    local host="$1" port="$2"
    if command -v timeout >/dev/null 2>&1; then
        timeout 1 bash -c ": <'/dev/tcp/${host}/${port}'" 2>/dev/null
    else
        bash -c ": <'/dev/tcp/${host}/${port}'" 2>/dev/null
    fi
}

# ra_tailscale_state: resolves the tailscale CLI into RA_TS_STATE =
# absent | unauth | ok, with the status JSON in RA_TS_JSON for the ok detail
# lines. Globals on purpose: callers must not run this inside a command
# substitution - the subshell would drop both. unauth covers everything
# short of a Running backend; the doctor renders it as the authenticate
# WARN, never a crash.
ra_tailscale_state() {
    RA_TS_STATE="absent"
    RA_TS_JSON=""
    command -v tailscale >/dev/null 2>&1 || return 0
    RA_TS_JSON="$(tailscale status --json 2>/dev/null)" || RA_TS_JSON=""
    if [ -z "$RA_TS_JSON" ]; then
        RA_TS_STATE="unauth"
        return 0
    fi
    case "$(ra_json_str "$RA_TS_JSON" BackendState unknown)" in
        Running) RA_TS_STATE="ok" ;;
        *)       RA_TS_STATE="unauth" ;;
    esac
    return 0
}

ra_status_tailscale() {
    printf 'Tailscale:\n'
    local name address
    ra_tailscale_state
    case "$RA_TS_STATE" in
        absent)
            ra_warn 'tailscale: not installed (manual: install Tailscale, then: sudo tailscale up)'
            ;;
        unauth)
            ra_warn 'tailscale: not authenticated - manual action required: authenticate (run: sudo tailscale up, then log in)'
            ;;
        ok)
            name="$(ra_json_str "$RA_TS_JSON" CurrentTailnet.Name 'unknown tailnet')"
            address="$(ra_json_str "$RA_TS_JSON" Self.TailscaleIPs.0 'none')"
            ra_ok "tailscale: connected (tailnet: ${name}, address: ${address})"
            ;;
    esac
    return 0
}

ra_status_ssh() {
    printf 'SSH:\n'
    local out
    case "$(ra_os)" in
        Darwin)
            if [ "$(ra_cfg macos.ssh false)" != "true" ]; then
                ra_warn 'ssh: not configured for this host (macos.ssh)'
                return 0
            fi
            # Check-only: enabling Remote Login stays a manual step.
            out="$(systemsetup -getremotelogin 2>/dev/null)" || out=""
            case "$out" in
                *"Remote Login: On"*)  ra_ok 'ssh: Remote Login on' ;;
                *"Remote Login: Off"*) ra_fail 'ssh: Remote Login off (manual: System Settings > General > Sharing > Remote Login)' ;;
                *)                     ra_warn 'ssh: Remote Login state unavailable (check manually: systemsetup -getremotelogin)' ;;
            esac
            ;;
        *)
            if [ "$(ra_cfg linux.ssh false)" != "true" ]; then
                ra_warn 'ssh: not configured for this host (linux.ssh)'
                return 0
            fi
            if ! command -v systemctl >/dev/null 2>&1; then
                ra_warn 'ssh: systemctl unavailable - sshd state unknown'
                return 0
            fi
            if [ "$(systemctl is-active ssh 2>/dev/null || true)" = "active" ]; then
                ra_ok 'ssh: sshd active'
            else
                ra_fail 'ssh: sshd not active (fix: systemctl enable --now ssh)'
            fi
            ;;
    esac
    return 0
}

ra_status_rdp() {
    printf 'RDP:\n'
    case "$(ra_os)" in
        Darwin)
            if [ "$(ra_cfg macos.screen_sharing false)" != "true" ]; then
                ra_warn 'rdp: not configured for this host (macos.screen_sharing)'
                return 0
            fi
            if ra_tcp_probe 127.0.0.1 5900; then
                ra_ok 'rdp: Screen Sharing listening on :5900 (recovery path)'
            else
                ra_warn 'rdp: Screen Sharing not active (manual: System Settings > General > Sharing > Screen Sharing)'
            fi
            ;;
        *)
            if [ "$(ra_cfg linux.rdp false)" != "true" ]; then
                ra_warn 'rdp: not configured for this host (linux.rdp)'
                return 0
            fi
            if ra_in_wsl; then
                ra_warn 'rdp: not applicable inside WSL'
                return 0
            fi
            local state=""
            if command -v systemctl >/dev/null 2>&1; then
                state="$(systemctl is-active xrdp 2>/dev/null || true)"
            fi
            case "$state" in
                active)   ra_ok 'rdp: xrdp active' ;;
                inactive) ra_fail 'rdp: xrdp not active (fix: systemctl enable --now xrdp)' ;;
                *)        ra_warn 'rdp: xrdp not resolved yet (desktop environment detection runs during setup)' ;;
            esac
            ;;
    esac
    return 0
}

ra_status_serve() {
    printf 'Tailscale Serve:\n'
    local out
    ra_tailscale_state
    case "$RA_TS_STATE" in
        absent)
            ra_warn 'serve: skipped (tailscale not installed)'
            return 0
            ;;
        unauth)
            ra_warn 'serve: skipped (tailscale not authenticated)'
            return 0
            ;;
    esac
    if ! out="$(tailscale serve status 2>/dev/null)"; then
        ra_warn 'serve: status unavailable'
        return 0
    fi
    case "$out" in
        "" | *"No serve configuration"*)
            ra_warn 'serve: none active (dot remote setup re-applies the configured mappings)'
            ;;
        *)
            ra_ok 'serve: active mappings'
            printf '%s\n' "$out" | sed 's/^/  /'
            ;;
    esac
    return 0
}

ra_status_cloudflare() {
    printf 'Cloudflare:\n'
    if ! command -v cloudflared >/dev/null 2>&1; then
        ra_warn 'cloudflared: not installed'
        return 0
    fi
    local cfg="${HOME}/.cloudflared/config.yml"
    if [ ! -f "$cfg" ]; then
        ra_warn "cloudflared: no local tunnel config at ${cfg} (dot remote tunnel render writes it)"
        return 0
    fi
    # Validate quietly: cloudflared's errors can echo config lines, and the
    # doctor never prints configuration content.
    if cloudflared tunnel ingress validate --config "$cfg" >/dev/null 2>&1; then
        ra_ok "cloudflared: tunnel config valid (${cfg})"
    else
        ra_fail "cloudflared: tunnel config invalid (${cfg}) (fix: dot remote tunnel render)"
    fi
    return 0
}

ra_status_services() {
    printf 'Applications:\n'
    local names name host port svc_env
    names="$(ra_cfg_keys services)"
    if [ -z "$names" ]; then
        ra_warn 'applications: none configured'
        return 0
    fi
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ "$(ra_cfg "services.${name}.enabled" false)" != "true" ]; then
            ra_warn "${name}: disabled"
            continue
        fi
        host="$(ra_cfg "services.${name}.host" "127.0.0.1")"
        port="$(ra_cfg "services.${name}.port" "")"
        svc_env="$(ra_cfg "services.${name}.environment" "unknown")"
        if [ "$host" != "127.0.0.1" ]; then
            ra_fail "${name}: target ${host}:${port} is not loopback (fix: bind the app to 127.0.0.1)"
            continue
        fi
        if [ -z "$port" ]; then
            ra_warn "${name}: no port configured (${svc_env})"
            continue
        fi
        if ! command -v timeout >/dev/null 2>&1; then
            ra_warn "${name}: port check skipped, timeout unavailable (127.0.0.1:${port}, ${svc_env})"
            continue
        fi
        if ra_tcp_probe "$host" "$port"; then
            ra_ok "${name}: listening on 127.0.0.1:${port} (${svc_env})"
        else
            ra_fail "${name}: not listening on 127.0.0.1:${port} (${svc_env}; start the app or fix its bind)"
        fi
    done <<EOF
$names
EOF
    return 0
}

ra_status_tmux() {
    printf 'tmux:\n'
    # RA_TMUX_BIN overrides the resolved binary: a host-installed tmux
    # cannot be un-installed, so tests pin the absent branch through an
    # unresolvable name instead of PATH games.
    local tmux_bin="${RA_TMUX_BIN:-tmux}" out
    if ! command -v "$tmux_bin" >/dev/null 2>&1; then
        ra_warn 'tmux: not installed (session persistence unavailable here)'
        return 0
    fi
    if ! out="$("$tmux_bin" ls 2>/dev/null)"; then
        ra_warn 'tmux: no active sessions'
        return 0
    fi
    ra_ok 'tmux: active sessions'
    printf '%s\n' "$out" | sed 's/^/  /'
    return 0
}

# Sections run best-effort: a probe failing inside one section degrades that
# section, never the doctor (exit 0 always).
ra_status_section() {
    "$@" || ra_fail "section probe failed: ${1#ra_status_}"
}

cmd_status() {
    # Read-only doctor; with [data.remote_access] absent or disabled there
    # is nothing to doctor.
    local enabled
    enabled="$(ra_cfg enabled false)"
    if [ "$enabled" != "true" ]; then
        printf 'not configured\n'
        return 0
    fi
    ra_status_section ra_status_tailscale
    ra_status_section ra_status_ssh
    ra_status_section ra_status_rdp
    ra_status_section ra_status_serve
    ra_status_section ra_status_cloudflare
    ra_status_section ra_status_services
    ra_status_section ra_status_tmux
    return 0
}

# ---------------------------------------------------------------------------
# tunnel render/validate - the machine-local cloudflared config (spec §4).
# render writes $RA_TUNNEL_CONFIG (default $HOME/.cloudflared/config.yml)
# from [data.remote_access.tunnel]: one ingress entry per declared
# hostname/service pair, terminal http_status:404 always appended,
# credentials referenced by path only. validate line-scans an existing
# config: every http:// origin must be 127.0.0.1 and the last ingress entry
# must be http_status:404. Findings name the problem class only - the
# config's own lines are never echoed (credential material lives next door
# in ~/.cloudflared, and validate's output is not the place it leaks).
# ---------------------------------------------------------------------------

ra_tunnel_render() {
    local cfg="${RA_TUNNEL_CONFIG:-${HOME}/.cloudflared/config.yml}"
    local json id name hostname service ingress=""
    json="$(ra_data_json)"
    id="$(ra_json_str "$json" tunnel.id "")"
    [ -n "$id" ] || ra_die "tunnel render: no tunnel id under [data.remote_access.tunnel]"
    mkdir -p -- "${cfg%/*}"
    # ra_cfg_keys yields the ingress names sorted (jq `keys`), so repeated
    # renders are byte-identical for the same data.
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        hostname="$(ra_json_str "$json" "tunnel.ingress.${name}.hostname" "")"
        service="$(ra_json_str "$json" "tunnel.ingress.${name}.service" "")"
        [ -n "$hostname" ] || ra_die "tunnel render: ingress ${name} has no hostname"
        [ -n "$service" ] || ra_die "tunnel render: ingress ${name} has no service"
        ingress="${ingress}  - hostname: ${hostname}
    service: ${service}
"
    done <<EOF
$(ra_cfg_keys tunnel.ingress)
EOF
    cat >"$cfg" <<EOF
tunnel: ${id}
credentials-file: ${HOME}/.cloudflared/${id}.json

ingress:
${ingress}  - service: http_status:404
EOF
    printf 'tunnel config written: %s\n' "$cfg"
}

ra_tunnel_validate() {
    local cfg="${RA_TUNNEL_CONFIG:-${HOME}/.cloudflared/config.yml}"
    [ -f "$cfg" ] || ra_die "tunnel validate: no config at ${cfg}"
    local line origin last="" loopback=0 terminal=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *"service: http://"*)
                # Origin host check: everything between http:// and the
                # next : or / must be the loopback literal.
                origin="${line#*"service: http://"}"
                origin="${origin%%[:/]*}"
                [ "$origin" = "127.0.0.1" ] || loopback=$((loopback + 1))
                ;;
        esac
        case "$line" in
            *service:*) last="$line" ;;
        esac
    done <"$cfg"
    case "$last" in
        *"service: http_status:404"*) terminal=1 ;;
    esac
    [ "$loopback" -eq 0 ] ||
        ra_fail "tunnel validate: loopback - ${loopback} http:// origin(s) not on 127.0.0.1 (${cfg})"
    [ "$terminal" -eq 1 ] ||
        ra_fail "tunnel validate: http_status:404 - the last ingress entry must be service: http_status:404 (${cfg})"
    if [ "$loopback" -eq 0 ] && [ "$terminal" -eq 1 ]; then
        ra_ok "tunnel config valid (${cfg})"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# login keys (spec §5.1) - materialize + authorize, Unix arm. `setup` drives
# these per declared [[data.remote_access.login_keys]] entry; Tasks 10-11's
# ps1 twin inverts the same two names for the Windows host. Private key
# material is never printed: the commands' output names files and verdicts,
# never key contents. The confirm gate defaults to WARN-and-skip whenever
# nothing can answer a prompt - a non-interactive run never prompts and
# never creates keys.
# ---------------------------------------------------------------------------

# ra_login_key_materialize NAME GENERATE: ensure ~/.ssh/NAME exists per spec
# §5.1 - idempotent, only-if-missing, confirmation-gated. Both halves
# missing: confirm, then `ssh-keygen -t ed25519` (through the
# RA_CONFIRM_MATERIALIZE seam the passphrase is empty, `-N ''`, because no
# prompt can be answered there; a real interactive run omits -N and lets
# ssh-keygen ask). Only NAME.pub present: Pattern B - the public half was
# generated on the owning device and dropped here; inbound-only, use as-is,
# no generation, no missing-private-key complaint. GENERATE=false and no
# .pub yet: WARN to drop the public half. Either way the private half's
# mode is normalized to 600 and ~/.ssh to 700.
ra_login_key_materialize() {
    local name="$1" generate="${2:-true}"
    local priv="${HOME}/.ssh/${name}" pub="${HOME}/.ssh/${name}.pub" answer=""
    mkdir -p -- "${HOME}/.ssh"
    chmod 700 -- "${HOME}/.ssh"
    if [ -f "$priv" ]; then
        chmod 600 -- "$priv"
        ra_ok "login key ${name}: present"
        return 0
    fi
    if [ -f "$pub" ]; then
        ra_ok "login key ${name}: public half present, inbound-only (no private half here)"
        return 0
    fi
    if [ "$generate" != "true" ]; then
        ra_warn "login key ${name}: generate=false and no public half dropped yet - drop the public half into ${pub} to authorize it"
        return 0
    fi
    if [ -n "${RA_CONFIRM_MATERIALIZE:-}" ]; then
        ssh-keygen -t ed25519 -f "$priv" -N ''
    elif [ -n "${RA_NONINTERACTIVE:-}" ] || [ ! -t 0 ]; then
        ra_warn "login key ${name}: not created (non-interactive run - confirm the prompt on a TTY, or set RA_CONFIRM_MATERIALIZE=1)"
        return 0
    else
        printf 'create login key %s (passphrase prompt follows)? [y/N] ' "$name"
        read -r answer || answer=""
        case "$answer" in
            y | Y | yes | Yes | YES)
                ssh-keygen -t ed25519 -f "$priv"
                ;;
            *)
                ra_warn "login key ${name}: not created (declined)"
                return 0
                ;;
        esac
    fi
    chmod 600 -- "$priv"
    ra_ok "login key ${name}: created"
    return 0
}

# ra_authorized_keys_install NAME TARGET: authorize ~/.ssh/NAME.pub for
# TARGET - append-only into the local ~/.ssh/authorized_keys behind a
# `grep -Fxq` guard (never a duplicate, never a reorder, existing lines
# never touched), mode 600. `linux`/`macos` targets are this machine's
# local arm; `windows`/`wsl` are the Windows host's ps1 twin's installs
# (administrators_authorized_keys with its admins-only ACL, and the
# wsl.exe channel) and are skipped here with a line saying so.
ra_authorized_keys_install() {
    local name="$1" target="$2"
    local pub="${HOME}/.ssh/${name}.pub" ak="${HOME}/.ssh/authorized_keys" line
    case "$target" in
        linux | macos)
            ;;
        windows | wsl)
            ra_warn "login key ${name}: target ${target} is installed by the Windows arm (dot remote on the Windows host)"
            return 0
            ;;
        *)
            ra_warn "login key ${name}: unknown target ${target} - skipped"
            return 0
            ;;
    esac
    [ -f "$pub" ] || {
        ra_warn "login key ${name}: no public half at ${pub} - nothing to authorize into ${target}"
        return 0
    }
    line="$(cat "$pub")"
    mkdir -p -- "${HOME}/.ssh"
    [ -f "$ak" ] || : >"$ak"
    chmod 600 -- "$ak"
    if grep -Fxq -- "$line" "$ak"; then
        ra_ok "login key ${name}: already authorized (${target})"
        return 0
    fi
    printf '%s\n' "$line" >>"$ak"
    ra_ok "login key ${name}: authorized (${target})"
    return 0
}

# ---------------------------------------------------------------------------
# setup (spec §6) - idempotent configure, Unix arm. Prerequisites are
# checked, never installed (xrdp is the sanctioned exception, §11); an
# unauthenticated Tailscale prints the issue's ACTION REQUIRED block and
# stops only the Tailscale-dependent paths (Serve mappings, the
# tailnet-scoped firewall verification); every write verifies current state
# first, so an already-correct host is verified, not rewritten - a second
# run records no mutations and setup exits non-zero only on hard failure.
# ---------------------------------------------------------------------------

# ra_desktop_detected: the spec §6 signal chain for the xrdp decision. WSL
# exclusion first - the /proc/version microsoft fingerprint (RA_PROC_VERSION
# overrides it for tests, the same seam ra_in_wsl uses; an exported
# WSL_DISTRO_NAME is the other fingerprint) - then `systemctl get-default`
# returning graphical.target (servers default to multi-user.target), then
# the corroborating signals: a non-empty session directory or the
# display-manager unit alias. rc 0 = desktop present, 1 = server/WSL/none.
ra_desktop_detected() {
    local pv dir unit
    pv="${RA_PROC_VERSION:-}"
    if [ -z "$pv" ]; then
        if [ -n "${WSL_DISTRO_NAME:-}" ]; then
            return 1
        fi
        if [ -r /proc/version ]; then
            pv="$(cat /proc/version 2>/dev/null)" || pv=""
        fi
    fi
    case "$pv" in
        *microsoft* | *Microsoft*) return 1 ;;
    esac
    if command -v systemctl >/dev/null 2>&1; then
        [ "$(systemctl get-default 2>/dev/null || true)" = "graphical.target" ] && return 0
    fi
    for dir in /usr/share/xsessions /usr/share/wayland-sessions; do
        [ -d "$dir" ] || continue
        set -- "$dir"/*
        [ -e "$1" ] && return 0
    done
    for unit in \
        /etc/systemd/system/display-manager.service \
        /lib/systemd/system/display-manager.service \
        /usr/lib/systemd/system/display-manager.service; do
        [ -e "$unit" ] && return 0
    done
    return 1
}

# ra_serve_apply: one Tailscale Serve mapping per configured service with
# tailscale = true (spec §6: path-scoped per instance, targets stay
# loopback). Idempotent: `tailscale serve status` is read first and a
# service whose target is already mapped is verified, not rewritten. A
# non-loopback configured host is refused, never served. The caller gates
# this on ra_tailscale_state = ok.
ra_serve_apply() {
    local json name host port target status
    json="$(ra_data_json)"
    status="$(tailscale serve status 2>/dev/null)" || status=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$(ra_json_str "$json" "services.${name}.tailscale" false)" = "true" ] || continue
        host="$(ra_json_str "$json" "services.${name}.host" "127.0.0.1")"
        port="$(ra_json_str "$json" "services.${name}.port" "")"
        if [ "$host" != "127.0.0.1" ]; then
            ra_fail "serve ${name}: target ${host}:${port} is not loopback - refused (fix the app's bind first)"
            continue
        fi
        if [ -z "$port" ]; then
            ra_warn "serve ${name}: no port configured - skipped"
            continue
        fi
        target="http://${host}:${port}"
        case "$status" in
            *"$target"*)
                ra_ok "serve ${name}: already mapped (${target})"
                ;;
            *)
                tailscale serve --bg --set-path "/${name}" "$target"
                ra_ok "serve ${name}: mapped /${name} to ${target}"
                ;;
        esac
    done <<EOF
$(ra_cfg_keys services)
EOF
    return 0
}

# ra_setup_linux: the spec §6 Linux arm - sshd enable + running, the
# tailnet-scoped firewall verification (authenticated gate only, see
# ra_firewall_check), then the desktop-gated xrdp path. linux.ssh /
# linux.rdp guard their branches so a host that did not declare them is
# not touched.
ra_setup_linux() {
    if [ "$(ra_cfg linux.ssh false)" = "true" ]; then
        if ! command -v systemctl >/dev/null 2>&1; then
            ra_warn 'ssh: systemctl unavailable - enable sshd manually (sudo systemctl enable --now ssh)'
        elif [ "$(systemctl is-active ssh 2>/dev/null || true)" = "active" ]; then
            ra_ok 'ssh: sshd already active'
        else
            systemctl enable --now ssh
            ra_ok 'ssh: sshd enabled and started'
        fi
    fi
    if [ "$RA_TS_STATE" = "ok" ]; then
        ra_firewall_check
    fi
    ra_setup_linux_rdp
    return 0
}

# ra_setup_linux_rdp: xrdp is the sanctioned setup-time install (spec §11)
# - only on a detected desktop with linux.rdp declared. Detection failure
# reports the server verdict and changes nothing; inside WSL it is not
# applicable. The install goes through RA_PKG_MGR (default apt-get) so
# hosts with another package manager - and the tests - can pin the
# command; an already-resolving xrdp skips straight to the state check.
ra_setup_linux_rdp() {
    [ "$(ra_cfg linux.rdp false)" = "true" ] || return 0
    if ra_in_wsl; then
        ra_warn 'rdp: not applicable inside WSL'
        return 0
    fi
    if ! ra_desktop_detected; then
        ra_warn 'rdp: server, no GUI - RDP not applicable (nothing changed)'
        return 0
    fi
    local pkg="${RA_PKG_MGR:-apt-get}"
    if ! command -v xrdp >/dev/null 2>&1; then
        "$pkg" install -y xrdp
    else
        ra_ok 'rdp: xrdp already installed'
    fi
    if [ "$(systemctl is-active xrdp 2>/dev/null || true)" = "active" ]; then
        ra_ok 'rdp: xrdp already active'
    else
        systemctl enable --now xrdp
        ra_ok 'rdp: xrdp enabled and started'
    fi
    return 0
}

# ra_setup_darwin: the spec §6 macOS arm - verify Remote Login and Screen
# Sharing state only; enabling stays manual, so this arm never issues a
# write (the tests' strict systemsetup stub fails any call beyond
# -getremotelogin).
ra_setup_darwin() {
    local out
    if [ "$(ra_cfg macos.ssh false)" = "true" ]; then
        out="$(systemsetup -getremotelogin 2>/dev/null)" || out=""
        case "$out" in
            *"Remote Login: On"*)  ra_ok 'ssh: Remote Login on' ;;
            *"Remote Login: Off"*) ra_fail 'ssh: Remote Login off (manual: System Settings > General > Sharing > Remote Login)' ;;
            *)                     ra_warn 'ssh: Remote Login state unavailable (check manually: systemsetup -getremotelogin)' ;;
        esac
    fi
    if [ "$(ra_cfg macos.screen_sharing false)" = "true" ]; then
        if ra_tcp_probe 127.0.0.1 5900; then
            ra_ok 'rdp: Screen Sharing listening on :5900 (recovery path)'
        else
            ra_warn 'rdp: Screen Sharing not active (manual: System Settings > General > Sharing > Screen Sharing)'
        fi
    fi
    return 0
}

# ra_setup_login_keys: drive ra_login_key_materialize +
# ra_authorized_keys_install per declared
# [[data.remote_access.login_keys]] entry (spec §5.1). login_keys is an
# array, so the walk is index-based through ra_json_str - the resolver
# that understands numeric segments in both jq and python3 - and the
# first missing .name ends it. Note the resolver's `//` semantics: an
# explicit generate=false collapses to the default, so declare generate
# explicitly and keep it true on this arm (Pattern B is expressed by
# dropping the .pub, which materialize handles either way).
ra_setup_login_keys() {
    local json i=0 t target name generate
    json="$(ra_data_json)"
    while :; do
        name="$(ra_json_str "$json" "login_keys.${i}.name" "")"
        [ -n "$name" ] || break
        generate="$(ra_json_str "$json" "login_keys.${i}.generate" "true")"
        ra_login_key_materialize "$name" "$generate"
        t=0
        while :; do
            target="$(ra_json_str "$json" "login_keys.${i}.targets.${t}" "")"
            [ -n "$target" ] || break
            ra_authorized_keys_install "$name" "$target"
            t=$((t + 1))
        done
        i=$((i + 1))
    done
    return 0
}

# ra_firewall_check: tailnet-scoped firewall verification, check-only -
# spec §6 lists it among the Tailscale-dependent paths, so it runs only
# behind the authenticated gate, and it never mutates: rule writes stay a
# manual action on Unix (the Windows arm's twin owns its rule writes).
ra_firewall_check() {
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q 'tailscale0'; then
            ra_ok 'firewall: ufw carries a tailscale0 rule'
        else
            ra_warn 'firewall: no tailscale0 rule in ufw (manual: sudo ufw allow in on tailscale0)'
        fi
    elif command -v nft >/dev/null 2>&1; then
        ra_warn 'firewall: nftables present - verify the tailnet scope manually (dot remote does not mutate nftables)'
    fi
    return 0
}

# ra_setup_cloudflared_check: prerequisites are checked, never installed -
# cloudflared's presence is reported with its manual action; service
# registration stays a printed elevated manual step (spec §6).
ra_setup_cloudflared_check() {
    if command -v cloudflared >/dev/null 2>&1; then
        ra_ok 'cloudflared: present (service registration stays manual: sudo cloudflared service install)'
    else
        ra_warn 'cloudflared: not installed (manual: install cloudflared before using the browser path)'
    fi
    return 0
}

cmd_setup() {
    local enabled
    enabled="$(ra_cfg enabled false)"
    if [ "$enabled" != "true" ]; then
        printf 'not configured\n'
        return 0
    fi
    # Prerequisite + gate first: RA_TS_STATE is what every later step
    # branches on.
    ra_tailscale_state
    case "$RA_TS_STATE" in
        ok)
            ra_ok 'tailscale: connected'
            ;;
        unauth)
            ra_warn 'tailscale: not authenticated'
            printf '%s\n' 'ACTION REQUIRED:'
            printf '%s\n' 'Authenticate this host with Tailscale, then rerun:'
            printf '%s\n' '    dot remote setup'
            ;;
        absent)
            ra_warn 'tailscale: not installed (manual: install Tailscale, then: sudo tailscale up)'
            ;;
    esac
    # Platform transport writes - independent of Tailscale, run either way.
    case "$(ra_os)" in
        Darwin) ra_setup_darwin ;;
        *)      ra_setup_linux ;;
    esac
    ra_setup_login_keys
    # Tailscale-dependent path: serve mappings are held unless the backend
    # is authenticated (the firewall verification gates inside the Linux
    # arm on the same state).
    if [ "$RA_TS_STATE" = "ok" ]; then
        ra_serve_apply
    else
        ra_warn "serve: skipped while tailscale is ${RA_TS_STATE} (dependent paths held)"
    fi
    # Tunnel render + service check (machine-local, auth-independent);
    # render only where a tunnel id is actually configured.
    if [ -n "$(ra_cfg tunnel.id "")" ]; then
        ra_tunnel_render
    fi
    ra_setup_cloudflared_check
    printf '%s\n' 'next: verify key login from another device, then run: dot remote harden-ssh'
    return 0
}

main() {
    local cmd="${1:-}"
    [ $# -gt 0 ] && shift
    # ${1+"$@"}, not "$@": under set -u, bash 3.2 (macOS /bin/bash, which the
    # header claims to run on) raises "unbound variable" for an empty "$@" -
    # i.e. every argless path (bare invocation, a handler after shift).
    case "$cmd" in
        setup)         cmd_setup ${1+"$@"} ;;
        status)        cmd_status ${1+"$@"} ;;
        fix)           cmd_fix ${1+"$@"} ;;
        harden-ssh)    cmd_harden_ssh ${1+"$@"} ;;
        wsl-reconcile) cmd_wsl_reconcile ${1+"$@"} ;;
        tunnel)
            case "${1:-}" in
                render)  shift; cmd_tunnel_render ${1+"$@"} ;;
                validate) shift; cmd_tunnel_validate ${1+"$@"} ;;
                *) ra_usage >&2; exit 2 ;;
            esac
            ;;
        *) ra_usage >&2; exit 2 ;;
    esac
}

# RA_NO_MAIN=1 keeps dispatch off: tests source this file and drive the
# ra_* helpers function-level (the ps1 twin's REMOTE_ACCESS_NO_MAIN=1
# mirror). Every direct caller goes through main() below.
[ -n "${RA_NO_MAIN:-}" ] || main ${1+"$@"}
