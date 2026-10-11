#!/usr/bin/env bash
set -euo pipefail

# vscode_wsl_server_fetch [retry-hint] (scripts/lib/vscode-wsl.sh), shared by `dot up` (the
# installer template inlines the lib) and `dot upgrade` (sources it). EXECUTED against fixture
# launchers.
#
# On WSL there is no Linux VS Code: `code` is the Windows client's bin/code reached through
# interop, and every CLI call goes through Remote-WSL, which first installs the VS Code SERVER
# for the client's commit under ~/.vscode-server/bin when it is not there (after every VS Code
# update on Windows). A WSL `dot up` (2026-10-11) sat 22 minutes on "Installing VS Code
# extensions" with nothing on screen: `code --list-extensions` was downloading 200+ MB inside
# $(...) with stderr to /dev/null. The extensions DO belong on the WSL side (all 24 curated ones
# were there), so the step stays; the contract is about the fetch:
#   - when `code` is the Windows launcher (it carries COMMIT=, SERVERDATAFOLDER= and the WSL
#     branch) and the server for COMMIT is missing, say so and run one `code --version` in the
#     foreground, so Remote-WSL's own progress is visible; return 0 - the extension step follows
#   - server present, a native Linux `code`, or no `code` at all: no call, no output, return 0
#   - a failed fetch warns with the caller's retry hint and returns 1, so the caller skips the
#     extension step this run instead of retrying the download silently
#   - the fetch is its own timing section ("VS Code server fetch"), not booked as "VS Code"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
lib="$repo_root/scripts/lib/vscode-wsl.sh"
tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"
du="$repo_root/scripts/dotupgrade.sh"

[ -f "$lib" ] || { fail "scripts/lib/vscode-wsl.sh is missing"; finish; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
commit=0123456789abcdef0123456789abcdef01234567

# The Windows client's launcher as WSL sees it (resources/win32/bin/code.sh): a sh script with
# COMMIT=, SERVERDATAFOLDER= and the WSL_DISTRO_NAME branch. The fixture "installs the server"
# with a mkdir and prints the notice wslDownload.sh prints.
mkdir -p "$tmp/wsl-bin" "$tmp/linux-bin" "$tmp/empty-bin"
cat >"$tmp/wsl-bin/code" <<EOF2
#!/bin/sh
COMMIT="$commit"
APP_NAME="code"
QUALITY="stable"
SERVERDATAFOLDER=".vscode-server"
IN_WSL=false
if [ -n "\$WSL_DISTRO_NAME" ]; then IN_WSL=true; fi
printf '%s\n' "\$*" >>"\${CODE_LOG:?}"
if [ "\${CODE_MODE:-ok}" = fail ]; then echo "ERROR: Failed to download the VS Code server" >&2; exit 13; fi
if [ ! -d "\$HOME/.vscode-server/bin/\$COMMIT" ]; then
    echo "Installing VS Code Server for Linux x64 (\$COMMIT)"
    mkdir -p "\$HOME/.vscode-server/bin/\$COMMIT"
fi
echo 1.100.0; echo "\$COMMIT"; echo x64
EOF2
# a native Linux launcher: no WSL branch, no server
cat >"$tmp/linux-bin/code" <<'EOF2'
#!/bin/sh
printf '%s\n' "$*" >>"${CODE_LOG:?}"
echo 1.100.0
EOF2
chmod +x "$tmp/wsl-bin/code" "$tmp/linux-bin/code"

# run <home> <bindir> [args...]: the helper under the libs both consumers load; prints output + rc.
# PATH is controlled: on a WSL host the real Windows launcher sits on PATH via /mnt/c.
run() {
    local home="$1" bin="$2"; shift 2
    HOME="$home" PATH="$bin:/usr/bin:/bin" CODE_LOG="$tmp/code.log" \
        bash -c 'set -euo pipefail; . "$1"; . "$2"; . "$3"; shift 3; rc=0; vscode_wsl_server_fetch "$@" || rc=$?; echo rc=$rc' \
        _ "$repo_root/scripts/lib/agent-skills.sh" "$repo_root/scripts/lib/timing.sh" "$lib" "$@" 2>&1
}

# A. Windows launcher, server missing: announced, one foreground `code --version`, progress visible.
h="$tmp/a"; mkdir -p "$h"; : >"$tmp/code.log"
got="$(run "$h" "$tmp/wsl-bin" 'dot upgrade')"
case "$got" in *'VS Code'*server*rc=0*) pass ;; *) fail "missing server: must announce the fetch and return 0 (output: $got)" ;; esac
case "$got" in *'Installing VS Code Server for Linux x64'*) pass ;; *) fail "missing server: Remote-WSL's own progress must reach the terminal (output: $got)" ;; esac
grep -Fxq -- '--version' "$tmp/code.log" || fail "missing server: the fetch must be one \`code --version\` (code saw: $(/bin/cat "$tmp/code.log"))"
[ "$(grep -c . "$tmp/code.log")" = 1 ] || fail "missing server: exactly one call (code saw: $(/bin/cat "$tmp/code.log"))"
[ -d "$h/.vscode-server/bin/$commit" ] || fail "missing server: the fixture's server folder must exist afterwards"

# B. Windows launcher, server present: nothing to do, nothing said.
: >"$tmp/code.log"
got="$(run "$h" "$tmp/wsl-bin")"
[ "$got" = "rc=0" ] || fail "server present: must be silent and return 0 (output: $got)"
[ ! -s "$tmp/code.log" ] || fail "server present: must not call code (code saw: $(/bin/cat "$tmp/code.log"))"

# C. The fetch fails: warned with the caller's hint, return 1 (the caller skips the step).
h="$tmp/c"; mkdir -p "$h"; : >"$tmp/code.log"
got="$(CODE_MODE=fail run "$h" "$tmp/wsl-bin" 're-run dot upgrade')"
case "$got" in *'VS Code server fetch failed'*'re-run dot upgrade'*rc=1*) pass ;; *) fail "failed fetch: must warn with the hint and return 1 (output: $got)" ;; esac

# D. A native Linux `code`: not the Windows launcher - no call, no output.
h="$tmp/d"; mkdir -p "$h"; : >"$tmp/code.log"
got="$(run "$h" "$tmp/linux-bin")"
[ "$got" = "rc=0" ] || fail "native code: must be silent and return 0 (output: $got)"
[ ! -s "$tmp/code.log" ] || fail "native code: must not call code (code saw: $(/bin/cat "$tmp/code.log"))"

# E. No `code` at all.
got="$(run "$h" "$tmp/empty-bin")"
[ "$got" = "rc=0" ] || fail "no code: must be silent and return 0 (output: $got)"

# F. Its own timing section, and the interrupted one resumes.
h="$tmp/f"; mkdir -p "$h"; : >"$tmp/code.log"
got="$(HOME="$h" PATH="$tmp/wsl-bin:/usr/bin:/bin" CODE_LOG="$tmp/code.log" DOT_TIMING_MIN_SECONDS=0 \
    bash -c 'set -euo pipefail; . "$1"; . "$2"; . "$3"; dot_timing_mark "VS Code"; vscode_wsl_server_fetch >/dev/null 2>&1; echo "LAST=$DOT_TIMING_LAST"; dot_timing_summary t' \
    _ "$repo_root/scripts/lib/agent-skills.sh" "$repo_root/scripts/lib/timing.sh" "$lib" 2>&1)"
case "$got" in *'VS Code server fetch'*) pass ;; *) fail "timing: the fetch must be its own section (output: $got)" ;; esac
case "$got" in *'LAST=VS Code'*) pass ;; *) fail "timing: the interrupted section must resume (output: $got)" ;; esac

# G. Wiring: both consumers load the lib and fetch BEFORE their first `code` call.
require "$tmpl" '{{ include "scripts/lib/vscode-wsl.sh" }}'
awk '/vscode_wsl_server_fetch/ {a=NR} /code --list-extensions/ {b=NR} END {exit !(a && b && a<b)}' "$tmpl" ||
    fail "installer: vscode_wsl_server_fetch must run before code --list-extensions"
require "$du" 'lib/vscode-wsl.sh'
awk '/vscode_wsl_server_fetch/ {a=NR} /code --update-extensions/ {b=NR} END {exit !(a && b && a<b)}' "$du" ||
    fail "dotupgrade.sh: vscode_wsl_server_fetch must run before code --update-extensions"

# H. The extension step itself stays on WSL and on native Linux (the extensions belong on both).
for platform in wsl sh; do
    render_to "$tmp/$platform.sh" "$platform" '{"vscode_settings": true, "core": true}'
    require "$tmp/$platform.sh" 'code --list-extensions'
    require "$tmp/$platform.sh" 'code --install-extension'
    require "$tmp/$platform.sh" 'vscode_wsl_server_fetch'
done

finish
