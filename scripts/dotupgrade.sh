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

# dot upgrade --yes: answer "yes" to its questions up front (stop the sessions and desktop
# apps; stop Docker for its upgrade), for a run nobody stays to watch. Without it each
# question takes its safe default ("no") after DOTUPGRADE_PROMPT_TIMEOUT seconds (60).
for arg in "$@"; do
    case "$arg" in
        -y | --yes) export DOTUPGRADE_YES=1 ;;
        -h | --help)
            echo "dot upgrade [--yes]   upgrade all tooling; --yes answers its questions with yes"
            echo "  Unanswered questions take their default (no) after DOTUPGRADE_PROMPT_TIMEOUT seconds (60; 0 = wait)."
            exit 0
            ;;
    esac
done

# Where the time goes (scripts/lib/timing.sh): marks at each section, a summary at the end.
DOT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DOT_SCRIPT_DIR/lib/timing.sh"
# net_timeout and github_latest_tag, for the outside-package-managers lag check at the end.
. "$DOT_SCRIPT_DIR/lib/agent-skills.sh"
. "$DOT_SCRIPT_DIR/lib/docker-vscode.sh"
. "$DOT_SCRIPT_DIR/lib/netspeed.sh"
# vscode_wsl_server_fetch: on WSL, the VS Code server download a `code` call hides.
. "$DOT_SCRIPT_DIR/lib/vscode-wsl.sh"

echo "dot upgrade - sweeping all tooling..."
# Two marks, so the Timings line says which half is slow: the scan and the stop, then the
# Codex daemon and the defer scan (one "sessions and Codex daemon" mark hid it).
dot_timing_mark 'sessions (scan and stop)'

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
# stdin for the answer, stderr for the question: stop_live_sessions is called with stdout to
# /dev/null (its count travels there), so a `-t 1` test made the offer unreachable on every
# Linux/WSL run (2026-10-11; tests/dotupgrade_stop_offer_tty_contract.sh).
is_interactive() { [ -t 0 ] && [ -t 2 ]; }
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
# A stopped CLI session restarts cold; name how to pick it back up rather than leave the
# operator to guess (2026-10-11: `dot upgrade --yes` run from another terminal stopped a live
# Claude Code session, with no trail beyond "unsaved context is lost unless it can be
# resumed"). Serena has no CLI of its own to resume - it is an MCP server its host (Claude
# Code, OpenCode, Codex, Antigravity) relaunches automatically when that host's session does.
resume_hint() {
    case "$1" in
        claude) echo "claude --resume" ;;
        codex) echo "codex resume" ;;
        opencode) echo "opencode --continue" ;;
        agy) echo "agy --continue" ;;
    esac
}
# Prints the number of sessions stopped. Nothing is stopped unless the operator says so.
stop_live_sessions() {
    local mine pids pid answer each stopped=0 chosen="" tty name hint
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
        printf '  Stop them so everything upgrades now? [y] all  [s] choose each  [N] keep and defer%s: ' "$(dot_ask_hint)"
    } >&2
    # the time spent answering is "your answers" in the closing Timings line, not this section
    dot_timing_wait 2>/dev/null || true
    dot_ask answer
    case "$answer" in
        [yY]) chosen="$pids" ;;
        [sS])
            for pid in $pids; do
                printf '    Stop %s? [y/N]%s: ' "$(describe_pid "$pid")" "$(dot_ask_hint)" >&2
                dot_ask each
                case "$each" in [yY]) chosen="$chosen $pid" ;; esac
            done
            ;;
    esac
    dot_timing_resume 2>/dev/null || true
    for pid in $chosen; do
        tty="$(agent_tty "$pid")"
        name="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"
        stop_pid_tree "$pid"
        reset_agent_terminal "$tty"
        stopped=$((stopped + 1))
        hint="$(resume_hint "$name")"
        [ -n "$hint" ] && echo "    stopped $name (pid $pid) - resume it with: $hint" >&2
    done
    [ "$stopped" -gt 0 ] && echo "  Stopped $stopped process(es); re-scanning." >&2
    echo "$stopped"
}
stop_live_sessions opencode claude codex agy serena >/dev/null
dot_timing_mark 'Codex daemon and defer scan'

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
    # The tree: the daemon runs helpers (code-mode host, command runner, voice host).
    for pid in $(codex_daemon_pids); do stop_pid_tree "$pid"; done
    echo "  Stopped Codex's app-server daemon (it restarts on demand, on the new version)."
}
live codex || stop_codex_daemon
DEFER=""
live codex && DEFER="codex"
live serena && DEFER="${DEFER:+$DEFER,}serena"
live opencode && DEFER="${DEFER:+$DEFER,}opencode"
export DOTUPGRADE_DEFER="$DEFER"
if [ -n "$DEFER" ]; then
    LIVE_NAMES="$(for p in opencode claude codex agy serena; do live "$p" && echo "$p"; done | sort -u | tr '\n' ' ')"
    echo "  Live agent session(s): ${LIVE_NAMES}- deferring: $DEFER"
else
    echo "  No live agent sessions - full sweep."
fi

dot_timing_mark 'network check'
# A slow link (under DOT_SLOW_MBPS, default 50 Mbit/s) is said up front; at a terminal the operator
# may leave the system package sweep out of this run or stop. --yes and no terminal continue.
net_speed_check
if [ "$NET_CHOICE" = stop ]; then
    echo "  Stopped at your request - nothing was upgraded. Re-run when the connection is better."
    exit 0
fi

dot_timing_mark 'system packages'
# --- 1. System packages: apt on Linux/WSL, brew on macOS. ---
# Docker (lib/docker-vscode.sh): an upgrade restarts Docker and stops every container, and a VS
# Code window attached to a dev container loses it. When a Docker upgrade is pending AND Docker
# is running, the operator is asked first; on yes VS Code is closed, then Docker stopped. Nothing
# apt_upgrade_run <apt-get flags...> - `apt-get upgrade -y`. dpkg's routine lines (Preparing to
# unpack / Unpacking / Setting up / Processing triggers: 17 of them for four packages, 2026-10-12)
# go to a file and the console gets one line - the list of what upgrades was printed just above;
# apt's whole output is shown when it fails. Captured stdout means no prompt can be seen or
# answered, so apt runs non-interactively (DEBIAN_FRONTEND=noninteractive; a changed conffile
# keeps the installed copy, --force-confold, as unattended-upgrades does). DOT_APT_VERBOSE=1
# keeps everything on the terminal, prompts included.
apt_upgrade_run() {
    local apt_q=("$@") out n
    if [ "${DOT_APT_VERBOSE:-}" = 1 ]; then
        sudo apt-get "${apt_q[@]}" upgrade -y
        return $?
    fi
    if out="$(sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_q[@]}" -o Dpkg::Use-Pty=0 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y 2>&1)"; then
        n="$(printf '%s\n' "$out" | grep -c '^Setting up ' || true)"
        [ "${n:-0}" -gt 0 ] && echo "  apt: $n package(s) upgraded."
    else
        printf '%s\n' "$out"
        echo "  apt upgrade failed - continuing with the rest of the sweep."
    fi
    return 0
}
# apt_sudo_prime - prime sudo's credential cache (and time its own prompt as "sudo password",
# not "system packages") before the first privileged apt call. The same shape and name as
# run_onchange_install_packages.sh.tmpl's own dot_sudo_prime: a WSL `dot upgrade` reported 53s
# of "system packages" with apt having nothing at all to do (2026-10-12), almost all of it the
# operator typing the password. `sudo -n true` says whether a prompt is coming at all; a
# cached credential opens no extra section.
apt_sudo_prime() {
    local prompt=0 rc=0
    sudo -n true >/dev/null 2>&1 || prompt=1
    [ "$prompt" = 0 ] || dot_timing_wait 'sudo password' 2>/dev/null || true
    sudo -v || rc=$?
    [ "$prompt" = 0 ] || dot_timing_resume 2>/dev/null || true
    return "$rc"
}

# below costs anything when Docker is not running (WSL: Docker Desktop and VS Code are Windows').
case "$NET_CHOICE:$(uname -s)" in
    skip:*)
        echo "  Skipping system packages (slow network, your choice)."
        ;;
    *:Linux)
        if command -v apt-get &>/dev/null; then
            echo "  Upgrading apt packages..."
            # Quiet like `dot up`: no Hit:/Get:/Reading... lines, one line naming what upgrades,
            # then only dpkg's own lines and errors. DOT_APT_VERBOSE=1 shows everything.
            apt_q=(-qq)
            if [ "${DOT_APT_VERBOSE:-}" = 1 ]; then apt_q=(); fi
            apt_sudo_prime
            if sudo apt-get "${apt_q[@]}" update; then
                # The password was just typed (or cached): keep it alive for the rest of the run -
                # a Maestro download outlasted sudo's 15 minutes and the npm step asked again
                # (lib/agent-skills.sh, 2026-10-11).
                dot_sudo_keepalive
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
                apt_list="$(apt-get -s upgrade 2>/dev/null | awk '/^Inst / { print $2 }' | tr '\n' ' ')" || apt_list=""
                if [ -n "${apt_list// /}" ]; then
                    echo "  apt: upgrading $(wc -w <<<"$apt_list") package(s): ${apt_list% }"
                else
                    echo "  apt: nothing to upgrade"
                fi
                apt_upgrade_run "${apt_q[@]}"
                dock_unhold
                # delta, dust, procs come from GitHub releases (no apt repo) and `dot up` installs
                # them only when missing: this is where they get upgraded (github_tool_sync,
                # lib/agent-skills.sh). The closing note then names only what still lags.
                # lychee and vale follow the pins in .chezmoidata.yaml (the weekly auto-update PR
                # moves them): reinstalled at the pin when the installed version differs
                # (release_tool_pins_upgrade, lib/agent-skills.sh). The tools that are current
                # share one line (tool_current_flush); any with news keeps its own.
                tool_current_collect
                for n in delta dust procs; do github_tool_sync "$n" sudo upgrade; done
                release_tool_pins_upgrade sudo
                tool_current_flush 'GitHub-release tools'
            fi
        else
            echo "  apt-get not found - skipping system packages."
        fi
        ;;
    *:Darwin)
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
# Run in the background, alongside the AI tools below: on WSL it took a minute on its own, and
# nothing after it depends on it. Waited for (and reported) before the summary.
# vscode_extensions_report <output file> <exit status> - what `code --update-extensions` did, in
# one line: "up to date", "N updated" with the names, or the failure (its output shown then).
# The step ran in the background with its output in the file; it used to print nothing on
# success, so a run never said whether anything moved.
vscode_extensions_report() {
    local out="$1" rc="$2" names n
    if [ "$rc" -ne 0 ]; then
        echo "  VS Code extension update did not finish cleanly (exit $rc) - continuing."
        [ -s "$out" ] && grep -v -e DeprecationWarning -e trace-deprecation "$out" | sed 's/^/    /'
        return 0
    fi
    if grep -q 'No extension to update' "$out" 2>/dev/null; then
        echo "  VS Code extensions: up to date"
        return 0
    fi
    names="$(grep -oE "Extension '[^']+' v[^ ]+ was successfully (updated|installed)" "$out" 2>/dev/null \
        | sed -E "s/^Extension '([^']+)' (v[^ ]+).*/\1 \2/" | paste -sd ',' - | sed 's/,/, /g')"
    n="$(printf '%s' "$names" | grep -o ', ' | wc -l | tr -d ' ')"
    if [ -n "$names" ]; then
        echo "  VS Code extensions: $((n + 1)) updated - $names"
    else
        echo "  VS Code extensions: updated"
        grep -v -e DeprecationWarning -e trace-deprecation "$out" 2>/dev/null | sed 's/^/    /'
    fi
    return 0
}

vscode_ext_pid=""
vscode_ext_out=""
# WSL: after a VS Code update on Windows, the first `code` call downloads the WSL server (200+ MB)
# before answering - inside the 300 s below it would be killed halfway and leave a partial tarball
# under ~/.vscode-server/bin. Fetch it first, visibly (lib/vscode-wsl.sh); a failed fetch skips
# the update this run. No-op on native Linux/macOS and when the server is present.
if command -v code &>/dev/null && vscode_wsl_server_fetch 're-run dot upgrade'; then
    echo "  Updating VS Code extensions (in the background)..."
    vscode_ext_out="$(mktemp)"
    timeout 300 code --update-extensions >"$vscode_ext_out" 2>&1 &
    vscode_ext_pid=$!
fi

dot_timing_mark 'AI tools'
# --- 2. AI tools: the update_ai_tools section, defer-aware. ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/update_ai_tools.sh"

if [ -n "$vscode_ext_pid" ]; then
    dot_timing_mark 'VS Code extensions (waiting)'
    vscode_ext_rc=0
    wait "$vscode_ext_pid" || vscode_ext_rc=$?
    vscode_extensions_report "$vscode_ext_out" "$vscode_ext_rc"
    rm -f "$vscode_ext_out"
fi

# --- Known outside-package-managers artifacts: no manager owns these, so
# the sweep above cannot upgrade them (Linux: direct .debs with no repo -
# Chrome, Docker Desktop, Termius, Handy, OpenCode Desktop, git-delta, dust,
# procs, neovim/lazygit/lychee/vale tarballs - plus the Antigravity 2.0 tar.gz; macOS:
# ScreenRec and Antigravity 2.0 .dmgs). Most self-update or are refreshable
# by re-running the installer; named here so the gap stays visible.
# Only what is actually installed here is named: WSL has none of the desktop apps (they live on
# Windows), and listing Docker Desktop there read as if WSL had a copy to keep current.
#
# delta, dust and procs are upgraded above (github_tool_sync) and lychee and vale follow their
# pins (release_tool_pins_upgrade), so none of the five is named here any more (2026-10-11): the
# note is for the desktop .debs only, which no manager and no pin owns.
unmanaged_present() {
    local names=()
    if command -v google-chrome &>/dev/null; then names+=("Chrome"); fi
    if dpkg -s docker-desktop &>/dev/null || command -v docker-desktop &>/dev/null; then names+=("Docker Desktop"); fi
    if dpkg -s termius &>/dev/null || command -v termius &>/dev/null; then names+=("Termius"); fi
    if dpkg -s handy &>/dev/null; then names+=("Handy"); fi
    if dpkg -s opencode-desktop &>/dev/null || command -v opencode-desktop &>/dev/null; then names+=("OpenCode Desktop"); fi
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
