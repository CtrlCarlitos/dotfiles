#!/usr/bin/env bash
# scripts/lib/docker-vscode.sh - stop Docker and VS Code cleanly before `dot upgrade` upgrades
# Docker on Linux and macOS. Shell twin of Get-DockerDesktopUpgrade / Invoke-DockerDesktopStopOffer
# / Stop-VsCode in scripts/lib/ps-common.ps1; sourced by scripts/dotupgrade.sh. Template-free bash.
#
# Why: a VS Code window attached to a dev container loses it the moment Docker stops or restarts,
# and an upgrade that stops Docker takes every running container with it. So when a Docker upgrade
# is PENDING and Docker is RUNNING, the operator is asked (same rules as agent sessions: never
# without a yes, never with DOTUPGRADE_NO_PROMPT=1 or without a terminal) and, on yes, VS Code is
# closed first, then Docker. It is not reopened. A VS Code that hosts the terminal running
# dot upgrade is never closed (that would end the command).
#
# What counts as "a Docker upgrade is pending":
#   macOS  the `docker` cask is outdated (`brew outdated --cask --greedy`; the cask auto-updates
#          itself, so a plain `brew upgrade` skips it - the caller upgrades it explicitly when the
#          operator agreed to the stop).
#   Linux  `apt-get -s upgrade` lists a Docker package (docker-ce, docker-ce-cli, containerd.io,
#          docker-desktop, the compose/buildx plugins). Declining holds exactly those packages for
#          this run (apt-mark hold, always undone, and never a hold the operator already had).
# WSL runs neither: Docker Desktop and VS Code live on Windows there, and the Windows dot upgrade
# handles both. Nothing here is ever reached unless Docker is running, so those cost nothing.
#
# Overridable for tests: dock_os, dock_is_interactive, dock_native_engine_running, dock_exclude_pids; DOCK_GRACE_SECONDS.

DOCK_PKG_REGEX='docker-ce|docker-ce-cli|containerd\.io|docker-desktop|docker-compose-plugin|docker-buildx-plugin'
DOCK_VSCODE_LINUX='/usr/share/code/|/usr/share/code-insiders/|/opt/visual-studio-code|/snap/code/|/usr/lib/code/'
DOCK_VSCODE_MAC='/Visual Studio Code( - Insiders)?\.app/Contents/'
DOCK_DESKTOP_LINUX='/opt/docker-desktop/'
DOCK_DESKTOP_MAC='/Docker\.app/Contents/'
DOCK_HELD=()

dock_os() { uname -s; }
dock_is_interactive() { [ -t 0 ] && [ -t 1 ]; }
dock_native_engine_running() { pgrep -x dockerd >/dev/null 2>&1; }

# The invoker's own ancestry (this shell, the terminal, an integrated terminal's VS Code): never
# offered for closing, since stopping it would end this very command.
dock_exclude_pids() {
    local pid=$$
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        echo "$pid"
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    done
}

_dock_pgrep() { pgrep -f -- "$1" 2>/dev/null || true; }

dock_vscode_pattern() { if [ "$(dock_os)" = Darwin ]; then echo "$DOCK_VSCODE_MAC"; else echo "$DOCK_VSCODE_LINUX"; fi; }
dock_desktop_pattern() { if [ "$(dock_os)" = Darwin ]; then echo "$DOCK_DESKTOP_MAC"; else echo "$DOCK_DESKTOP_LINUX"; fi; }

# pids of VS Code, one per line
dock_vscode_pids() { _dock_pgrep "$(dock_vscode_pattern)"; }

# pids of VS Code that may be closed: not in the invoker's ancestry
dock_vscode_closable_pids() {
    local mine pid
    mine=" $(dock_exclude_pids | tr '\n' ' ')"
    for pid in $(dock_vscode_pids); do
        case "$mine" in *" $pid "*) continue ;; esac
        echo "$pid"
    done
}

dock_desktop_pids() { _dock_pgrep "$(dock_desktop_pattern)"; }

# 0 when Docker is running here: Docker Desktop, or on Linux a native engine
dock_docker_running() {
    [ -n "$(dock_desktop_pids)" ] && return 0
    if [ "$(dock_os)" != Darwin ] && dock_native_engine_running; then return 0; fi
    return 1
}

# Docker packages with an upgrade pending (Linux): one name per line, empty when none.
dock_pending_linux() {
    command -v apt-get >/dev/null 2>&1 || return 0
    apt-get -s upgrade 2>/dev/null | awk '/^Inst / { print $2 }' | grep -E "^($DOCK_PKG_REGEX)\$" || true
}

# "docker" when the cask is outdated (macOS), empty otherwise. --greedy: the cask auto-updates itself.
dock_pending_macos() {
    command -v brew >/dev/null 2>&1 || return 0
    brew outdated --cask --greedy --quiet docker 2>/dev/null | grep -Fx docker || true
}

_dock_wait_gone() { # $1 = seconds, rest = pids; 0 when none is left
    local secs="$1" pid left; shift
    local deadline=$((SECONDS + secs))
    while :; do
        left=0
        for pid in "$@"; do kill -0 "$pid" 2>/dev/null && left=1; done
        [ "$left" = 0 ] && return 0
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 1
    done
}

# Close VS Code: a normal quit where the OS has one (macOS), a TERM otherwise, then wait; whatever
# is still there after the grace period is killed. 0 when nothing is left.
dock_stop_vscode() {
    local pids=("$@") grace="${DOCK_GRACE_SECONDS:-20}" pid
    [ "${#pids[@]}" -gt 0 ] || return 0
    if [ "$(dock_os)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
        osascript -e 'tell application "Visual Studio Code" to quit' >/dev/null 2>&1 || true
        osascript -e 'tell application "Visual Studio Code - Insiders" to quit' >/dev/null 2>&1 || true
    else
        kill -TERM "${pids[@]}" 2>/dev/null || true
    fi
    _dock_wait_gone "$grace" "${pids[@]}" && return 0
    for pid in "${pids[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
    _dock_wait_gone 3 "${pids[@]}"
}

# Stop Docker: `docker desktop stop` (stops the engine and the app), then the platform's own way,
# then the processes. A native engine alone is not stopped here: its package upgrade restarts it.
dock_stop_docker() {
    local grace="${DOCK_GRACE_SECONDS:-20}" pids
    pids="$(dock_desktop_pids)"
    [ -n "$pids" ] || return 0
    if command -v docker >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then timeout 90 docker desktop stop >/dev/null 2>&1 || true
        else docker desktop stop >/dev/null 2>&1 || true; fi
    fi
    # shellcheck disable=SC2086  # the pid list is the point
    _dock_wait_gone "$grace" $pids && return 0
    if [ "$(dock_os)" = Darwin ]; then
        if command -v osascript >/dev/null 2>&1; then osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true; fi
    else
        systemctl --user stop docker-desktop >/dev/null 2>&1 || true
    fi
    pids="$(dock_desktop_pids)"
    [ -n "$pids" ] || return 0
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    # shellcheck disable=SC2086
    _dock_wait_gone 5 $pids && return 0
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || true
    [ -z "$(dock_desktop_pids)" ]
}

# Hold the given packages for this run, but only the ones the operator has not held already, so
# dock_unhold can never release somebody else's hold.
dock_hold() {
    local already p
    already="$(apt-mark showhold 2>/dev/null || true)"
    for p in "$@"; do
        if printf '%s\n' "$already" | grep -Fxq "$p"; then continue; fi
        if sudo apt-mark hold "$p" >/dev/null 2>&1; then DOCK_HELD+=("$p"); fi
    done
}
dock_unhold() {
    local p
    for p in ${DOCK_HELD[@]+"${DOCK_HELD[@]}"}; do sudo apt-mark unhold "$p" >/dev/null 2>&1 || true; done
    DOCK_HELD=()
}

# The offer. $1 = what is pending (printed).
# Returns 0 when the upgrade may go ahead (Docker is not running, or was stopped),
# 1 when Docker was kept running. Nothing is stopped unless the operator answers y.
dock_gate() {
    local pending="$1" answer closable vs_all hosts=0
    dock_docker_running || return 0
    if [ "${DOTUPGRADE_NO_PROMPT:-}" = 1 ] || ! dock_is_interactive; then
        echo "  Docker upgrade pending ($pending) but Docker is running: left for the next run (it would stop your containers)."
        return 1
    fi
    closable="$(dock_vscode_closable_pids | tr '\n' ' ')"
    vs_all="$(dock_vscode_pids | tr '\n' ' ')"
    # a VS Code that is only in the invoker's ancestry
    if [ -n "${vs_all// /}" ] && [ -z "${closable// /}" ]; then hosts=1; fi
    if [ -n "${closable// /}" ] && [ "$(wc -w <<<"$vs_all")" -gt "$(wc -w <<<"$closable")" ]; then hosts=1; fi
    {
        echo "  A Docker upgrade is pending ($pending), and Docker is running."
        echo "  Upgrading restarts Docker and stops every running container; they are not restarted afterwards."
        if [ -n "${closable// /}" ]; then
            echo "  VS Code is running ($(wc -w <<<"$closable") process(es)) and may be attached to a container: it will be closed first, so nothing disconnects under an open editor."
        fi
        if [ "$hosts" = 1 ]; then
            echo "  VS Code also hosts THIS terminal, so it is not closed: any of its windows attached to a container will disconnect. Run dot upgrade from another terminal to avoid that."
        fi
        printf '  Stop Docker so it can upgrade now? [y/N]%s: ' "$(dot_ask_hint 2>/dev/null || true)"
    } >&2
    dot_timing_wait 2>/dev/null || true
    if declare -F dot_ask >/dev/null; then dot_ask answer; else read -r answer || answer=""; fi
    dot_timing_resume 2>/dev/null || true
    case "$answer" in
        [yY]) ;;
        *)
            echo "  Docker left running; its upgrade waits for the next run." >&2
            return 1
            ;;
    esac
    if [ -n "${closable// /}" ]; then
        # shellcheck disable=SC2086
        if dock_stop_vscode $closable; then
            echo "  VS Code closed; reopen it when you need it (a dev container reconnects once Docker is up)." >&2
        else
            echo "  Warning: VS Code did not close - continuing; windows attached to a container will disconnect." >&2
        fi
    fi
    if [ -n "$(dock_desktop_pids)" ]; then
        if dock_stop_docker; then
            echo "  Docker Desktop stopped for the upgrade; start it again when you need it." >&2
        else
            echo "  Warning: Docker Desktop did not stop - its upgrade is left for the next run." >&2
            return 1
        fi
    fi
    return 0
}
