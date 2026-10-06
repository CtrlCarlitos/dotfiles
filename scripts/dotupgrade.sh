#!/bin/bash
# dot upgrade - the single owner of ALL tool upgrades.
# `dot up` NEVER upgrades; this script does, with live-session guards.
set -u

# --- Devcontainer: upgrades ship via image rebuild, never in-place. ---
# Same detection expression as .chezmoiignore.
if [ -n "${DEVCONTAINER:-}" ] || [ -n "${REMOTE_CONTAINERS:-}" ] || [ -e /.dockerenv ]; then
    echo "devcontainer detected: upgrades ship via image rebuild - skipping."
    exit 0
fi

# Where the time goes (scripts/lib/timing.sh): marks at each section, a summary at the end.
DOT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DOT_SCRIPT_DIR/lib/timing.sh"
. "$DOT_SCRIPT_DIR/lib/docker-vscode.sh"

echo "dot upgrade - sweeping all tooling..."
dot_timing_mark 'sessions and Codex daemon'

# --- Live-session scan: defer dir-recreating upgrades while agent hosts run. ---
# A name match is not always a session: Codex's shared app-server daemon runs its OWN
# release copy under ~/.codex/packages/app-server-daemon/, not the CLI the upgrade
# replaces, so it does not defer anything. Everything else counts.
live_pids() {
    local p pid args
    for p in "$@"; do
        for pid in $(pgrep -x "$p" 2>/dev/null); do
            args="$(ps -o args= -p "$pid" 2>/dev/null)"
            case "$p:$args" in
                codex:*"/.codex/packages/app-server-daemon/"*) continue ;;
            esac
            echo "$pid"
        done
    done
}
live() { [ -n "$(live_pids "$@")" ]; }

# --- Offer to stop the sessions that block an upgrade. ---
# Deferring is the safe default; on a terminal the operator is first asked whether to stop
# the blockers instead. The invoker's own ancestry (this shell, the terminal, the agent that
# launched `dot upgrade`) is never offered: stopping it would end this very command. Those
# still defer. DOTUPGRADE_NO_PROMPT=1 and a non-terminal both keep defer-and-report.
ancestor_pids() {
    local pid=$$
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        echo "$pid"
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    done
}
descendant_pids() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        descendant_pids "$child"
        echo "$child"
    done
}
is_interactive() { [ -t 0 ] && [ -t 1 ]; }
# TERM the whole tree (Serena leaves language-server children), give it five seconds, KILL
# whatever is left.
stop_pid_tree() {
    local pid="$1" tree
    tree="$(descendant_pids "$pid" | tr '\n' ' ') $pid"
    # shellcheck disable=SC2086  # word splitting of the pid list is the point
    kill -TERM $tree 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        # shellcheck disable=SC2086
        kill -0 $tree 2>/dev/null || return 0
        sleep 0.5
    done
    # shellcheck disable=SC2086
    kill -KILL $tree 2>/dev/null
    return 0
}
# A TUI agent that is ended never switches off what it turned on in its terminal (mouse
# reporting, bracketed paste, the kitty keyboard protocol); the terminal then keeps typing
# those reports into the prompt. After the stop, write the switch-offs to the agent's tty.
agent_tty() { ps -o tty= -p "$1" 2>/dev/null | tr -d ' '; }
reset_agent_terminal() {
    local tty="$1" dev
    case "$tty" in '' | '?' | '-') return 0 ;; esac
    dev="${DOT_TTY_ROOT:-/dev}/$tty"
    if [ -w "$dev" ]; then
        printf '\033[?1000l\033[?1002l\033[?1003l\033[?1004l\033[?1006l\033[?2004l\033[<99u\033[>4;0m\033[?1049l\033[?25h' >"$dev" 2>/dev/null || true
    fi
    return 0
}
describe_pid() { printf '%s (pid %s, up %s)' "$(ps -o comm= -p "$1" 2>/dev/null)" "$1" "$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')"; }
# Prints the number of sessions stopped. Nothing is stopped unless the operator says so.
stop_live_sessions() {
    local mine pids pid answer each stopped=0 chosen="" tty
    [ "${DOTUPGRADE_NO_PROMPT:-}" = 1 ] && { echo 0; return 0; }
    mine=" $(ancestor_pids | tr '\n' ' ')"
    pids=""
    for pid in $(live_pids "$@"); do
        case "$mine" in *" $pid "*) continue ;; esac
        pids="$pids $pid"
    done
    [ -n "$pids" ] || { echo 0; return 0; }
    is_interactive || { echo 0; return 0; }

    {
        echo "  These sessions block part of the upgrade:"
        for pid in $pids; do echo "    $(describe_pid "$pid")"; done
        echo "  Stopping one ends that session; unsaved context is lost unless it can be resumed."
        printf '  Stop them so everything upgrades now? [y] all  [s] choose each  [N] keep and defer: '
    } >&2
    # the time spent answering is "your answers" in the closing Timings line, not this section
    dot_timing_wait 2>/dev/null || true
    read -r answer || answer=""
    case "$answer" in
        [yY]) chosen="$pids" ;;
        [sS])
            for pid in $pids; do
                printf '    Stop %s? [y/N]: ' "$(describe_pid "$pid")" >&2
                read -r each || each=""
                case "$each" in [yY]) chosen="$chosen $pid" ;; esac
            done
            ;;
    esac
    dot_timing_resume 2>/dev/null || true
    for pid in $chosen; do
        tty="$(agent_tty "$pid")"
        stop_pid_tree "$pid"
        reset_agent_terminal "$tty"
        stopped=$((stopped + 1))
    done
    [ "$stopped" -gt 0 ] && echo "  Stopped $stopped process(es); re-scanning." >&2
    echo "$stopped"
}
stop_live_sessions opencode claude codex agy serena >/dev/null

# --- Codex's app-server daemon: not a session, but it keeps running the release it started
# with, so it stays behind the CLI after an upgrade. With no Codex session left, stop it; it
# restarts on demand, on the new version.
codex_daemon_pids() {
    local pid
    for pid in $(pgrep -x codex 2>/dev/null); do
        case "$(ps -o args= -p "$pid" 2>/dev/null)" in
            *"/.codex/packages/app-server-daemon/"*) echo "$pid" ;;
        esac
    done
}
stop_codex_daemon() {
    local pids pid
    pids="$(codex_daemon_pids)"
    [ -n "$pids" ] || return 0
    command -v codex >/dev/null 2>&1 && timeout 20 codex app-server daemon stop >/dev/null 2>&1
    # The polite stop did not take (or the CLI is too old to have it): the daemon is safe to end.
    for pid in $(codex_daemon_pids); do kill -TERM "$pid" 2>/dev/null; done
    echo "  Stopped Codex's app-server daemon (it restarts on demand, on the new version)."
}
live codex || stop_codex_daemon
DEFER=""
live codex && DEFER="codex"
live opencode claude codex agy && DEFER="${DEFER:+$DEFER,}graft"
live serena && DEFER="${DEFER:+$DEFER,}serena"
live opencode && DEFER="${DEFER:+$DEFER,}opencode"
export DOTUPGRADE_DEFER="$DEFER"
if [ -n "$DEFER" ]; then
    LIVE_NAMES="$(for p in opencode claude codex agy serena; do live "$p" && echo "$p"; done | sort -u | tr '\n' ' ')"
    echo "  Live agent session(s): ${LIVE_NAMES}- deferring: $DEFER"
else
    echo "  No live agent sessions - full sweep."
fi

dot_timing_mark 'system packages'
# --- 1. System packages: apt on Linux/WSL, brew on macOS. ---
# Docker (lib/docker-vscode.sh): an upgrade restarts Docker and stops every container, and a VS
# Code window attached to a dev container loses it. When a Docker upgrade is pending AND Docker
# is running, the operator is asked first; on yes VS Code is closed, then Docker stopped. Nothing
# below costs anything when Docker is not running (WSL: Docker Desktop and VS Code are Windows').
case "$(uname -s)" in
    Linux)
        if command -v apt-get &>/dev/null; then
            echo "  Upgrading apt packages..."
            if sudo apt-get update; then
                if dock_docker_running; then
                    dock_pending="$(dock_pending_linux | tr '\n' ' ')"
                    if [ -n "${dock_pending// /}" ] && ! dock_gate "${dock_pending% }"; then
                        # Kept running: hold the Docker packages out of THIS run (released at exit,
                        # and only the holds taken here), so nothing restarts Docker under you.
                        # shellcheck disable=SC2086  # the package list is word-split on purpose
                        dock_hold $dock_pending
                        trap dock_unhold EXIT
                        echo "  Docker packages held back for this run: ${dock_pending% }"
                    fi
                fi
                sudo apt-get upgrade -y
                dock_unhold
            fi
        else
            echo "  apt-get not found - skipping system packages."
        fi
        ;;
    Darwin)
        if command -v brew &>/dev/null; then
            echo "  Upgrading brew packages..."
            if brew update; then
                # The docker cask auto-updates itself, so a plain `brew upgrade` skips it: when it
                # is outdated and Docker is not running (or the operator agreed to the stop), take
                # it explicitly - dot upgrade is the one owner of upgrades.
                dock_cask_docker=0
                if [ -n "$(dock_pending_macos)" ] && dock_gate "Docker Desktop (brew cask)"; then dock_cask_docker=1; fi
                brew upgrade
                if [ "$dock_cask_docker" = 1 ]; then
                    brew upgrade --cask --greedy docker || echo "  Warning: the Docker Desktop cask upgrade failed - continuing."
                fi
            fi
        else
            echo "  brew not found - skipping system packages."
        fi
        ;;
esac

dot_timing_mark 'VS Code extensions'
# --- 1b. VS Code extensions: `dot up` only installs missing ones; updates are this command's
# job. Skipped quietly when VS Code is absent; a failure never aborts.
if command -v code &>/dev/null; then
    echo "  Updating VS Code extensions..."
    timeout 300 code --update-extensions >/dev/null 2>&1 || echo "  VS Code extension update did not finish cleanly - continuing."
fi

dot_timing_mark 'AI tools'
# --- 2. AI tools: the update_ai_tools section, defer-aware. ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/update_ai_tools.sh"

# --- Known outside-package-managers artifacts: no manager owns these, so
# the sweep above cannot upgrade them (Linux: direct .debs with no repo -
# Chrome, Docker Desktop, Termius, Handy, OpenCode Desktop, git-delta, dust,
# procs, neovim/lazygit/lychee/vale tarballs - plus the Antigravity 2.0 tar.gz; macOS:
# ScreenRec and Antigravity 2.0 .dmgs). Most self-update or are refreshable
# by re-running the installer; named here so the gap stays visible.
# Only what is actually installed here is named: WSL has none of the desktop apps (they live on
# Windows), and listing Docker Desktop there read as if WSL had a copy to keep current.
unmanaged_present() {
    local names=() n
    # delta, dust, procs: GitHub .debs with no repo; lychee, vale: pinned release tarballs
    if command -v google-chrome &>/dev/null; then names+=("Chrome"); fi
    if dpkg -s docker-desktop &>/dev/null || command -v docker-desktop &>/dev/null; then names+=("Docker Desktop"); fi
    if dpkg -s termius &>/dev/null || command -v termius &>/dev/null; then names+=("Termius"); fi
    if dpkg -s handy &>/dev/null; then names+=("Handy"); fi
    if dpkg -s opencode-desktop &>/dev/null || command -v opencode-desktop &>/dev/null; then names+=("OpenCode Desktop"); fi
    for n in delta dust procs lychee vale; do
        if command -v "$n" &>/dev/null; then names+=("$n"); fi
    done
    if [ -d "$HOME/.local/share/antigravity-2.0" ]; then names+=("Antigravity 2.0"); fi
    local IFS=','
    printf '%s' "${names[*]}" | sed 's/,/, /g'
}
case "$(uname -s)" in
    Linux)
        unmanaged="$(unmanaged_present)"
        if [ -n "$unmanaged" ]; then
            echo "  Note: outside package managers (no auto-upgrade): $unmanaged - re-run the installer or upgrade manually if any lags."
        fi
        ;;
    Darwin)
        echo "  Note: outside package managers (no auto-upgrade): ScreenRec, Antigravity 2.0 - re-run the installer or upgrade manually if any lags."
        ;;
esac

dot_timing_summary 'dot upgrade'
# --- Deferred report: what to re-run when quiet. ---
if [ -n "$DEFER" ]; then
    echo ""
    echo "Deferred (live sessions): $DEFER"
    echo "  Re-run 'dot upgrade' with those sessions closed to pick them up."
else
    echo "dot upgrade complete."
fi
