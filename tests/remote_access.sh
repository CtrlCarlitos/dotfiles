#!/usr/bin/env bash
set -euo pipefail

# remote_access contract: the `dot remote` Unix twin skeleton and its
# `status` doctor. The dispatch table resolves every subcommand the spec
# names; an unknown one prints usage and exits 2; `wsl-reconcile` is a
# Windows-only arm and says so on Unix; `status` degrades to `not configured`
# when [data.remote_access] is absent, and on a configured host prints the
# spec §7 sections in order (Tailscale, SSH, RDP, Tailscale Serve,
# Cloudflare, Applications, tmux) with ✓/○/✗ markers - unauthenticated
# Tailscale warns and names `authenticate`, a non-loopback service target
# FAILs, a missing tmux degrades to one ○ line, and the doctor exits 0 in
# every case without ever printing token-shaped material. Config reaches the
# twin through a stub `chezmoi` on PATH whose `data --format json` cats a
# fixture - the same harness (ra_stub/ra_run) every later remote_access task
# reuses. `tunnel render` writes the machine-local cloudflared config.yml
# from the fixture data (tunnel id, credentials referenced by path only,
# every declared hostname→service pair, terminal `http_status:404` always
# appended, byte-identical re-render) to the `$HOME/.cloudflared/config.yml`
# default, and `tunnel validate` exits 0/1 with named findings (`loopback`,
# `http_status:404`) that never echo the file's own lines -
# `RA_TUNNEL_CONFIG` pins the file under test where the default is not it.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/remote-access-XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/home"

# ra_stub DIR NAME BODY: write NAME into DIR as an executable stub whose
# script is BODY. The body lands in a heredoc, so callers escape \$ for
# anything that must expand at stub runtime, and quote paths that must
# expand at stub-build time.
ra_stub() {
    local dir="$1" name="$2" body="$3"
    mkdir -p "$dir"
    cat >"$dir/$name" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
    chmod +x "$dir/$name"
}

# ra_run ARGS...: execute the twin with the stub bin first on PATH and a
# scratch HOME - no host chezmoi, no host config can leak in.
ra_run() (
    # shellcheck disable=SC2030  # the subshell is the isolation: HOST PATH
    # and HOME must not leak back into the test process
    export PATH="$scratch/bin:$PATH"
    export HOME="$scratch/home"
    exec bash "$repo_root/scripts/remote-access.sh" "$@"
)

# The stub `chezmoi`: `data --format json` cats the fixture, exactly what
# the real command emits for a machine whose data has no remote_access key.
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/off.json' ;;
esac"

# ra_section_line OUT PREFIX: line number of the first line of OUT starting
# with PREFIX (0 when absent) - how the section-order assertion works.
ra_section_line() {
    local n
    n="$(printf '%s\n' "$1" | grep -n "^$2" | sed -n '1{s/:.*//;p;}')" || n=""
    [ -n "$n" ] || n=0
    printf '%s' "$n"
}

# 1. Unknown subcommand: usage, exit 2.
rc=0
out="$(ra_run definitely-not-a-subcommand 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "unknown subcommand must exit 2 (got $rc)"
printf '%s' "$out" | grep -Fq 'usage:' ||
    fail "unknown subcommand must print usage (got: $out)"
pass

# 2. wsl-reconcile on Unix: the not-applicable line, exit 0.
rc=0
out="$(ra_run wsl-reconcile 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "wsl-reconcile must exit 0 on Unix (got $rc)"
printf '%s' "$out" | grep -Fq 'not applicable on this platform - run on the Windows host' ||
    fail "wsl-reconcile must print the not-applicable line (got: $out)"
pass

# 3. status with [data.remote_access] absent (off.json): not configured, exit 0.
#    After the dispatcher's shift this is an argless handler call - the
#    empty-argv path that bash 3.2's set -u mishandles as plain "$@".
rc=0
out="$(ra_run status 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "status must exit 0 when not configured (got $rc)"
printf '%s' "$out" | grep -Fq 'not configured' ||
    fail "status must print 'not configured' (got: $out)"
pass

# 4. Bare invocation (zero args): usage, exit 2 - exercised directly, since
#    ra_run always passes at least one argument.
rc=0
# shellcheck disable=SC2031  # same isolation as ra_run: the env-prefix is
# the point, nothing is meant to leak out of the command substitution
out="$(PATH="$scratch/bin:$PATH" HOME="$scratch/home" \
    bash "$repo_root/scripts/remote-access.sh" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "bare invocation must exit 2 (got $rc)"
printf '%s' "$out" | grep -Fq 'usage:' ||
    fail "bare invocation must print usage (got: $out)"
pass

# 5. status on a fully-stubbed healthy Linux host: the seven spec §7
#    sections in order, ✓ lines that reflect the stubs (including a live
#    loopback listener on the configured port), exit 0, no token-shaped
#    material anywhere in the output. RA_PROC_VERSION pins the non-WSL side
#    of the RDP branch (in WSL /proc/version says microsoft).
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/full-linux.json' ;;
esac"
ra_stub "$scratch/bin" tailscale "case \"\$1 \${2:-}\" in
    \"status --json\") printf '%s\n' '{\"BackendState\": \"Running\", \"CurrentTailnet\": {\"Name\": \"example.net\"}, \"Self\": {\"TailscaleIPs\": [\"100.64.0.1\"]}}' ;;
    \"serve status\") printf '%s\n' 'https://machine.example.net:443 path / --> http://127.0.0.1:4098' ;;
esac"
ra_stub "$scratch/bin" systemctl "case \"\$1 \${2:-}\" in
    \"is-active ssh\" | \"is-active xrdp\") printf 'active\n' ;;
    *) printf 'inactive\n'; exit 3 ;;
esac"
ra_stub "$scratch/bin" cloudflared "exit 0"
ra_stub "$scratch/bin" tmux "case \"\$1\" in
    ls) printf 'main: 1 windows (created Sun Sep 27 10:00:00 2026)\n' ;;
esac"
mkdir -p "$scratch/home/.cloudflared"
printf 'tunnel: 00000000-0000-0000-0000-000000000000\n' >"$scratch/home/.cloudflared/config.yml"
python3 -m http.server 4098 --bind 127.0.0.1 >/dev/null 2>&1 &
srv_pid=$!
srv_ready=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if (exec 3<>/dev/tcp/127.0.0.1/4098) 2>/dev/null; then
        srv_ready=1
        break
    fi
    sleep 0.2
done
[ -n "$srv_ready" ] || fail "test listener on 127.0.0.1:4098 never came up"
export RA_PROC_VERSION="Linux version 6.8.0-generic"
rc=0
out="$(ra_run status 2>&1)" || rc=$?
unset RA_PROC_VERSION
kill "$srv_pid" 2>/dev/null || true
wait "$srv_pid" 2>/dev/null || true
[ "$rc" -eq 0 ] || fail "status must exit 0 on a healthy host (got $rc)"
for section in 'Tailscale:' 'SSH:' 'RDP:' 'Tailscale Serve:' 'Cloudflare:' 'Applications:' 'tmux:'; do
    printf '%s' "$out" | grep -Fq "$section" ||
        fail "status must print a $section section (got: $out)"
done
line_tailscale="$(ra_section_line "$out" 'Tailscale:')"
line_ssh="$(ra_section_line "$out" 'SSH:')"
line_rdp="$(ra_section_line "$out" 'RDP:')"
line_serve="$(ra_section_line "$out" 'Tailscale Serve:')"
line_cloudflare="$(ra_section_line "$out" 'Cloudflare:')"
line_apps="$(ra_section_line "$out" 'Applications:')"
line_tmux="$(ra_section_line "$out" 'tmux:')"
if [ "$line_tailscale" -lt "$line_ssh" ] && [ "$line_ssh" -lt "$line_rdp" ] \
    && [ "$line_rdp" -lt "$line_serve" ] && [ "$line_serve" -lt "$line_cloudflare" ] \
    && [ "$line_cloudflare" -lt "$line_apps" ] && [ "$line_apps" -lt "$line_tmux" ]; then
    :
else
    fail "status sections must appear in spec §7 order (got: $out)"
fi
printf '%s' "$out" | grep -Fq '✓ tailscale: connected (tailnet: example.net, address: 100.64.0.1)' ||
    fail "tailscale section must report the connected state (got: $out)"
printf '%s' "$out" | grep -Fq '✓ ssh: sshd active' ||
    fail "ssh section must report the stubbed sshd state (got: $out)"
printf '%s' "$out" | grep -Fq '✓ rdp: xrdp active' ||
    fail "rdp section must report the stubbed xrdp state (got: $out)"
printf '%s' "$out" | grep -Fq '✓ serve: active mappings' ||
    fail "serve section must report the stubbed mappings (got: $out)"
printf '%s' "$out" | grep -Fq 'http://127.0.0.1:4098' ||
    fail "serve section must pass through the mapping target (got: $out)"
printf '%s' "$out" | grep -Fq '✓ cloudflared: tunnel config valid' ||
    fail "cloudflare section must validate the existing config (got: $out)"
printf '%s' "$out" | grep -Fq '✓ opencode_linux: listening on 127.0.0.1:4098 (linux)' ||
    fail "applications section must report the listening service (got: $out)"
printf '%s' "$out" | grep -Fq '✓ tmux: active sessions' ||
    fail "tmux section must report the stubbed session (got: $out)"
if printf '%s' "$out" | grep -Eq 'ey[A-Za-z0-9_-]{20,}'; then
    fail "status output must never contain token-shaped material (got: $out)"
fi
pass

# 6. Unauthenticated Tailscale: a WARN line naming the manual action
#    (authenticate), and the doctor still exits 0 - never a crash.
ra_stub "$scratch/bin" tailscale "case \"\$1 \${2:-}\" in
    \"status --json\") printf '%s\n' '{\"BackendState\": \"NeedsLogin\"}' ;;
esac"
rc=0
out="$(ra_run status 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "status must exit 0 with unauthenticated tailscale (got $rc)"
printf '%s' "$out" | grep -Fq '○ tailscale: not authenticated' ||
    fail "unauth tailscale must print the WARN line (got: $out)"
printf '%s' "$out" | grep -Fq 'authenticate' ||
    fail "the unauth WARN must name the manual action: authenticate (got: $out)"
pass

# 7. A service whose configured target host is not 127.0.0.1: a ✗ FAIL line
#    mentioning loopback, exit still 0 (report, not crash).
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/nonloopback-service.json' ;;
esac"
rc=0
out="$(ra_run status 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "status must exit 0 even with a non-loopback service (got $rc)"
printf '%s' "$out" | grep -Fq '✗ opencode_linux: target 0.0.0.0:4098 is not loopback' ||
    fail "a non-loopback target must FAIL with a loopback mention (got: $out)"
pass

# 8. macOS (full-mac.json, uname stubbed to Darwin): the SSH section reports
#    Remote Login check-only - the systemsetup stub is strict, so any
#    enabling call would surface as an unexpected-invocation error.
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/full-mac.json' ;;
esac"
ra_stub "$scratch/bin" uname "printf 'Darwin\n'"
ra_stub "$scratch/bin" systemsetup "if [ \"\$1\" = '-getremotelogin' ]; then
    printf 'Remote Login: On\n'
else
    printf 'unexpected systemsetup call: \$*\n' >&2
    exit 1
fi"
rc=0
out="$(ra_run status 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "status must exit 0 on the darwin arm (got $rc)"
printf '%s' "$out" | grep -Fq '✓ ssh: Remote Login on' ||
    fail "the darwin ssh section must report Remote Login state (got: $out)"
if printf '%s' "$out" | grep -Fq 'unexpected systemsetup call'; then
    fail "darwin status must stay check-only (no systemsetup writes)"
fi
pass

# 9. tmux binary unresolved: exactly one ○ line in the tmux section, exit
#    still 0. RA_TMUX_BIN pins the absent branch: a host-installed tmux
#    cannot be un-installed, and hiding it via PATH would hide bash too.
rm -f "$scratch/bin/tmux"
export RA_TMUX_BIN="tmux-no-such-binary"
rc=0
out="$(ra_run status 2>&1)" || rc=$?
unset RA_TMUX_BIN
[ "$rc" -eq 0 ] || fail "status must exit 0 with tmux unresolved (got $rc)"
tmux_warn_lines="$(printf '%s\n' "$out" | grep -c '^○ tmux' || true)"
[ "$tmux_warn_lines" -eq 1 ] ||
    fail "the tmux section must print exactly one ○ line when tmux is absent (got: $out)"
if printf '%s' "$out" | grep -Fq '✓ tmux'; then
    fail "the tmux section must not claim success when tmux is unresolved"
fi
pass

# ---------------------------------------------------------------------------
# 10-14. tunnel render/validate (spec §4). render writes the machine-local
# cloudflared config.yml from [data.remote_access.tunnel]: tunnel id,
# credentials referenced by path only, one ingress entry per declared
# hostname/service pair, terminal http_status:404 ALWAYS appended. validate
# line-scans a config: every http:// origin must be 127.0.0.1 and the last
# ingress entry must be the terminal 404; findings name the problem class
# and never echo the config's lines. RA_TUNNEL_CONFIG overrides the output
# path ($HOME/.cloudflared/config.yml by default) for the hand-written
# fixtures below.
# ---------------------------------------------------------------------------

# 10. render from tunnel-full.json onto the default path: id, credentials
#     path under .cloudflared/, every declared pair, terminal 404 last, and
#     a second render is byte-identical.
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/tunnel-full.json' ;;
esac"
cfg="$scratch/home/.cloudflared/config.yml"
rc=0
out="$(ra_run tunnel render 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "tunnel render must exit 0 (got $rc)"
if [ -f "$cfg" ]; then
    require "$cfg" 'tunnel: 6ff42ae2-765d-4adf-8684-a115a1b92d95'
    require "$cfg" "credentials-file: $scratch/home/.cloudflared/6ff42ae2-765d-4adf-8684-a115a1b92d95.json"
    require "$cfg" '  - hostname: opencode.example.com'
    require "$cfg" '    service: http://127.0.0.1:4096'
    require "$cfg" '  - hostname: ssh.example.com'
    require "$cfg" '    service: ssh://127.0.0.1:22'
    require "$cfg" '  - hostname: wsl.example.com'
    require "$cfg" '    service: ssh://127.0.0.1:2222'
    last_service="$(grep 'service:' "$cfg" | tail -n 1 || true)"
    [ "$last_service" = '  - service: http_status:404' ] ||
        fail "the final ingress entry must be the terminal 404 (got: $last_service)"
    cp "$cfg" "$cfg.first"
    rc=0
    out="$(ra_run tunnel render 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] || fail "the second render must exit 0 (got $rc)"
    if cmp -s "$cfg" "$cfg.first"; then
        :
    else
        fail "a second render must be byte-identical"
    fi
else
    fail "tunnel render must write the default ${cfg}"
fi
pass

# 11. validate on the rendered config: exit 0, verdict line.
rc=0
out="$(ra_run tunnel validate 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "tunnel validate must exit 0 on the rendered config (got $rc)"
printf '%s' "$out" | grep -Fq 'tunnel config valid' ||
    fail "tunnel validate must print its verdict (got: $out)"
pass

# 12. validate on a hand-written config whose http origin is 0.0.0.0:
#     exit 1, the finding names loopback.
printf '%s\n' \
    'tunnel: 6ff42ae2-765d-4adf-8684-a115a1b92d95' \
    'credentials-file: /home/operator/.cloudflared/6ff42ae2-765d-4adf-8684-a115a1b92d95.json' \
    'ingress:' \
    '  - hostname: opencode.example.com' \
    '    service: http://0.0.0.0:4096' \
    '  - service: http_status:404' >"$scratch/home/.cloudflared/loopback.yml"
rc=0
out="$(RA_TUNNEL_CONFIG="$scratch/home/.cloudflared/loopback.yml" ra_run tunnel validate 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "tunnel validate must exit 1 on a non-loopback origin (got $rc)"
printf '%s' "$out" | grep -Fq 'loopback' ||
    fail "the loopback finding must be named (got: $out)"
pass

# 13. validate on the rendered config minus its terminal 404 entry:
#     exit 1, the finding names http_status:404.
if [ -f "$cfg" ]; then
    grep -v 'http_status:404' "$cfg" >"$scratch/home/.cloudflared/no-final-404.yml"
    rc=0
    out="$(RA_TUNNEL_CONFIG="$scratch/home/.cloudflared/no-final-404.yml" ra_run tunnel validate 2>&1)" || rc=$?
    [ "$rc" -eq 1 ] || fail "tunnel validate must exit 1 without the terminal 404 (got $rc)"
    printf '%s' "$out" | grep -Fq 'http_status:404' ||
        fail "the terminal-404 finding must be named (got: $out)"
else
    fail "test 13 needs test 10's rendered config"
fi
pass

# 14. validate on a structurally valid config whose credentials-file line
#     carries an inline token-shaped string: still exits 0, and the output
#     never echoes it.
printf '%s\n' \
    'tunnel: 6ff42ae2-765d-4adf-8684-a115a1b92d95' \
    'credentials-file: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.inline-token-material' \
    'ingress:' \
    '  - hostname: opencode.example.com' \
    '    service: http://127.0.0.1:4096' \
    '  - service: http_status:404' >"$scratch/home/.cloudflared/inline-token.yml"
rc=0
out="$(RA_TUNNEL_CONFIG="$scratch/home/.cloudflared/inline-token.yml" ra_run tunnel validate 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "a token-shaped credentials-file must still validate structurally (got $rc)"
if printf '%s' "$out" | grep -Eq 'ey[A-Za-z0-9_-]{20,}'; then
    fail "tunnel validate output must never echo token material (got: $out)"
fi
pass

finish
