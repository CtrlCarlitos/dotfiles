#!/usr/bin/env bash
set -euo pipefail

# install_maestro <version> <sha256> [retry-hint] (scripts/lib/agent-skills.sh): the
# mobile_dev group's Maestro CLI, shared by `dot up` (the installer template renders
# the pins into the call) and `dot upgrade` (which follows the pin). EXECUTED against
# a stub curl and a fixture maestro.zip.
#
# The 2026-10-11 WSL `dot up`: "maestro download failed or timed out - skipping".
# The release asset is 300 MB and the link ran at ~170 KiB/s, so the 300 s wall
# clock could never succeed there, and the next `dot up` never retried (run_onchange
# re-enters only when the rendered script changes), while `dot upgrade` did not know
# Maestro existed. The contract:
#   - the download is guarded by a STALL limit (curl --speed-limit/--speed-time), not
#     a wall clock: a dead transfer is killed, a slow one is allowed to finish
#   - the install records the pinned version (~/.local/opt/maestro/.dotfiles-version),
#     so a pin bump reinstalls and the same pin is a no-op
#   - a Maestro that is not ours (on PATH, not under ~/.local/opt) is left alone
#   - a failed download warns with the retry hint the caller passes (`dot upgrade`: it
#     installs a missing Maestro by itself, so nothing needs the run_onchange script re-entered)
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
lib="$repo_root/scripts/lib/agent-skills.sh"

command -v zip >/dev/null 2>&1 || skip 'zip not installed (fixture needed)'
command -v unzip >/dev/null 2>&1 || skip 'unzip not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/fixture/maestro/bin" "$tmp/fixture/maestro/lib"
printf '#!/bin/sh\necho maestro-fixture\n' >"$tmp/fixture/maestro/bin/maestro"
: >"$tmp/fixture/maestro/lib/maestro.jar"
(cd "$tmp/fixture" && zip -qr "$tmp/maestro.zip" maestro) || { fail 'could not build the fixture zip'; finish; }
fixture_sha="$(sha256sum "$tmp/maestro.zip" 2>/dev/null || shasum -a 256 "$tmp/maestro.zip")"
fixture_sha="${fixture_sha%% *}"

# curl: logs its argv, copies the fixture to -o/--output, or fails with 28 (CURL_MODE=stall).
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${CURL_LOG:?}"
[ "${CURL_MODE:-ok}" = stall ] && exit 28
out=''; prev=''
for a in "$@"; do
    case "$prev" in -o|--output) out="$a" ;; esac
    prev="$a"
done
[ -n "$out" ] || exit 2
if [ "${CURL_MODE:-ok}" = slow ]; then
    head -c 1024 "${FIXTURE_ZIP:?}" >"$out"
    sleep "${CURL_SLOW_SECS:-2}"
fi
/bin/cat "${FIXTURE_ZIP:?}" >"$out"
EOF
chmod +x "$tmp/bin/curl"

# run <home> [args...]: executes install_maestro under set -e like the installer; prints stdout+stderr.
# PATH is controlled: the host's own Maestro (~/.local/bin on a box where `dot up` installed it)
# would read as "a Maestro that is not ours" and skip every download below. RUN_EXTRA_PATH adds
# a directory for the case that wants exactly that.
run() {
    local home="$1"; shift
    HOME="$home" PATH="$tmp/bin:${RUN_EXTRA_PATH:+$RUN_EXTRA_PATH:}/usr/bin:/bin" CURL_LOG="$tmp/curl.log" FIXTURE_ZIP="$tmp/maestro.zip" \
        bash -c 'set -euo pipefail; . "$1"; shift; install_maestro "$@"; echo rc=$?' _ "$lib" "$@" 2>&1
}
opt=".local/opt/maestro"

# A. Fresh install: stall-guarded download, verified, laid out, linked, version recorded.
h="$tmp/a"; mkdir -p "$h"; : >"$tmp/curl.log"
got="$(run "$h" 2.11.0 "$fixture_sha")"
case "$got" in *rc=0*) pass ;; *) fail "fresh: did not complete (output: $got)" ;; esac
grep -Fq 'https://github.com/mobile-dev-inc/maestro/releases/download/cli-2.11.0/maestro.zip' "$tmp/curl.log" \
    || fail "fresh: must download the pinned release asset (curl saw: $(/bin/cat "$tmp/curl.log"))"
if grep -Eq -- '--speed-limit [0-9]+' "$tmp/curl.log" && grep -Eq -- '--speed-time [0-9]+' "$tmp/curl.log"; then
    pass
else
    fail "fresh: the download must be stall-guarded with --speed-limit/--speed-time (curl saw: $(/bin/cat "$tmp/curl.log"))"
fi
[ -x "$h/$opt/bin/maestro" ] || fail "fresh: ~/$opt/bin/maestro must be executable"
[ "$(readlink "$h/.local/bin/maestro")" = "$h/$opt/bin/maestro" ] || fail "fresh: ~/.local/bin/maestro must link to the install (got '$(readlink "$h/.local/bin/maestro" || true)')"
[ "$(/bin/cat "$h/$opt/.dotfiles-version" 2>/dev/null)" = 2.11.0 ] || fail "fresh: the installed pin must be recorded in ~/$opt/.dotfiles-version"
case "$got" in *'Maestro 2.11.0 installed'*) pass ;; *) fail "fresh: must report the install (output: $got)" ;; esac

# B. Same pin again: nothing downloaded.
: >"$tmp/curl.log"
got="$(run "$h" 2.11.0 "$fixture_sha")"
[ ! -s "$tmp/curl.log" ] || fail "same pin: must not download again (curl saw: $(/bin/cat "$tmp/curl.log"))"
case "$got" in *rc=0*) pass ;; *) fail "same pin: did not complete (output: $got)" ;; esac

# C. Pin bump: reinstalled, version marker follows.
: >"$tmp/curl.log"
got="$(run "$h" 2.12.0 "$fixture_sha")"
grep -Fq 'cli-2.12.0/maestro.zip' "$tmp/curl.log" || fail "pin bump: must download the new pin (curl saw: $(/bin/cat "$tmp/curl.log"))"
[ "$(/bin/cat "$h/$opt/.dotfiles-version" 2>/dev/null)" = 2.12.0 ] || fail "pin bump: the marker must follow the pin"
case "$got" in *'Maestro 2.12.0 installed'*) pass ;; *) fail "pin bump: must report the new version (output: $got)" ;; esac

# D. A stalled download: warned with the caller's retry hint, nothing installed, exit 0.
h="$tmp/d"; mkdir -p "$h"; : >"$tmp/curl.log"
got="$(CURL_MODE=stall run "$h" 2.11.0 "$fixture_sha" 'dot upgrade')"
case "$got" in
    *'maestro download failed or stalled'*'dot upgrade'*rc=0*) pass ;;
    *) fail "stall: must warn, name the retry hint and continue (output: $got)" ;;
esac
if [ -e "$h/$opt" ] || [ -e "$h/.local/bin/maestro" ]; then fail "stall: nothing may be installed"; fi

# E. Checksum mismatch: nothing installed, exit 0.
h="$tmp/e"; mkdir -p "$h"; : >"$tmp/curl.log"
got="$(run "$h" 2.11.0 0000000000000000000000000000000000000000000000000000000000000000)"
case "$got" in *'maestro CHECKSUM MISMATCH'*rc=0*) pass ;; *) fail "mismatch: must warn CHECKSUM MISMATCH and continue (output: $got)" ;; esac
[ ! -e "$h/$opt/bin/maestro" ] || fail "mismatch: nothing may be extracted from an unverified zip"

# F. A Maestro that is not ours on PATH: left alone, no download.
h="$tmp/f"; mkdir -p "$h/elsewhere"; : >"$tmp/curl.log"
printf '#!/bin/sh\nexit 0\n' >"$h/elsewhere/maestro"; chmod +x "$h/elsewhere/maestro"
got="$(RUN_EXTRA_PATH="$h/elsewhere" run "$h" 2.11.0 "$fixture_sha")"
[ ! -s "$tmp/curl.log" ] || fail "foreign maestro: must not download (curl saw: $(/bin/cat "$tmp/curl.log"))"
[ ! -e "$h/$opt" ] || fail "foreign maestro: must not install alongside"
case "$got" in *rc=0*) pass ;; *) fail "foreign maestro: did not complete (output: $got)" ;; esac

# G. A slow-but-alive download gets periodic progress feedback, not total silence
#    for its whole duration (2026-10-11: a ~300 MB Maestro download on a slow WSL
#    link looked indistinguishable from stuck for 20+ minutes).
h="$tmp/g"; mkdir -p "$h"; : >"$tmp/curl.log"
got="$(CURL_MODE=slow CURL_SLOW_SECS=2 MAESTRO_HEARTBEAT_SECS=1 run "$h" 2.11.0 "$fixture_sha")"
case "$got" in *rc=0*) pass ;; *) fail "slow: did not complete (output: $got)" ;; esac
case "$got" in *'still downloading'*) pass ;; *) fail "slow: must print at least one heartbeat line while the download runs (output: $got)" ;; esac
case "$got" in *'Maestro 2.11.0 installed'*) pass ;; *) fail "slow: must still report the install once the download finishes (output: $got)" ;; esac

finish
