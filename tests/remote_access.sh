#!/usr/bin/env bash
# Fixture wrappers isolate RA_SSHD_CONFIG; later tests deliberately replace it.
# shellcheck disable=SC2031
# Transport fixtures; the shared key engine has its own executed test suite.
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
# Login keys (spec §5.1) run function-level: `ra_call` sources the twin into
# a subshell with `RA_NO_MAIN=1` (the seam that keeps its dispatch off, the
# ps1 twin's `REMOTE_ACCESS_NO_MAIN=1` mirror) and invokes a helper directly,
# because their driver, `setup`, is the next task's. materialize is
# idempotent, only-if-missing, confirmation-gated (RA_NONINTERACTIVE=1 warns
# `not created` and never calls ssh-keygen; the `RA_CONFIRM_MATERIALIZE=1`
# non-TTY seam records `ssh-keygen -t ed25519 -f ~/.ssh/<name> -N ''` - the
# empty passphrase exists only in the seam; only-a-.pub is pattern B:
# accepted as-is, authorized, no generation). authorize appends the .pub
# into the local `~/.ssh/authorized_keys` only (`grep -Fxq` dedup, existing
# lines never touched, mode 600) and skips `windows`/`wsl` targets with a
# line naming the Windows host - its ps1 twin installs those. `setup`
# (spec §6) orchestrates the whole surface per host: prerequisites are
# reported, never installed (xrdp through the RA_PKG_MGR seam is the
# sanctioned exception); an unauthenticated tailscale prints the verbatim
# ACTION REQUIRED block and holds only the dependent paths (serve, the
# tailnet-scoped firewall verification) while the sshd enable still runs;
# the Linux arm installs + enables xrdp only on a detected desktop
# (graphical.target; RA_PROC_VERSION pins the /proc/version WSL
# fingerprint, which no PATH stub can reach) and reports `server, no GUI`
# otherwise; every tailscale=true service gets exactly one path-scoped
# serve mapping with a 127.0.0.1 target; the declared login keys
# materialize + authorize; tunnel render runs; darwin stays check-only
# (`systemsetup -getremotelogin` state line, no enabling call).
# Idempotency is executed, not grepped: ra_run_twice runs setup twice
# against the recorded stubs - the stubs derive their state from the call
# log - and the second pass must record zero mutating calls. fix (spec §8)
# is repair-only: a stopped sshd gets exactly `systemctl restart ssh` plus
# the startup-mode restore, the cloudflared service restarts only when its
# unit exists and is not running (read-only list-unit-files probe), the
# wsl.enabled portproxy pointer names the Windows-host arm, a healthy host
# records zero mutating calls (the
# strict stubs fail anything beyond the read-only probes), an
# unauthenticated backend holds serve, and an unconfigured host is a
# `not configured` no-op. harden-ssh is guarded: without `--confirmed` or
# with zero keys in ~/.ssh/authorized_keys it refuses (exit 1, reason
# printed, sshd_config untouched); with both it rewrites the config at
# RA_SSHD_CONFIG (default /etc/ssh/sshd_config) to exactly one active
# `PasswordAuthentication no`, byte-identically on a second run, and
# records the sshd restart.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/remote-access-XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/home"
unset RA_SSHD_CONFIG
printf 'AuthorizedKeysFile .ssh/authorized_keys\n' > "$scratch/sshd_config.fixture"
printf '[data.remote_access.ssh]\nlogin_keys = []\n' > "$scratch/contract.toml"

# ra_stub DIR NAME BODY: write NAME into DIR as an executable stub whose
# script is BODY. The body lands in a heredoc, so callers escape \$ for
# anything that must expand at stub runtime, and quote paths that must
# expand at stub-build time.
ra_stub() {
    local dir="$1" name="$2" body="$3"
    local metadata=""
    if [ "$name" = chezmoi ]; then
        metadata="if [ \"\${1:-}\" = execute-template ]; then printf '%s\\n' '$scratch/contract.toml'; exit 0; fi"
    fi
    mkdir -p "$dir"
    cat >"$dir/$name" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${metadata}
${body}
EOF
    chmod +x "$dir/$name"
}

# ra_run ARGS...: execute the twin with the stub bin first on PATH and a
# scratch HOME - no host chezmoi, no host config can leak in.
# shellcheck disable=SC2030,SC2031  # the subshell is the isolation: PATH
# and HOME must not leak back into the test process
ra_run() (
    export PATH="$scratch/bin:$PATH"
    export HOME="$scratch/home"
    export RA_SSHD_CONFIG="${RA_SSHD_CONFIG:-$scratch/sshd_config.fixture}"
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

# ra_mode FILE: permission bits of FILE, portable across GNU stat (Linux,
# `stat -c %a`) and BSD stat (macOS, `stat -f %Lp`); "unknown" when neither
# stat can read it (a missing file must fail the mode assertion, not abort
# the run before finish).
ra_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || printf 'unknown'
}

# ra_call ARGS...: source the twin into a subshell (RA_NO_MAIN=1 keeps its
# main off - see the header) and invoke ARGS as a function call: how the
# login-key helpers are driven before `setup` wires them to a subcommand.
# shellcheck disable=SC2030,SC2031  # the subshell is the isolation: PATH,
# HOME and RA_NO_MAIN must not leak back into the test process
ra_call() (
    export PATH="$scratch/bin:$PATH"
    export HOME="$scratch/home"
    export RA_SSHD_CONFIG="${RA_SSHD_CONFIG:-$scratch/sshd_config.fixture}"
    export RA_NO_MAIN=1
    . "$repo_root/scripts/remote-access.sh"
    "$@"
)

# ra_run_twice ARGS...: run the twin twice against the recorded-stub set,
# snapshotting the mutating-call log between passes - the idempotency
# harness: the second pass must add zero lines. Outputs land in
# $scratch/twice-N.out, the counts in $scratch/twice-N.count.
# shellcheck disable=SC2030,SC2031  # the subshell is the isolation: PATH
# and HOME must not leak back into the test process
ra_run_twice() (
    export PATH="$scratch/bin:$PATH"
    export HOME="$scratch/home"
    export RA_SSHD_CONFIG="${RA_SSHD_CONFIG:-$scratch/sshd_config.fixture}"
    bash "$repo_root/scripts/remote-access.sh" "$@" >"$scratch/twice-1.out" 2>&1 || return 1
    if [ -f "$scratch/calls" ]; then
        wc -l <"$scratch/calls" >"$scratch/twice-1.count"
    else
        : >"$scratch/twice-1.count"
    fi
    bash "$repo_root/scripts/remote-access.sh" "$@" >"$scratch/twice-2.out" 2>&1 || return 1
    if [ -f "$scratch/calls" ]; then
        wc -l <"$scratch/calls" >"$scratch/twice-2.count"
    else
        : >"$scratch/twice-2.count"
    fi
    return 0
)

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

# ---------------------------------------------------------------------------
# Generation and cross-OS publication were removed. Authoritative local
# key behavior is exercised by ssh_authorization_test.py.

# 23-27. setup (spec §6). The stubs record every mutating call into
# $scratch/calls (one quoted-argv line per invocation); the systemctl stub
# derives is-active from that log, the apt-get stub materializes the xrdp
# binary it installs, and the tailscale stub derives serve status from the
# serve lines in the log - so a second setup pass finds every state already
# correct and records nothing (idempotency, executed).
# ---------------------------------------------------------------------------

# 23. (a) Unauthenticated tailscale: the verbatim ACTION REQUIRED block,
#     the tailscale-dependent path (serve) records NO calls, and the
#     independent path (sshd enable) still runs. Exit 0 - setup exits
#     non-zero only on hard failure, and an auth gate is not a crash.
#     uname is pinned back to Linux: test 8's Darwin stub persists in the
#     stub bin, and the arm dispatch keys off it.
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/full-linux-server.json' ;;
esac"
ra_stub "$scratch/bin" uname "printf 'Linux\n'"
ra_stub "$scratch/bin" tailscale "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"status --json\") printf '%s\n' '{\"BackendState\": \"NeedsLogin\"}' ;;
    serve*)
        line='tailscale'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    *) printf 'unexpected tailscale call: \$*\n' >&2
       exit 1 ;;
esac"
ra_stub "$scratch/bin" systemctl "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"get-default \") printf 'multi-user.target\n' ;;
    \"is-active ssh\") printf 'inactive\n'; exit 3 ;;
    \"enable --now\")
        line='systemctl'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    *) printf 'unexpected systemctl call: \$*\n' >&2
       exit 1 ;;
esac"
rm -f "$scratch/calls"
rc=0
out="$(ra_run setup 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "setup must exit 0 with unauthenticated tailscale (got $rc)"
printf '%s' "$out" | grep -Fq 'ACTION REQUIRED:' ||
    fail "setup must print the ACTION REQUIRED block verbatim (got: $out)"
printf '%s' "$out" | grep -Fq 'Authenticate this host with Tailscale, then rerun:' ||
    fail "the ACTION REQUIRED block must name the authenticate action (got: $out)"
printf '%s' "$out" | grep -Fq '    dot remote setup' ||
    fail "the ACTION REQUIRED block must end with the 4-space rerun line (got: $out)"
if grep -q '^tailscale ' "$scratch/calls" 2>/dev/null; then
    fail "unauthenticated tailscale must hold the serve path (got: $(cat "$scratch/calls"))"
fi
require "$scratch/calls" "systemctl 'enable' '--now' 'ssh'"
pass

# 24. (b)(c)(d) Desktop Linux (full-linux-desktop.json, get-default ->
#     graphical.target, the WSL fingerprint pinned away through
#     RA_PROC_VERSION): xrdp installed via the RA_PKG_MGR seam (apt-get
#     default) and enabled; sshd enabled; the declared login key
#     materialized (confirm seam) + authorized; EXACTLY two path-scoped
#     serve mappings with 127.0.0.1 targets (one per tailscale=true
#     service); tunnel render called (terminal 404 present); no "no GUI"
#     report; no token-shaped material anywhere in the output.
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/full-linux-desktop.json' ;;
esac"
ra_stub "$scratch/bin" uname "printf 'Linux\n'"
ra_stub "$scratch/bin" tailscale "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"status --json\") printf '%s\n' '{\"BackendState\": \"Running\"}' ;;
    \"serve status\")
        if [ -f \"\$log\" ]; then grep '127.0.0.1' \"\$log\" || true; fi
        exit 0 ;;
    serve*)
        line='tailscale'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    *) printf 'unexpected tailscale call: \$*\n' >&2
       exit 1 ;;
esac"
ra_stub "$scratch/bin" systemctl "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"get-default \") printf 'graphical.target\n' ;;
    \"is-active ssh\")
        if grep -Fxq \"systemctl 'enable' '--now' 'ssh'\" \"\$log\" 2>/dev/null; then
            printf 'active\n'
        else
            printf 'inactive\n'; exit 3
        fi ;;
    \"is-active xrdp\")
        if grep -Fxq \"systemctl 'enable' '--now' 'xrdp'\" \"\$log\" 2>/dev/null; then
            printf 'active\n'
        else
            printf 'inactive\n'; exit 3
        fi ;;
    \"enable --now\")
        line='systemctl'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        printf 'Created symlink /etc/systemd/system/multi-user.target.wants/xrdp.service\n' ;;
    *) printf 'unexpected systemctl call: \$*\n' >&2
       exit 1 ;;
esac"
ra_stub "$scratch/bin" apt-get "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"install -y\")
        line='apt-get'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        printf '#!/usr/bin/env bash\nexit 0\n' >'$scratch/bin/xrdp'
        chmod +x '$scratch/bin/xrdp'
        printf 'Selecting previously unselected package xrdp.\n' ;;
    *) printf 'unexpected apt-get call: \$*\n' >&2
       exit 1 ;;
esac"
rm -f "$scratch/calls" "$scratch/bin/xrdp"
rm -rf "$scratch/home/.ssh" "$scratch/home/.cloudflared"
export RA_PROC_VERSION="Linux version 6.8.0-generic"
export RA_CONFIRM_MATERIALIZE=1
rc=0
out="$(ra_run setup 2>&1)" || rc=$?
unset RA_PROC_VERSION RA_CONFIRM_MATERIALIZE
[ "$rc" -eq 0 ] || fail "setup must exit 0 on the desktop arm (got $rc)"
require "$scratch/calls" "apt-get 'install' '-y' 'xrdp'"
require "$scratch/calls" "systemctl 'enable' '--now' 'xrdp'"
require "$scratch/calls" "systemctl 'enable' '--now' 'ssh'"
if grep -q 'ssh-keygen.*-t' "$scratch/calls"; then fail 'setup must not generate keys'; fi
serve_count="$(grep -c '^tailscale ' "$scratch/calls" || true)"
[ "$serve_count" -eq 2 ] ||
    fail "exactly two serve mappings must be applied (got $serve_count: $(grep '^tailscale ' "$scratch/calls" || true))"
if grep '^tailscale ' "$scratch/calls" | grep -v -- '--set-path' | grep -q .; then
    fail "every serve mapping must be path-scoped --set-path (got: $(grep '^tailscale ' "$scratch/calls" || true))"
fi
if grep '^tailscale ' "$scratch/calls" | grep -v 'http://127.0.0.1:' | grep -q .; then
    fail "every serve mapping target must stay on 127.0.0.1 (got: $(grep '^tailscale ' "$scratch/calls" || true))"
fi
require "$scratch/home/.cloudflared/config.yml" 'tunnel: 00000000-0000-0000-0000-000000000000'
require "$scratch/home/.cloudflared/config.yml" '  - service: http_status:404'
[ ! -s "$scratch/home/.ssh/authorized_keys" ] || fail 'empty login_keys must leave no authorization entries'
if printf '%s' "$out" | grep -Fq 'no GUI'; then
    fail "the desktop arm must not report the server no-GUI line (got: $out)"
fi
if printf '%s' "$out" | grep -Eq 'ey[A-Za-z0-9_-]{20,}'; then
    fail "setup output must never contain token-shaped material (got: $out)"
fi
pass

# 25. (c) Idempotency, executed (ra_run_twice): the same recorded-stub set,
#     setup run twice - the second pass verifies already-correct state and
#     records ZERO mutating calls (the stubs derive is-active and serve
#     status from the call log; apt-get materialized the xrdp binary; the
#     login key exists; authorized_keys dedups).
rc=0
rm -f "$scratch/calls" "$scratch/bin/xrdp"
rm -rf "$scratch/home/.ssh" "$scratch/home/.cloudflared"
export RA_PROC_VERSION="Linux version 6.8.0-generic"
export RA_CONFIRM_MATERIALIZE=1
ra_run_twice setup || rc=$?
unset RA_PROC_VERSION RA_CONFIRM_MATERIALIZE
[ "$rc" -eq 0 ] ||
    fail "setup must exit 0 on both idempotency passes (pass1: $(cat "$scratch/twice-1.out"), pass2: $(cat "$scratch/twice-2.out"))"
count1="$(cat "$scratch/twice-1.count" 2>/dev/null || true)"
count2="$(cat "$scratch/twice-2.count" 2>/dev/null || true)"
count1="${count1:-0}"
count2="${count2:-0}"
[ "$count1" -gt 0 ] || fail "the first pass must record mutating calls (got $count1)"
[ "$count1" -eq "$count2" ] ||
    fail "the second pass must record zero mutating calls (pass1: $count1, pass2: $count2; new: $(tail -n "+$((count1 + 1))" "$scratch/calls" 2>/dev/null || true))"
require "$scratch/calls" "apt-get 'install' '-y' 'xrdp'"
require "$scratch/calls" "systemctl 'enable' '--now' 'xrdp'"
pass

# 26. (b) Server Linux (full-linux-server.json, get-default ->
#     multi-user.target, the WSL fingerprint pinned away so the DETECTION
#     decides, not the environment): no xrdp calls at all - the strict
#     apt-get/systemctl stubs would fail any install or xrdp enable - and
#     the output carries the spec's no-GUI verdict. sshd enable still
#     runs; the single tailscale=true service still gets its loopback
#     mapping.
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/full-linux-server.json' ;;
esac"
ra_stub "$scratch/bin" uname "printf 'Linux\n'"
ra_stub "$scratch/bin" systemctl "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"get-default \") printf 'multi-user.target\n' ;;
    \"is-active ssh\") printf 'inactive\n'; exit 3 ;;
    \"enable --now\")
        line='systemctl'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    *) printf 'unexpected systemctl call: \$*\n' >&2
       exit 1 ;;
esac"
ra_stub "$scratch/bin" apt-get "printf 'unexpected apt-get call: \$*\n' >&2
exit 1"
rm -f "$scratch/calls" "$scratch/bin/xrdp"
export RA_PROC_VERSION="Linux version 6.8.0-generic"
rc=0
out="$(ra_run setup 2>&1)" || rc=$?
unset RA_PROC_VERSION
[ "$rc" -eq 0 ] || fail "setup must exit 0 on the server arm (got $rc)"
printf '%s' "$out" | grep -Fq 'no GUI' ||
    fail "the server arm must report the no-GUI verdict (got: $out)"
if [ -e "$scratch/calls" ] && grep -q 'xrdp' "$scratch/calls"; then
    fail "the server arm must make no xrdp calls (got: $(cat "$scratch/calls"))"
fi
if [ -e "$scratch/calls" ] && grep -q 'apt-get' "$scratch/calls"; then
    fail "the server arm must invoke no package manager (got: $(cat "$scratch/calls"))"
fi
require "$scratch/calls" "systemctl 'enable' '--now' 'ssh'"
serve_count="$(grep -c '^tailscale ' "$scratch/calls" || true)"
[ "$serve_count" -eq 1 ] ||
    fail "the server arm must apply exactly one serve mapping (got $serve_count)"
if grep '^tailscale ' "$scratch/calls" | grep -qv 'http://127.0.0.1:4098'; then
    fail "the server serve mapping must target 127.0.0.1:4098 (got: $(grep '^tailscale ' "$scratch/calls" || true))"
fi
pass

# 27. (e) Darwin (full-mac.json, uname stubbed to Darwin): Remote Login is
#     a check-only state line from the strict systemsetup stub - any
#     enabling call would surface as an unexpected-invocation error - plus
#     exactly one serve mapping (127.0.0.1 target) and the tunnel render.
#     The login-key walk runs non-interactively: it WARNS 'not created',
#     never prompts, never generates.
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
ra_stub "$scratch/bin" tailscale "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"status --json\") printf '%s\n' '{\"BackendState\": \"Running\"}' ;;
    \"serve status\")
        if [ -f \"\$log\" ]; then grep '127.0.0.1' \"\$log\" || true; fi
        exit 0 ;;
    serve*)
        line='tailscale'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    *) printf 'unexpected tailscale call: \$*\n' >&2
       exit 1 ;;
esac"
rm -f "$scratch/calls"
rm -rf "$scratch/home/.ssh"
export RA_NONINTERACTIVE=1
rc=0
out="$(ra_run setup 2>&1)" || rc=$?
unset RA_NONINTERACTIVE
[ "$rc" -eq 0 ] || fail "setup must exit 0 on the darwin arm (got $rc)"
printf '%s' "$out" | grep -Fq '✓ ssh: Remote Login on' ||
    fail "the darwin arm must print the Remote Login state line (got: $out)"
if printf '%s' "$out" | grep -Fq 'unexpected systemsetup call'; then
    fail "darwin setup must stay check-only (no systemsetup writes)"
fi
serve_count="$(grep -c '^tailscale ' "$scratch/calls" || true)"
[ "$serve_count" -eq 1 ] ||
    fail "the darwin arm must apply exactly one serve mapping (got $serve_count)"
if grep '^tailscale ' "$scratch/calls" | grep -qv 'http://127.0.0.1:4099'; then
    fail "the darwin serve mapping must target 127.0.0.1:4099 (got: $(grep '^tailscale ' "$scratch/calls" || true))"
fi
require "$scratch/home/.cloudflared/config.yml" '  - service: http_status:404'
printf '%s' "$out" | grep -Fq 'SSH authorization in sync' ||
    fail "the darwin arm must reconcile the local key contract (got: $out)"
pass

# Missing/invalid declared keys now fail preflight; the authoritative engine
# suite verifies no authorization changes occur on those failures.

# 29. fix with [data.remote_access] absent: not configured + docs pointer,
#     exit 0 - a no-op, never a crash, never a call (spec §4).
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/off.json' ;;
esac"
rm -f "$scratch/calls"
rc=0
out="$(ra_run fix 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "fix must exit 0 when not configured (got $rc)"
printf '%s' "$out" | grep -Fq 'not configured' ||
    fail "fix must print 'not configured' when the key is absent (got: $out)"
printf '%s' "$out" | grep -Fq 'docs/remote-access.md' ||
    fail "fix's not-configured line must point at the docs (got: $out)"
if [ -e "$scratch/calls" ]; then
    fail "the not-configured no-op must record no calls (got: $(cat "$scratch/calls"))"
fi
pass

# 30. fix on a server whose sshd is stopped: exactly the two repairs -
#     `systemctl restart ssh` and the startup-mode restore (`systemctl
#     enable ssh`) - recorded, exit 0 (a repair is not a failure), and the
#     unauthenticated backend holds serve (no tailscale mutation at all).
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/full-linux-server.json' ;;
esac"
ra_stub "$scratch/bin" uname "printf 'Linux\n'"
ra_stub "$scratch/bin" tailscale "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"status --json\") printf '%s\n' '{\"BackendState\": \"NeedsLogin\"}' ;;
    serve*)
        line='tailscale'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    *) printf 'unexpected tailscale call: \$*\n' >&2
       exit 1 ;;
esac"
ra_stub "$scratch/bin" systemctl "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"is-active ssh\") printf 'inactive\n'; exit 3 ;;
    \"is-enabled ssh\") printf 'disabled\n'; exit 1 ;;
    \"list-unit-files cloudflared.service\") printf 'UNIT FILE         STATE           VENDOR PRESET\n' ;;
    \"restart ssh\")
        line='systemctl'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    \"enable ssh\")
        line='systemctl'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    *) printf 'unexpected systemctl call: \$*\n' >&2
       exit 1 ;;
esac"
rm -f "$scratch/calls"
rc=0
out="$(ra_run fix 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "fix must exit 0 after repairing (got $rc: $out)"
require "$scratch/calls" "systemctl 'restart' 'ssh'"
require "$scratch/calls" "systemctl 'enable' 'ssh'"
repair_lines="$(wc -l <"$scratch/calls" 2>/dev/null || true)"
repair_lines="${repair_lines:-0}"
[ "$repair_lines" -eq 2 ] ||
    fail "fix must record exactly the two sshd repairs (got $repair_lines: $(cat "$scratch/calls" 2>/dev/null || true))"
if grep -Fq "systemctl 'restart' 'cloudflared'" "$scratch/calls" 2>/dev/null; then
    fail "fix must not restart cloudflared when its unit is absent (got: $(cat "$scratch/calls"))"
fi
if grep -q '^tailscale ' "$scratch/calls" 2>/dev/null; then
    fail "unauthenticated tailscale must hold the serve path during fix (got: $(cat "$scratch/calls"))"
fi
printf '%s' "$out" | grep -Fq '✓ ssh: sshd restarted' ||
    fail "fix must report the restart (got: $out)"
printf '%s' "$out" | grep -Fq 'serve: skipped' ||
    fail "fix must hold the serve path while tailscale is unauthenticated (got: $out)"
pass

# 31. fix on a healthy host (sshd active + enabled, the configured serve
#     mapping already in place, the cloudflared unit installed AND
#     running): ZERO mutating calls - fix is repair-only, the in-place
#     mapping is verified not rewritten, the running cloudflared service is
#     verified not bounced, and the tunnel config re-render is a
#     byte-identical local write.
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/full-linux.json' ;;
esac"
ra_stub "$scratch/bin" tailscale "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"status --json\") printf '%s\n' '{\"BackendState\": \"Running\"}' ;;
    \"serve status\")
        printf '%s\n' 'https://machine.example.net:443 path / --> http://127.0.0.1:4098' ;;
    serve*)
        line='tailscale'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    *) printf 'unexpected tailscale call: \$*\n' >&2
       exit 1 ;;
esac"
ra_stub "$scratch/bin" systemctl "case \"\$1 \${2:-}\" in
    \"is-active ssh\") printf 'active\n' ;;
    \"is-enabled ssh\") printf 'enabled\n' ;;
    \"list-unit-files cloudflared.service\") printf 'UNIT FILE         STATE           VENDOR PRESET\ncloudflared.service enabled        enabled\n' ;;
    \"is-active cloudflared\") printf 'active\n' ;;
    *) printf 'unexpected systemctl call: \$*\n' >&2
       exit 1 ;;
esac"
rm -f "$scratch/calls"
rc=0
out="$(ra_run fix 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "fix must exit 0 on a healthy host (got $rc: $out)"
if [ -e "$scratch/calls" ] && [ -s "$scratch/calls" ]; then
    fail "fix on a healthy host must record zero mutating calls (got: $(cat "$scratch/calls"))"
fi
printf '%s' "$out" | grep -Fq '✓ cloudflared: service running' ||
    fail "the running cloudflared service must be verified, not bounced (got: $out)"
printf '%s' "$out" | grep -Fq 'already mapped' ||
    fail "the in-place serve mapping must be verified, not rewritten (got: $out)"
printf '%s' "$out" | grep -Fq 'tunnel config written' ||
    fail "fix must re-render the tunnel config (got: $out)"
pass

# ---------------------------------------------------------------------------
# 32-34. harden-ssh (spec §4) - the guarded key-only flip. Two guards, both
# required: ~/.ssh/authorized_keys holds at least one key AND --confirmed
# is passed. A refusal exits 1 with the reason and never writes
# sshd_config; with both guards met, the config at $RA_SSHD_CONFIG gains
# exactly one active `PasswordAuthentication no` and the restart is
# recorded - byte-identically on a second run.
# ---------------------------------------------------------------------------

# 32. Key authorized but no --confirmed: the refusal names the attestation,
#     exit 1, no sshd_config write, no systemctl call (the strict stub
#     would fail any).
ra_stub "$scratch/bin" systemctl "printf 'unexpected systemctl call: \$*\n' >&2
exit 1"
mkdir -p "$scratch/home/.ssh"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4bGmSPbKDIX6g9uAAaf7UNuYF8b2TmXLamtGpiI6Cd dropped@other-device\n' >"$scratch/home/.ssh/authorized_keys"
rm -f "$scratch/home/sshd_config" "$scratch/calls"
export RA_SSHD_CONFIG="$scratch/home/sshd_config"
rc=0
out="$(ra_run harden-ssh 2>&1)" || rc=$?
unset RA_SSHD_CONFIG
[ "$rc" -eq 1 ] || fail "harden-ssh without --confirmed must exit 1 (got $rc)"
printf '%s' "$out" | grep -Fq -- '--confirmed' ||
    fail "the refusal must name --confirmed (got: $out)"
if [ -e "$scratch/home/sshd_config" ]; then
    fail "the refusal must not write sshd_config"
fi
if [ -e "$scratch/calls" ]; then
    fail "the refusal must not restart sshd (got: $(cat "$scratch/calls"))"
fi
pass

# 33. --confirmed but authorized_keys holds no key: the refusal names the
#     authorized_keys state, exit 1, sshd_config byte-identical, no restart.
printf 'Port 22\n' >"$scratch/home/sshd_config"
cp "$scratch/home/sshd_config" "$scratch/home/sshd_config.before"
rm -rf "$scratch/home/.ssh"
rm -f "$scratch/calls"
export RA_SSHD_CONFIG="$scratch/home/sshd_config"
rc=0
out="$(ra_run harden-ssh --confirmed 2>&1)" || rc=$?
unset RA_SSHD_CONFIG
[ "$rc" -eq 1 ] || fail "harden-ssh with zero authorized keys must exit 1 (got $rc)"
printf '%s' "$out" | grep -Fq 'no authorized key' ||
    fail "the refusal must name the missing authorized key (got: $out)"
if ! cmp -s "$scratch/home/sshd_config" "$scratch/home/sshd_config.before"; then
    fail "the refusal must leave sshd_config untouched"
fi
if [ -e "$scratch/calls" ]; then
    fail "the refusal must not restart sshd (got: $(cat "$scratch/calls"))"
fi
pass

# 33b. The key count must not depend on the data pipe. `remote_keys.py count`
#      exits without reading stdin, so when the producer is still writing (a
#      payload past the pipe buffer, forced here with 1 MB) it dies of SIGPIPE
#      and, under `set -o pipefail`, harden-ssh exited 1 with NO message. Small
#      payloads only passed by winning a race: reliably lost on Git Bash,
#      intermittent under load elsewhere.
cp "$scratch/bin/chezmoi" "$scratch/chezmoi.saved"
big="$scratch/big-remote-access.json"
{ printf '{"remote_access":{"padding":"'; head -c 1000000 /dev/zero | tr '\0' 'a'; printf '"}}'; } >"$big"
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$big' ;;
esac"
printf 'Port 22\n' >"$scratch/home/sshd_config"
rm -rf "$scratch/home/.ssh"
export RA_SSHD_CONFIG="$scratch/home/sshd_config"
rc=0
out="$(ra_run harden-ssh --confirmed 2>&1)" || rc=$?
unset RA_SSHD_CONFIG
cp "$scratch/chezmoi.saved" "$scratch/bin/chezmoi"
[ "$rc" -eq 1 ] || fail "33b: harden-ssh with zero keys and a large data payload must exit 1 (got $rc)"
printf '%s' "$out" | grep -Fq 'no authorized key' ||
    fail "33b: the refusal must name the missing key even when the data pipe is large (got: $out)"
pass

# 34. Both guards met: the config gains exactly one active
#     `PasswordAuthentication no` (the commented default line goes), the
#     unrelated lines survive, the restart is the only systemctl call - and
#     a second run is byte-identical.
rm -f "$scratch/calls"
mkdir -p "$scratch/home/.ssh"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4bGmSPbKDIX6g9uAAaf7UNuYF8b2TmXLamtGpiI6Cd dropped@other-device\n' >"$scratch/home/.ssh/authorized_keys"
printf '%s\n' \
    'Port 22' \
    '#PasswordAuthentication yes' \
    'PubkeyAuthentication yes' >"$scratch/home/sshd_config"
ra_stub "$scratch/bin" systemctl "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"restart ssh\")
        line='systemctl'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    *) printf 'unexpected systemctl call: \$*\n' >&2
       exit 1 ;;
esac"
export RA_SSHD_CONFIG="$scratch/home/sshd_config"
rc=0
out="$(ra_run harden-ssh --confirmed 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "harden-ssh with a key and --confirmed must exit 0 (got $rc: $out)"
require "$scratch/home/sshd_config" 'PasswordAuthentication no'
require "$scratch/home/sshd_config" 'Port 22'
require "$scratch/home/sshd_config" 'PubkeyAuthentication yes'
pa_lines="$(grep -c 'PasswordAuthentication' "$scratch/home/sshd_config" || true)"
[ "$pa_lines" -eq 1 ] ||
    fail "exactly one PasswordAuthentication line must remain (got $pa_lines: $(cat "$scratch/home/sshd_config"))"
require "$scratch/calls" "systemctl 'restart' 'ssh'"
restart_lines="$(wc -l <"$scratch/calls" 2>/dev/null || true)"
restart_lines="${restart_lines:-0}"
[ "$restart_lines" -eq 1 ] ||
    fail "the restart must be the only systemctl call (got: $(cat "$scratch/calls" 2>/dev/null || true))"
cp "$scratch/home/sshd_config" "$scratch/home/sshd_config.once"
rc=0
out="$(ra_run harden-ssh --confirmed 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "the second harden-ssh must exit 0 (got $rc)"
if ! cmp -s "$scratch/home/sshd_config" "$scratch/home/sshd_config.once"; then
    fail "a second harden-ssh must be byte-identical (idempotent)"
fi
unset RA_SSHD_CONFIG
pass

# ---------------------------------------------------------------------------
# 35-36. fix's cloudflared + portproxy arms (spec §8). The cloudflared
# service restarts only when the systemd unit exists and is not running
# (read-only list-unit-files existence probe); the :2222 portproxy is
# Windows-owned, so a wsl.enabled host gets the pointer line naming the
# Windows-host arm, and nothing else is touched.
# ---------------------------------------------------------------------------

# 35. The unit exists but is not running: exactly one mutating call -
#     `systemctl restart cloudflared` - the restart is reported, and the
#     read-only existence probe records nothing.
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/full-linux-server.json' ;;
esac"
ra_stub "$scratch/bin" uname "printf 'Linux\n'"
ra_stub "$scratch/bin" tailscale "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"status --json\") printf '%s\n' '{\"BackendState\": \"NeedsLogin\"}' ;;
    serve*)
        line='tailscale'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    *) printf 'unexpected tailscale call: \$*\n' >&2
       exit 1 ;;
esac"
ra_stub "$scratch/bin" systemctl "log='$scratch/calls'
case \"\$1 \${2:-}\" in
    \"is-active ssh\") printf 'active\n' ;;
    \"is-enabled ssh\") printf 'enabled\n' ;;
    \"list-unit-files cloudflared.service\") printf 'UNIT FILE         STATE           VENDOR PRESET\ncloudflared.service enabled        enabled\n' ;;
    \"is-active cloudflared\") printf 'inactive\n'; exit 3 ;;
    \"restart cloudflared\")
        line='systemctl'
        for a in \"\$@\"; do line=\"\$line '\$a'\"; done
        printf '%s\n' \"\$line\" >>\"\$log\"
        exit 0 ;;
    *) printf 'unexpected systemctl call: \$*\n' >&2
       exit 1 ;;
esac"
rm -f "$scratch/calls"
rc=0
out="$(ra_run fix 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "fix must exit 0 after restarting cloudflared (got $rc: $out)"
require "$scratch/calls" "systemctl 'restart' 'cloudflared'"
repair_lines="$(wc -l <"$scratch/calls" 2>/dev/null || true)"
repair_lines="${repair_lines:-0}"
[ "$repair_lines" -eq 1 ] ||
    fail "the cloudflared restart must be the only mutating call (got $repair_lines: $(cat "$scratch/calls" 2>/dev/null || true))"
printf '%s' "$out" | grep -Fq '✓ cloudflared: service restarted' ||
    fail "fix must report the cloudflared restart (got: $out)"
pass

# 36. The portproxy pointer: a wsl.enabled host (full-linux-wsl.json) gets
#     the Windows-owned pointer line and NOTHING else - sshd is
#     active+enabled, the cloudflared unit is absent, serve is held
#     (unauth), so fix records zero mutating calls.
ra_stub "$scratch/bin" chezmoi "case \"\$1\" in
    data) cat '$repo_root/tests/fixtures/remote_access/full-linux-wsl.json' ;;
esac"
ra_stub "$scratch/bin" uname "printf 'Linux\n'"
ra_stub "$scratch/bin" tailscale "case \"\$1 \${2:-}\" in
    \"status --json\") printf '%s\n' '{\"BackendState\": \"NeedsLogin\"}' ;;
    *) printf 'unexpected tailscale call: \$*\n' >&2
       exit 1 ;;
esac"
ra_stub "$scratch/bin" systemctl "case \"\$1 \${2:-}\" in
    \"is-active ssh\") printf 'active\n' ;;
    \"is-enabled ssh\") printf 'enabled\n' ;;
    \"list-unit-files cloudflared.service\") printf 'UNIT FILE         STATE           VENDOR PRESET\n' ;;
    *) printf 'unexpected systemctl call: \$*\n' >&2
       exit 1 ;;
esac"
rm -f "$scratch/calls"
rc=0
out="$(ra_run fix 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "fix must exit 0 on the wsl-declared host (got $rc: $out)"
printf '%s' "$out" | grep -Fq 'portproxy: Windows-owned - run: dot remote wsl-reconcile on the Windows host' ||
    fail "fix must print the Windows-owned portproxy pointer when wsl.enabled (got: $out)"
if [ -e "$scratch/calls" ] && [ -s "$scratch/calls" ]; then
    fail "the healthy wsl-declared host must record zero mutating calls (got: $(cat "$scratch/calls"))"
fi
pass

finish
