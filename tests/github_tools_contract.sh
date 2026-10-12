#!/usr/bin/env bash
set -euo pipefail

# github_tool_sync <delta|dust|procs> <sudo-cmd> <install|upgrade> (scripts/lib/agent-skills.sh):
# the three modern_cli tools that come from GitHub releases on Debian/Ubuntu (no apt repo),
# shared by the installer (install when missing) and `dot upgrade` (upgrade when behind).
# EXECUTED against fake curl/dpkg/sudo and fixture assets.
#
# Until 2026-10-11 the installer had three near-identical blocks gated on `command -v`, with no
# pin and no upgrade path: `dot upgrade` ended with "delta 0.19.2 (0.20.1 available) ... re-run
# the installer", and re-running did nothing because the binary existed. Windows (winget) and
# macOS (brew) already upgrade these through the package-manager sweep; Linux was the gap.
#   - install: a present tool is left alone, silently; a missing one is installed at the newest
#     release tag (github_latest_tag: git ls-remote, not the rate-limited GitHub API)
#   - upgrade: a missing tool is left alone; current (or ahead) is reported current; behind is
#     downloaded and installed, then reported; an unknown newest tag is reported, not acted on
#   - assets: delta git-delta_<v>_amd64.deb and dust du-dust_<v>-1_amd64.deb via dpkg -i (then
#     apt-get -f); procs from its x86_64 zip into GITHUB_TOOL_BIN (/usr/local/bin) via install
#   - the download is stall-guarded (curl --speed-limit/--speed-time), like Maestro's; a failed
#     download warns and returns 0 - never aborts a `set -e` run
#   - amd64 assets only: any other machine says so and skips
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
lib="$repo_root/scripts/lib/agent-skills.sh"
tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"
du="$repo_root/scripts/dotupgrade.sh"

command -v zip >/dev/null 2>&1 || skip 'zip not installed (fixture needed)'
command -v unzip >/dev/null 2>&1 || skip 'unzip not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/sys" "$tmp/dest" "$tmp/fixture"
# coreutils the helper needs, and nothing else: the host's own delta/dust/procs must not leak in
for c in bash sh grep sed sort head tail cat tr wc mktemp rm mkdir awk cut timeout env printf dirname basename readlink unzip install cp mv chmod touch; do
    if p="$(command -v "$c" 2>/dev/null)"; then ln -s "$p" "$tmp/sys/$c" 2>/dev/null || true; fi
done
printf 'not a real deb\n' >"$tmp/fixture/asset.deb"
printf '#!/bin/sh\necho procs-fixture\n' >"$tmp/fixture/procs"; chmod +x "$tmp/fixture/procs"
(cd "$tmp/fixture" && zip -q "$tmp/fixture/procs.zip" procs)
# curl: logs argv; copies the matching fixture to -o; CURL_MODE=stall fails with 28
cat >"$tmp/bin/curl" <<'EOF2'
#!/bin/sh
printf '%s\n' "$*" >>"${CURL_LOG:?}"
[ "${CURL_MODE:-ok}" = stall ] && exit 28
out=''; prev=''; url=''
for a in "$@"; do case "$prev" in -o|--output) out="$a" ;; esac; case "$a" in http*) url="$a" ;; esac; prev="$a"; done
[ -n "$out" ] || exit 2
case "$url" in *.zip) cp "${FIXTURE_DIR:?}/procs.zip" "$out" ;; *) cp "${FIXTURE_DIR:?}/asset.deb" "$out" ;; esac
EOF2
printf '#!/bin/sh\nprintf "dpkg %%s\\n" "$*" >>"${TOOL_LOG:?}"\nexit "${DPKG_RC:-0}"\n' >"$tmp/bin/dpkg"
printf '#!/bin/sh\nprintf "apt-get %%s\\n" "$*" >>"${TOOL_LOG:?}"\nexit 0\n' >"$tmp/bin/apt-get"
printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >>"${TOOL_LOG:?}"\nexec "$@"\n' >"$tmp/bin/sudo"
printf '#!/bin/sh\nprintf "%%s\\n" "${FAKE_ARCH:-x86_64}"\n' >"$tmp/bin/uname"
chmod +x "$tmp/bin"/*
set_tool() { # <name> <version|-> : a fake tool reporting its version, or none at all
    rm -f "$tmp/bin/$1"
    [ "$2" = - ] && return 0
    printf '#!/bin/sh\necho "%s %s"\n' "$1" "$2" >"$tmp/bin/$1"; chmod +x "$tmp/bin/$1"
}
# run <name> <sudo> <mode> : github_latest_tag answers $FAKE_LATEST; prints stdout+stderr and rc
run() {
    : >"$tmp/tool.log"; : >"$tmp/curl.log"
    PATH="$tmp/bin:$tmp/sys" CURL_LOG="$tmp/curl.log" TOOL_LOG="$tmp/tool.log" FIXTURE_DIR="$tmp/fixture" GITHUB_TOOL_BIN="$tmp/dest" \
        bash -c 'set -euo pipefail; . "$1"; shift; github_latest_tag() { printf "%s\n" "${FAKE_LATEST:-}"; }; rc=0; github_tool_sync "$@" || rc=$?; echo "rc=$rc"' _ "$lib" "$@" 2>&1
}
run_collect() { # same, inside tool_current_collect ... tool_current_flush (dot upgrade's span)
    : >"$tmp/tool.log"; : >"$tmp/curl.log"
    PATH="$tmp/bin:$tmp/sys" CURL_LOG="$tmp/curl.log" TOOL_LOG="$tmp/tool.log" FIXTURE_DIR="$tmp/fixture" GITHUB_TOOL_BIN="$tmp/dest" \
        bash -c 'set -euo pipefail; . "$1"; shift; github_latest_tag() { printf "%s\n" "${FAKE_LATEST:-}"; }; rc=0; tool_current_collect; github_tool_sync "$@" || rc=$?; tool_current_flush "GitHub-release tools"; echo "rc=$rc"' _ "$lib" "$@" 2>&1
}

# A. install, delta missing: newest tag, deb URL, dpkg -i through sudo, one info line
set_tool delta -
got="$(FAKE_LATEST=0.20.1 run delta sudo install)"
case "$got" in *'Installing delta 0.20.1'*rc=0*) pass ;; *) fail "install: must announce and return 0 (got: $got)" ;; esac
grep -Fq 'https://github.com/dandavison/delta/releases/download/0.20.1/git-delta_0.20.1_amd64.deb' "$tmp/curl.log" || fail "install: delta's asset URL (curl saw: $(/bin/cat "$tmp/curl.log"))"
if grep -Eq -- '--speed-limit [0-9]+' "$tmp/curl.log" && grep -Eq -- '--speed-time [0-9]+' "$tmp/curl.log"; then
    pass
else
    fail "install: the download must be stall-guarded (curl saw: $(/bin/cat "$tmp/curl.log"))"
fi
grep -Eq '^sudo dpkg -i .*git-delta_0.20.1_amd64.deb$' "$tmp/tool.log" || fail "install: dpkg -i through the given sudo (log: $(/bin/cat "$tmp/tool.log"))"

# B. install, delta present: nothing, silently
set_tool delta 0.19.2
got="$(FAKE_LATEST=0.20.1 run delta sudo install)"
[ "$got" = "rc=0" ] || fail "install, present: must be silent (got: $got)"
[ ! -s "$tmp/curl.log" ] || fail "install, present: must not download"

# C. upgrade, delta behind: downloaded, installed, reported
set_tool delta 0.19.2
got="$(FAKE_LATEST=0.20.1 run delta sudo upgrade)"
case "$got" in *'delta upgraded to 0.20.1'*rc=0*) pass ;; *) fail "upgrade: must report the new version (got: $got)" ;; esac
grep -Fq 'git-delta_0.20.1_amd64.deb' "$tmp/curl.log" || fail "upgrade: must download the newest release"
grep -Eq '^sudo dpkg -i ' "$tmp/tool.log" || fail "upgrade: dpkg -i through sudo (log: $(/bin/cat "$tmp/tool.log"))"

# D. upgrade, dust current: reported current, no download; the dust URL shape is v-prefixed
set_tool dust 1.2.6
got="$(FAKE_LATEST=1.2.6 run dust sudo upgrade)"
case "$got" in *'dust is current (1.2.6)'*rc=0*) pass ;; *) fail "upgrade, current: must say so (got: $got)" ;; esac
[ ! -s "$tmp/curl.log" ] || fail "upgrade, current: must not download"
# inside a collect span the line is held and flushed as one for every current tool (dot upgrade
# printed five of them in a row, 2026-10-12)
got="$(FAKE_LATEST=1.2.6 run_collect dust sudo upgrade)"
case "$got" in *'dust is current'*) fail "collect span: the per-tool line must be held (got: $got)" ;; *'   GitHub-release tools current: dust 1.2.6'*rc=0*) pass ;; *) fail "collect span: one folded line expected (got: $got)" ;; esac
set_tool dust 1.2.5
got="$(FAKE_LATEST=1.2.6 run dust sudo upgrade)"
grep -Fq 'https://github.com/bootandy/dust/releases/download/v1.2.6/du-dust_1.2.6-1_amd64.deb' "$tmp/curl.log" || fail "dust's asset URL (curl saw: $(/bin/cat "$tmp/curl.log"))"
case "$got" in *'dust upgraded to 1.2.6'*) pass ;; *) fail "dust upgrade must report (got: $got)" ;; esac

# E. upgrade, tool absent: left alone, silently (the installer's job, and only if the group is on)
set_tool dust -
got="$(FAKE_LATEST=1.2.6 run dust sudo upgrade)"
[ "$got" = "rc=0" ] || fail "upgrade, absent: must be silent (got: $got)"
[ ! -s "$tmp/curl.log" ] || fail "upgrade, absent: must not download"

# F. upgrade, newest tag unknown (offline): said, not acted on
set_tool dust 1.2.5
got="$(FAKE_LATEST='' run dust sudo upgrade)"
case "$got" in *'dust'*'newest release unknown'*rc=0*) pass ;; *) fail "upgrade, offline: must say the lookup failed (got: $got)" ;; esac
[ ! -s "$tmp/curl.log" ] || fail "upgrade, offline: must not download"

# G. procs: zip, extracted, installed into GITHUB_TOOL_BIN through sudo
set_tool procs 0.14.0
got="$(FAKE_LATEST=0.14.10 run procs sudo upgrade)"
grep -Fq 'https://github.com/dalance/procs/releases/download/v0.14.10/procs-v0.14.10-x86_64-linux.zip' "$tmp/curl.log" || fail "procs' asset URL (curl saw: $(/bin/cat "$tmp/curl.log"))"
[ -x "$tmp/dest/procs" ] || fail "procs: the binary must land in GITHUB_TOOL_BIN (got: $got)"
grep -Eq '^sudo install ' "$tmp/tool.log" || fail "procs: installed through sudo (log: $(/bin/cat "$tmp/tool.log"))"
case "$got" in *'procs upgraded to 0.14.10'*rc=0*) pass ;; *) fail "procs upgrade must report (got: $got)" ;; esac

# H. a stalled download: warned, nothing installed, rc 0
set_tool delta 0.19.2
got="$(CURL_MODE=stall FAKE_LATEST=0.20.1 run delta sudo upgrade)"
case "$got" in *'delta'*'failed'*rc=0*) pass ;; *) fail "stall: must warn and return 0 (got: $got)" ;; esac
if grep -q '^sudo dpkg' "$tmp/tool.log"; then fail "stall: nothing may be installed"; else pass; fi

# I. not amd64: said and skipped
set_tool delta -
got="$(FAKE_ARCH=aarch64 FAKE_LATEST=0.20.1 run delta sudo install)"
case "$got" in *'delta'*'amd64'*rc=0*) pass ;; *) fail "arm: must say the asset is amd64-only and skip (got: $got)" ;; esac
[ ! -s "$tmp/curl.log" ] || fail "arm: must not download"

# J. an empty sudo (root) runs the commands bare
set_tool delta -
got="$(FAKE_LATEST=0.20.1 run delta '' install)"
grep -Eq '^dpkg -i ' "$tmp/tool.log" || fail "root: dpkg must run bare with an empty sudo (log: $(/bin/cat "$tmp/tool.log"))"
case "$got" in *rc=0*) pass ;; *) fail "root: did not complete (got: $got)" ;; esac

# K. wiring: the installer installs the three through the helper and the inline blocks are gone
for n in delta dust procs; do
    require "$tmpl" "github_tool_sync $n \"\$SUDO\" install"
done
forbid "$tmpl" 'api.github.com/repos/dandavison/delta'
forbid "$tmpl" 'api.github.com/repos/bootandy/dust'
forbid "$tmpl" 'api.github.com/repos/dalance/procs'
# ...and dot upgrade upgrades them on apt systems, before the closing note, which no longer
# tells the operator to re-run an installer that would do nothing
require "$du" 'github_tool_sync "$n" sudo upgrade'
forbid "$du" 're-run the installer (or bump its pin) for any that lags'

finish
