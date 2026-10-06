#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2034  # functions defined for the snippets below; vars read by them
set -euo pipefail

# Linux and macOS twin of the Windows rule (dotupgrade_docker_winget_contract.sh): a Docker
# upgrade restarts Docker and stops every container, and a VS Code window attached to a dev
# container loses it. When an upgrade is PENDING and Docker is RUNNING, `dot upgrade` asks first;
# on yes it closes VS Code, then stops Docker; on no it keeps Docker out of the run (Linux: an
# apt-mark hold, always undone and never a hold the operator already had; macOS: no cask
# upgrade). A VS Code that hosts this terminal is never closed. Nothing is touched without a yes.
#
# Needs real processes (pgrep -f, kill): throwaway `sleep`s started with VS Code / Docker
# shaped command lines, plus fake docker / osascript / brew / apt-get / apt-mark / sudo binaries
# that log what they were asked. Linux only (CI Linux and WSL); Git Bash cannot do it.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

case "${OSTYPE:-}" in msys* | cygwin* | win32) skip 'needs a Linux userland (pgrep -f / exec -a)' ;; esac
command -v pgrep >/dev/null 2>&1 || skip 'pgrep not installed'

tmp="$(mktemp -d)"
spawned=()
cleanup() {
    local p
    for p in ${spawned[@]+"${spawned[@]}"}; do kill -KILL "$p" 2>/dev/null || true; done
    rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin"
export PATH="$tmp/bin:$PATH"
export CALLS="$tmp/calls"

# --- fake binaries ----------------------------------------------------------------------------------
cat >"$tmp/bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
# `docker desktop stop`: record how many VS Code processes were still alive (they must be gone
# BEFORE Docker is stopped), then stop the fake Docker Desktop unless it is set to be stubborn
if [ "$1 $2" = "desktop stop" ]; then
    echo "docker-stop vscode_alive=$(pgrep -fc "$FAKE_VSCODE_PAT" || true)" >>"$CALLS"
    [ "${FAKE_DOCKER_STUBBORN:-0}" = 1 ] || pkill -f "$FAKE_DESKTOP_PAT" || true
fi
exit 0
EOF
cat >"$tmp/bin/osascript" <<'EOF'
#!/bin/sh
echo "osascript $*" >>"$CALLS"
case "$*" in
    *'"Visual Studio Code"'*) pkill -f "$FAKE_VSCODE_PAT" || true ;;
    *'quit app "Docker"'*) pkill -f "$FAKE_DESKTOP_PAT" || true ;;
esac
exit 0
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >>"$CALLS"
pkill -f "$FAKE_DESKTOP_PAT" || true
exit 0
EOF
cat >"$tmp/bin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >>"$CALLS"
if [ "$1 $2" = "-s upgrade" ]; then
    printf '%s\n' 'Inst git [1:2.43] (1:2.44 Ubuntu)' 'Inst docker-ce [5:27] (5:28 Docker)' 'Inst containerd.io [1.7] (1.8 Docker)' 'Inst docker-ce-rootless-extras [5:27] (5:28 Docker)' 'Conf git (1:2.44 Ubuntu)'
fi
exit 0
EOF
cat >"$tmp/bin/apt-mark" <<'EOF'
#!/bin/sh
echo "apt-mark $*" >>"$CALLS"
[ "$1" = showhold ] && printf '%s' "${FAKE_HELD:-}"
exit 0
EOF
cat >"$tmp/bin/brew" <<'EOF'
#!/bin/sh
echo "brew $*" >>"$CALLS"
if [ "$1 $2" = "outdated --cask" ] && [ "${FAKE_CASK_OUTDATED:-0}" = 1 ]; then echo docker; fi
exit 0
EOF
chmod +x "$tmp/bin/"*

# throwaway processes whose command line looks like VS Code / Docker Desktop (argv0 is spoofed)
spawn() { # $1 = argv0, $2 = "ignoreterm" to ignore TERM; prints the pid
    if [ "${2:-}" = ignoreterm ]; then
        bash -c 'trap "" TERM; exec -a "$1" sleep 300' _ "$1" >/dev/null 2>&1 &
    else
        bash -c 'exec -a "$1" sleep 300' _ "$1" >/dev/null 2>&1 &
    fi
    spawned+=("$!")
    echo "$!"
}
alive() { kill -0 "$1" 2>/dev/null; }
settle() { sleep 0.3; }

# patterns the fakes use to find "their" processes
export FAKE_VSCODE_PAT='/fake/usr/share/code/'
export FAKE_DESKTOP_PAT='/fake/opt/docker-desktop/'
mkdir -p "$tmp/dockerd-bin"
cp "$(command -v sleep)" "$tmp/dockerd-bin/dockerd"

# run <body>: the library, the test hooks, then the body; stdin is the operator's answer.
# Prints the body's output; the calls the fakes recorded are in $tmp/calls.
run() {
    {
        printf '%s\n' 'set -u' ". \"$repo_root/scripts/lib/docker-vscode.sh\""
        printf '%s\n' 'dock_os() { echo "${FAKE_OS:-Linux}"; }'
        printf '%s\n' 'dock_is_interactive() { [ "${FAKE_TTY:-1}" = 1 ]; }'
        printf '%s\n' 'dock_exclude_pids() { echo $$; for p in ${FAKE_ANCESTORS:-}; do echo "$p"; done; }'
        printf '%s\n' 'DOCK_GRACE_SECONDS=2'
        printf '%s\n' "$1"
    } >"$tmp/snippet.sh"
    : >"$tmp/calls"
    bash "$tmp/snippet.sh" 2>"$tmp/stderr"
}
# Pattern matching: the library's own patterns look for /usr/share/code/ and /opt/docker-desktop/,
# which the fake argv0s contain as substrings (/fake/usr/share/code/..., /fake/opt/docker-desktop/...).

# =========================== Linux: pending detection ====================================
out="$(run 'dock_pending_linux')"
[ "$out" = "$(printf 'docker-ce\ncontainerd.io')" ] || fail "Linux: only Docker's own packages count as pending (got: $(printf '%s' "$out" | tr '\n' '|'))"
pass

# =========================== Linux: accepted -> VS Code first, then Docker ==============
v1="$(spawn /fake/usr/share/code/code)"; v2="$(spawn /fake/usr/share/code/code)"; d1="$(spawn /fake/opt/docker-desktop/bin/com.docker.backend)"
settle
printf 'y\n' | run 'dock_gate "docker-ce"; echo "rc=$?"' >"$tmp/out" || true
settle
grep -Fxq 'rc=0' "$tmp/out" || fail "Linux accept: the gate must return 0 (got: $(cat "$tmp/out"))"
if alive "$v1" || alive "$v2"; then fail "Linux accept: VS Code must be closed"; fi
if alive "$d1"; then fail "Linux accept: Docker Desktop must be stopped"; fi
grep -Fxq 'docker-stop vscode_alive=0' "$tmp/calls" || fail "Linux accept: VS Code must be gone BEFORE Docker is stopped (calls: $(tr '\n' '|' <"$tmp/calls"))"
grep -Fq 'VS Code is running (2 process(es))' "$tmp/stderr" || fail "Linux accept: the prompt must say VS Code will be closed first (got: $(cat "$tmp/stderr"))"
pass

# =========================== Linux: declined -> everything stays, packages held then released ==
v1="$(spawn /fake/usr/share/code/code)"; d1="$(spawn /fake/opt/docker-desktop/bin/com.docker.backend)"
settle
printf 'n\n' | run 'dock_gate "docker-ce"; echo "rc=$?"' >"$tmp/out" || true
grep -Fxq 'rc=1' "$tmp/out" || fail "Linux decline: the gate must return 1 (got: $(cat "$tmp/out"))"
if ! alive "$v1" || ! alive "$d1"; then fail "Linux decline: nothing may be stopped"; fi
FAKE_HELD='docker-ce-cli' run 'dock_hold docker-ce docker-ce-cli containerd.io; echo "held: ${DOCK_HELD[*]}"; dock_unhold; echo "after: ${#DOCK_HELD[@]}"' >"$tmp/out" || true
grep -Fxq 'held: docker-ce containerd.io' "$tmp/out" || fail "Linux hold: only packages the operator had not already held (got: $(cat "$tmp/out"))"
if ! grep -Fxq 'apt-mark hold docker-ce' "$tmp/calls" || ! grep -Fxq 'apt-mark unhold docker-ce' "$tmp/calls"; then fail "Linux hold: hold then unhold what was taken"; fi
if grep -Fq 'apt-mark hold docker-ce-cli' "$tmp/calls" || grep -Fq 'apt-mark unhold docker-ce-cli' "$tmp/calls"; then fail "Linux hold: a hold the operator already had must never be touched"; fi
grep -Fxq 'after: 0' "$tmp/out" || fail "Linux hold: the held list must be empty after unhold"
pass

# =========================== Linux: no terminal, NO_PROMPT, default answer ===============
printf '' | FAKE_TTY=0 run 'dock_gate "docker-ce"; echo "rc=$?"' >"$tmp/out" || true
grep -Fxq 'rc=1' "$tmp/out" || fail "no terminal: Docker must be left alone (got: $(cat "$tmp/out"))"
printf 'y\n' | DOTUPGRADE_NO_PROMPT=1 run 'dock_gate "docker-ce"; echo "rc=$?"' >"$tmp/out" || true
grep -Fxq 'rc=1' "$tmp/out" || fail "DOTUPGRADE_NO_PROMPT=1: Docker must be left alone even if a y is piped in"
printf '\n' | run 'dock_gate "docker-ce"; echo "rc=$?"' >"$tmp/out" || true
grep -Fxq 'rc=1' "$tmp/out" || fail "the default answer is no"
if ! alive "$v1" || ! alive "$d1"; then fail "none of the no-answers may stop anything"; fi
pass

# =========================== Linux: Docker not running -> nothing is even looked at ========
kill "$v1" "$d1" 2>/dev/null || true; settle
out="$(run 'dock_gate "docker-ce"; echo "rc=$?"')"
[ "$out" = "rc=0" ] || fail "Docker not running: the gate must return 0 at once (got: $out)"
if grep -Fq 'apt-get -s upgrade' "$tmp/calls"; then fail "Docker not running: no apt simulation is needed"; fi
pass

# =========================== Linux: VS Code that hosts this terminal is not closed ========
v1="$(spawn /fake/usr/share/code/code)"; v2="$(spawn /fake/usr/share/code/code)"; d1="$(spawn /fake/opt/docker-desktop/bin/com.docker.backend)"
settle
printf 'y\n' | FAKE_ANCESTORS="$v1" run 'dock_gate "docker-ce"; echo "rc=$?"' >"$tmp/out" || true
settle
grep -Fxq 'rc=0' "$tmp/out" || fail "hosting: the gate still proceeds (got: $(cat "$tmp/out"))"
if ! alive "$v1"; then fail "hosting: the VS Code in this shell's ancestry must NOT be closed"; fi
if alive "$v2"; then fail "hosting: the other VS Code process is closed"; fi
grep -Fq 'hosts THIS terminal' "$tmp/stderr" || fail "hosting: the prompt must warn that VS Code hosts this terminal"
kill "$v1" 2>/dev/null || true
pass

# =========================== Linux: a VS Code that ignores TERM is killed after the grace ====
v1="$(spawn /fake/usr/share/code/code ignoreterm)"; d1="$(spawn /fake/opt/docker-desktop/bin/com.docker.backend)"
settle
printf 'y\n' | run 'dock_gate "docker-ce"; echo "rc=$?"' >"$tmp/out" || true
settle
grep -Fxq 'rc=0' "$tmp/out" || fail "stubborn VS Code: the gate returns 0 (got: $(cat "$tmp/out"))"
if alive "$v1"; then fail "stubborn VS Code: killed after the grace period"; fi
grep -Fxq 'docker-stop vscode_alive=0' "$tmp/calls" || fail "stubborn VS Code: still gone before Docker is stopped"
pass

# =========================== Linux: stubborn Docker Desktop falls back, then is ended ======
d1="$(spawn /fake/opt/docker-desktop/bin/com.docker.backend)"
settle
printf 'y\n' | FAKE_DOCKER_STUBBORN=1 run 'dock_gate "docker-ce"; echo "rc=$?"' >"$tmp/out" || true
settle
grep -Fxq 'rc=0' "$tmp/out" || fail "stubborn Docker: ended in the end (got: $(cat "$tmp/out"))"
if alive "$d1"; then fail "stubborn Docker Desktop must be ended"; fi
grep -Fq 'systemctl --user stop docker-desktop' "$tmp/calls" || fail "stubborn Docker: the platform's own stop is tried before the processes"
pass

# =========================== Linux: engine only (no Desktop): VS Code closed, engine untouched ===
e1="$("$tmp/dockerd-bin/dockerd" 300 >/dev/null 2>&1 & echo $!)"; spawned+=("$e1")
v1="$(spawn /fake/usr/share/code/code)"
settle
printf 'y\n' | run 'dock_gate "docker-ce"; echo "rc=$?"' >"$tmp/out" || true
settle
grep -Fxq 'rc=0' "$tmp/out" || fail "engine only: the gate proceeds (got: $(cat "$tmp/out"))"
if alive "$v1"; then fail "engine only: VS Code is still closed first"; fi
if ! alive "$e1"; then fail "engine only: the package upgrade restarts the engine itself; it is not stopped here"; fi
if grep -Fq 'docker-stop' "$tmp/calls"; then fail "engine only: no Docker Desktop to stop"; fi
kill "$e1" 2>/dev/null || true
pass

# =========================== macOS ===============================================================
out="$(FAKE_CASK_OUTDATED=1 run 'dock_pending_macos')"
[ "$out" = docker ] || fail "macOS: an outdated docker cask is pending (got: $out)"
out="$(FAKE_CASK_OUTDATED=0 run 'dock_pending_macos')"
[ -z "$out" ] || fail "macOS: an up-to-date cask is not pending (got: $out)"
grep -Fxq 'brew outdated --cask --greedy --quiet docker' "$tmp/calls" || fail "macOS: the cask auto-updates itself, so the check must be --greedy (calls: $(tr '\n' '|' <"$tmp/calls"))"

v1="$(spawn '/fake/Applications/Visual Studio Code.app/Contents/MacOS/Electron')"
d1="$(spawn /fake/Applications/Docker.app/Contents/MacOS/com.docker.backend)"
settle
export FAKE_VSCODE_PAT='Visual Studio Code.app/Contents' FAKE_DESKTOP_PAT='Docker.app/Contents'
printf 'y\n' | FAKE_OS=Darwin run 'dock_gate "Docker Desktop (brew cask)"; echo "rc=$?"' >"$tmp/out" || true
settle
grep -Fxq 'rc=0' "$tmp/out" || fail "macOS accept: the gate returns 0 (got: $(cat "$tmp/out"))"
if alive "$v1"; then fail "macOS accept: VS Code is quit"; fi
if alive "$d1"; then fail "macOS accept: Docker Desktop is stopped"; fi
grep -Fq 'osascript -e tell application "Visual Studio Code" to quit' "$tmp/calls" || fail "macOS accept: VS Code gets a normal quit, not a kill"
grep -Fxq 'docker-stop vscode_alive=0' "$tmp/calls" || fail "macOS accept: VS Code is gone before Docker is stopped"
v1="$(spawn '/fake/Applications/Visual Studio Code.app/Contents/MacOS/Electron')"
d1="$(spawn /fake/Applications/Docker.app/Contents/MacOS/com.docker.backend)"
settle
printf 'n\n' | FAKE_OS=Darwin run 'dock_gate "Docker Desktop (brew cask)"; echo "rc=$?"' >"$tmp/out" || true
grep -Fxq 'rc=1' "$tmp/out" || fail "macOS decline: the gate returns 1"
if ! alive "$v1" || ! alive "$d1"; then fail "macOS decline: nothing is stopped"; fi
pass

# =========================== wiring in dotupgrade.sh ==============================================
du="$repo_root/scripts/dotupgrade.sh"
grep -Fq 'lib/docker-vscode.sh' "$du" || fail "dotupgrade.sh must source lib/docker-vscode.sh"
# Linux: the pending check happens AFTER `apt-get update` and BEFORE `apt-get upgrade`, a decline
# holds the packages, and the hold is always released
upd="$(grep -n 'sudo apt-get update' "$du" | head -1 | cut -d: -f1)"
gate="$(grep -n 'dock_gate "${dock_pending% }"' "$du" | head -1 | cut -d: -f1)"
upg="$(grep -n 'sudo apt-get upgrade -y' "$du" | head -1 | cut -d: -f1)"
if [ -z "$upd" ] || [ -z "$gate" ] || [ -z "$upg" ] || [ "$upd" -ge "$gate" ] || [ "$gate" -ge "$upg" ]; then
    fail "dotupgrade.sh: the Docker gate must sit between apt-get update and apt-get upgrade"
fi
grep -Fq 'trap dock_unhold EXIT' "$du" || fail "dotupgrade.sh: held packages must be released at exit"
# macOS: the cask is upgraded explicitly (--greedy) only after the gate says yes
grep -Fq 'brew upgrade --cask --greedy docker' "$du" || fail "dotupgrade.sh: macOS must upgrade the docker cask explicitly after the gate"
pass

finish
