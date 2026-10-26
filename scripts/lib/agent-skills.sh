#!/usr/bin/env bash
# scripts/lib/agent-skills.sh - the curated-agent-skills lifecycle and its
# supporting helpers, shared by every shell consumer (issue #123).
#
# Consumers:
#   - run_onchange_install_packages.sh.tmpl: inlined at RENDER time via
#     `{{ include "scripts/lib/agent-skills.sh" }}` - a run_onchange script
#     must stay self-contained, so the installer cannot source at runtime.
#   - scripts/update_ai_tools.sh: sources this file directly
#     (". "${BASH_SOURCE[0]%/*}/lib/agent-skills.sh"").
#   - scripts/update-versions.sh: net_timeout + sha256_cmd only.
#
# The file is deliberately TEMPLATE-FREE plain bash: both consumers must be
# able to load it byte-for-byte. Every value that differs per consumer
# (catalog path, agent list, npx wrapper, tally counters, record_cli_result)
# is resolved dynamically from the caller's scope.
#
# Behavior pins: tests/agent_skill_wiring_contract.sh extracts the lifecycle
# by marker and executes it in fixtures; tests/install_agent_skills_arguments.sh
# pins the exact npx argument vector. The add/verify bodies here are verbatim
# from the installer (previously copy-pasted into update_ai_tools.sh, which
# had drifted: no net_timeout, no shared logging - the 2026-08-30 hang class).

#-------------------------------------------------------------------------------
# Colors + logging - the one shell convention (the installer used to define
# these inline; the updater used raw echo).
#-------------------------------------------------------------------------------
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { printf "${BLUE}▸${NC} %s\n" "$1"; }
success() { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}⚠${NC} %s\n" "$1" >&2; }
error()   { printf "${RED}✗${NC} %s\n" "$1" >&2; }

#-------------------------------------------------------------------------------
# dot_sudo_keepalive - refresh sudo's cached credential in the background until the script
# that called this is gone. A WSL `dot upgrade --yes` (2026-10-11) asked for the password
# twice: for apt at the start, and 18 minutes later for the npm global upgrade, after
# Maestro's 300 MB download had outlasted sudo's 15-minute timestamp. The installer has had
# this loop since #114 (dot_sudo_prime); `dot upgrade` now starts the same one right after
# its first sudo succeeded. Call it AFTER a sudo that prompted: it never prompts itself.
#
# Both streams closed: the loop inherits the caller's descriptors, and one started inside a
# `$(...)` would hold that pipe open for the life of the run. $$ is the calling script (the
# function runs in its shell), so `kill -0` ends the loop within one interval of its exit.
# DOT_SUDO_KEEPALIVE_SECONDS (default 30) is for tests; DOT_SUDO_KEEPALIVE_PID names the loop.
# tests/dotupgrade_sudo_keepalive_contract.sh executes this against a fake sudo.
#-------------------------------------------------------------------------------
DOT_SUDO_KEEPALIVE_PID=""
dot_sudo_keepalive() {
    [ -z "$DOT_SUDO_KEEPALIVE_PID" ] || return 0
    local every="${DOT_SUDO_KEEPALIVE_SECONDS:-30}" parent=$$
    while true; do sudo -n true; sleep "$every"; kill -0 "$parent" || exit; done >/dev/null 2>&1 &
    DOT_SUDO_KEEPALIVE_PID=$!
    return 0
}

#-------------------------------------------------------------------------------
# net_timeout <seconds> <cmd...> - wall-clock guard for network install steps.
#
# A stalled download or `curl | sh` installer (no built-in timeout) otherwise
# freezes a `set -e` run indefinitely - confirmed live: Ollama's ~1.5GB bundle
# stalled mid-transfer for 15+ min with nothing else able to proceed, and the
# skills CLI once hung at its intro banner. Wrap the fetch so a dead
# connection is killed and the caller's `|| warn` can carry on.
#
# Uses coreutils `timeout` (always present on Linux) or `gtimeout` (macOS -
# `coreutils` is first in the brew core list so it lands before the guarded
# steps); if neither exists the command runs unguarded rather than failing.
# Resolved per-call, not cached, so a `gtimeout` installed partway through a
# macOS run is picked up by later steps. `-k 10` follows SIGTERM with SIGKILL
# after 10s for processes that ignore the first signal (NET_TIMEOUT_KILL_AFTER
# overrides the 10, for tests).
#
# Exit 124 = timed out, and so does 137: when the escalation to SIGKILL fires,
# `timeout` kills its own process group (itself included) and exits 137, and bash
# prints the kernel's "Killed" notice for it - a WSL `dot up` (2026-10-11) showed
#   line 161:  3657 Killed   "$bin" -k 10 "$secs" "$@"
# for a `claude mcp add` the kernel had stopped (SIGTTIN, #355), and the caller's "failed or timed
# out" could not say which. Both exits are reported here as one line naming the
# command and the budget, and come back as 124. The command runs in a subshell
# whose own stderr is discarded (that is where bash writes the notice) while the
# command's stderr is routed around it on fd 3, so errors still show.
#-------------------------------------------------------------------------------
net_timeout() {
    local secs="$1"; shift
    local bin="" rc=0
    if command -v timeout &>/dev/null; then bin="timeout"
    elif command -v gtimeout &>/dev/null; then bin="gtimeout"
    fi
    if [ -n "$bin" ]; then
        ( "$bin" -k "${NET_TIMEOUT_KILL_AFTER:-10}" "$secs" "$@" 2>&3 3>&-; exit $? ) 3>&2 2>/dev/null || rc=$?
        _net_timeout_report "$rc" "$secs" "$1"
    else
        "$@"
    fi
}

# _net_timeout_report <rc> <secs> <command> - 124 and 137 both mean the budget ran out:
# say so once, and return 124 for either; any other status is the command's own.
_net_timeout_report() {
    case "$1" in
        124 | 137)
            printf '%s timed out after %ss - killed\n' "$3" "$2" >&2
            return 124
            ;;
    esac
    return "$1"
}

#-------------------------------------------------------------------------------
# net_timeout_tty <seconds> <cmd...> - net_timeout for commands that need the
# terminal (sudo). Plain `timeout` runs its command in a NEW process group, so
# a sudo/pty that touches the tty from there is a background job and the
# kernel can stop it (SIGTTIN/SIGTTOU). `--foreground` keeps the command in
# the shell's foreground group. Seen: `sudo npx playwright install-deps` on
# WSL sat in state T for the full timeout AFTER apt had finished (the cause is
# a strong suspect, not reproduced: it needs a sudo password). Trade-off:
# --foreground times out only the direct child, not its descendants.
#-------------------------------------------------------------------------------
net_timeout_tty() {
    local secs="$1"; shift
    local bin="" rc=0
    if command -v timeout &>/dev/null; then bin="timeout"
    elif command -v gtimeout &>/dev/null; then bin="gtimeout"
    fi
    if [ -n "$bin" ]; then
        # --foreground never kills the timeout process itself, so no "Killed"
        # notice to hide here; only the 137 -> 124 reading is shared.
        "$bin" --foreground -k "${NET_TIMEOUT_KILL_AFTER:-10}" "$secs" "$@" || rc=$?
        _net_timeout_report "$rc" "$secs" "$1"
    else
        "$@"
    fi
}

#-------------------------------------------------------------------------------
# apt_resume_stopped - start a background watcher that sends SIGCONT to any
# apt/apt-get/dpkg process it finds stopped (`ps` state T), and print its pid;
# the caller kills it once its privileged apt call returns. sudo's `use_pty`
# races the new pty's foreground-group assignment against the command it runs,
# and a descendant that loses takes one stray SIGTTIN/SIGTTOU and sits stopped
# forever - nothing in a non-interactive script resumes it (issue #431 Run 7,
# diagnosed with strace; the full account is above apt_upgrade_run in
# scripts/dotupgrade.sh). The installer's `sudo npx playwright install-deps`
# showed the same shape on WSL and again on a clean Ubuntu 26.04 checkpoint
# (Run 8): every package configured, no End-Date in history.log, the 300 s
# budget spent. `sudo -n`: the watcher runs with no terminal, so an expired
# credential must fail quietly instead of prompting on /dev/tty from the
# background. Capped at 30 minutes in case the caller never stops it.
#
# Not only apt-named processes: Run 10 (clean checkpoint, this watcher in
# place) had install-deps' apt-get finish - End-Date written - and the chain
# above it (sudo -> npx -> node -> sh) still sat out the 300 s. A stopped
# process anywhere under the calling script ($$) is continued too, whatever
# its name. Optional arguments, for evidence no run had so far: <log> gets one
# line per process resumed (first time only) and, after <snapshot-secs>, one
# dump of every process under the caller - `ps` columns and comm only, never
# argv. tests/dotupgrade_apt_resume_stopped_contract.sh executes it.
#-------------------------------------------------------------------------------
apt_resume_stopped() {
    local log="${1:-/dev/null}" snap_after="${2:-0}" root=$$
    # Closes all three streams (invariant: a background job started from a function must close
    # both, or its caller's command substitution - here, catching this function's own `echo $!` -
    # blocks until the BACKGROUND loop exits too, since it would otherwise still hold the
    # inherited pipe open for up to the 30-minute cap below, not just for the echo).
    (
        local i=0 pid line seen=" " snapped=""
        while [ "$i" -lt 6000 ]; do
            while read -r pid line; do
                [ -n "$pid" ] || continue
                kill -CONT "$pid" 2>/dev/null || sudo -n kill -CONT "$pid" 2>/dev/null
                case "$seen" in *" $pid "*) ;; *)
                    seen="$seen$pid "
                    printf '%s resumed stopped: %s %s\n' "$(date +%T)" "$pid" "$line" >>"$log" ;;
                esac
            done < <(_apt_watch_ps "$root" stopped)
            if [ -z "$snapped" ] && [ "$snap_after" -gt 0 ] && [ $((i * 3)) -ge $((snap_after * 10)) ]; then
                snapped=1
                {
                    printf '%s still running after %ss (PID PPID PGID TPGID STAT WCHAN COMMAND):\n' "$(date +%T)" "$snap_after"
                    _apt_watch_ps "$root" all
                } >>"$log"
            fi
            sleep 0.3
            i=$((i + 1))
        done
    ) </dev/null >/dev/null 2>&1 &
    echo $!
}

# _apt_watch_ps <root pid> stopped|all - apt_resume_stopped's process listing, one
# `PID PPID PGID TPGID STAT WCHAN COMMAND` line each: `stopped` = state T and either
# apt-named or under <root>; `all` = every process under <root>, whatever its state.
_apt_watch_ps() {
    ps -eo pid=,ppid=,pgid=,tpgid=,stat=,wchan:24=,comm= 2>/dev/null | awk -v root="$1" -v mode="$2" '
        { n++; pid[n] = $1; pp[$1] = $2; st[$1] = $5; c = $7
          for (k = 8; k <= NF; k++) c = c " " $k
          cm[$1] = c; row[$1] = $1 " " $2 " " $3 " " $4 " " $5 " " $6 " " c }
        END {
            for (j = 1; j <= n; j++) {
                p = pid[j]; under = 0
                for (q = pp[p]; q != "" && q > 1 && hops < 64; q = pp[q]) { hops++; if (q == root) { under = 1; break } }
                hops = 0
                if (mode == "all") { if (under) print row[p]; continue }
                if (st[p] !~ /^T/) continue
                if (under || cm[p] == "apt" || cm[p] == "apt-get" || cm[p] == "dpkg") print row[p]
            }
        }'
}

#-------------------------------------------------------------------------------
# mcp_add_quiet <agent label> <server> <retry-hint> <cmd...> - an agent CLI's
# `mcp add`, quiet on success. The CLIs' own lines reached the terminal raw on
# the 2026-10-11 WSL `dot up` - "Added stdio MCP server maestro with command:
# maestro mcp to user config" and "File modified: ~/.claude.json" (Claude
# Code), "Added global MCP server 'maestro'." (Codex) - while OpenCode's
# registration says "Registered/updated MCP in opencode (maestro)". Output is
# captured and shown only on failure, before the warn that names the retry
# hint (the run_onchange re-entry command: a failed registration is never
# retried by the next `dot up`). Always returns 0 - never aborts a `set -e`
# run. net_timeout_tty, not net_timeout: `claude mcp add` touches the
# controlling terminal while probing the server, and plain `timeout` stops it
# dead on WSL (#355). tests/mcp_add_quiet_contract.sh executes this.
#-------------------------------------------------------------------------------
mcp_add_quiet() {
    local label="$1" server="$2" hint="$3" out rc=0
    shift 3
    out="$(net_timeout_tty 60 "$@" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        [ -z "$out" ] || printf '%s\n' "$out" >&2
        warn "$server MCP registration for $label failed - re-run: $hint"
        return 0
    fi
    info "Registered MCP in $label ($server)"
    return 0
}

#-------------------------------------------------------------------------------
# sha256_cmd - print the available SHA-256 tool ("shasum -a 256" included
# verbatim: stock macOS ships shasum, not sha256sum), empty when none.
#-------------------------------------------------------------------------------
sha256_cmd() {
    if command -v sha256sum &>/dev/null; then printf '%s\n' "sha256sum"
    elif command -v gsha256sum &>/dev/null; then printf '%s\n' "gsha256sum"
    elif command -v shasum &>/dev/null; then printf '%s\n' "shasum -a 256"
    fi
}

#-------------------------------------------------------------------------------
# fetch_and_verify <name> <asset_url> <sums_url> <asset_name> <dest_dir>
#
# Download-to-temp + checksum-verify for third-party installers that publish
# SHA256SUMS (#125's verify_and_run_installer): fetches the asset and its
# SHA256SUMS into <dest_dir> (net_timeout-guarded, never piped), verifies
# <asset_name> against the one-line SHA256SUMS entry, returns 0 iff verified.
# Verifies from a one-line file, not stdin (like agent-guardrails' own
# installer): a BSD-compatible sha256sum (macOS 14+) may not read `-c -`.
# No <asset_name> line fails the grep, so a partial SHA256SUMS fail-closes.
# Warns and returns non-zero on any failure; the caller owns cleanup and the
# run-from-a-file step.
#-------------------------------------------------------------------------------
fetch_and_verify() {
    local name="$1" asset_url="$2" sums_url="$3" asset_name="$4" dest="$5"
    if ! net_timeout 60 curl -fsSL -o "$dest/$asset_name" "$asset_url" ||
        ! net_timeout 60 curl -fsSL -o "$dest/SHA256SUMS" "$sums_url"; then
        warn "$name: installer download failed or timed out - skipping"
        return 1
    fi
    local sha
    sha="$(sha256_cmd)"
    if [ -z "$sha" ]; then
        warn "$name: no SHA-256 tool found - cannot verify installer, skipping"
        return 1
    fi
    # --quiet (GNU sha256sum, gsha256sum, perl shasum, uutils alike): the "install.sh: OK" line
    # the check printed landed in the middle of dot up / dot upgrade output, where it read as a
    # result of whatever step came before it. A mismatch still prints its FAILED line.
    # [ *]: sha256sum's line is "<hash>  <name>" in text mode but "<hash> *<name>" in binary mode
    # (Git for Windows' sha256sum.exe defaults to binary mode); a bare space before <name> only
    # matched text mode and reported every binary-mode checksum as a mismatch (2026-10-24).
    if ! ( cd "$dest" && grep "[ *]${asset_name}\$" SHA256SUMS >SHA256SUMS.one &&
        $sha -c --quiet SHA256SUMS.one ); then
        warn "$name: installer CHECKSUM MISMATCH - not running it"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# maestro_download_heartbeat <file> - one progress line every MAESTRO_HEARTBEAT_SECS
# (default 30; a test shortens it) while FILE grows, so a slow-but-alive download
# (its own stall guard already lets it run as long as it needs) is not silent for
# its whole duration. A WSL `dot up` (2026-10-11) looked indistinguishable from
# stuck for 20+ minutes while curl was downloading the whole time - the stall
# guard protects against a dead connection, not against an operator's "is this
# stuck?". Runs until the caller kills it; FILE not existing yet reads as 0 bytes,
# never an error.
#-------------------------------------------------------------------------------
maestro_download_heartbeat() {
    local file="$1" secs="${MAESTRO_HEARTBEAT_SECS:-30}" size
    while :; do
        sleep "$secs"
        size="$(wc -c <"$file" 2>/dev/null || echo 0)"
        info "   ...still downloading ($((size / 1048576)) MiB so far)"
    done
}

#-------------------------------------------------------------------------------
# install_maestro <version> <sha256> [retry-hint] - the mobile_dev group's Maestro
# CLI, pinned and checksum-verified (.chezmoidata.yaml's maestro_version /
# maestro_sha256), shared by the installer template (`dot up`) and
# update_ai_tools.sh (`dot upgrade`).
#
# Not the vendor's curl-piped-to-bash installer (its URL is in .chezmoidata.yaml's
# versions comment): it only runs `unzip -qt` on what it downloads - a corruption check, not
# an authenticity one - which would make the repo's pin meaningless. The exact
# release asset is fetched and its sha256 verified here instead, the shape
# install_powershell() uses. The release tag is "cli-$version"; the "cli-" prefix
# is part of the URL only, never of the stored version. The zip extracts into its
# own maestro/ directory (maestro/bin/maestro, a Gradle POSIX launcher that
# resolves JAVA_HOME or falls back to `java` on PATH, plus maestro/lib/*.jar) -
# confirmed against the real release - so a plain -d destination is enough.
#
# Single-user: no sudo, lands under $HOME/.local/opt/maestro, linked from
# $HOME/.local/bin (on PATH per dot_zshrc's "Local binaries" block).
#
# The download is guarded by a STALL limit, not a wall clock: the asset is
# ~300 MB and a WSL `dot up` (2026-10-11) on a ~170 KiB/s link could never
# finish inside the 300 s net_timeout it had, every run. curl kills a transfer
# that drops under 10 KiB/s for 60 s (a dead connection, the only hang class the
# wall clock was for) and otherwise lets a slow one finish.
#
# The installed pin is recorded in $HOME/.local/opt/maestro/.dotfiles-version:
# the same pin is a no-op, a bumped pin reinstalls (`command -v maestro` alone
# never did - a pin bump re-rendered the installer and the step skipped itself).
# A Maestro that is not ours (on PATH, nothing under ~/.local/opt/maestro) is
# left alone. Every failure warns with the caller's retry hint ("re-run dot
# upgrade" by default; the installer passes the run_onchange re-entry command)
# and returns 0 - never aborts a `set -e` run.
#-------------------------------------------------------------------------------
install_maestro() {
    local ver="$1" want="$2" hint="${3:-re-run dot upgrade}"
    local root="$HOME/.local/opt/maestro" marker have got sha_cmd tmp asset url
    marker="$root/.dotfiles-version"
    have="$(/bin/cat "$marker" 2>/dev/null || true)"
    if [ -x "$root/bin/maestro" ] && [ "$have" = "$ver" ]; then
        return 0
    fi
    if [ ! -e "$root/bin/maestro" ] && command -v maestro >/dev/null 2>&1; then
        info "maestro already on PATH ($(command -v maestro)) - not installing the pinned $ver alongside it"
        return 0
    fi
    asset="maestro.zip"
    url="https://github.com/mobile-dev-inc/maestro/releases/download/cli-$ver/$asset"
    sha_cmd="$(sha256_cmd)"
    if [ -z "$sha_cmd" ]; then
        warn "maestro: no SHA-256 tool found - cannot verify the download, skipping ($hint)"
        return 0
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        warn "maestro: unzip not found - cannot extract the download, skipping ($hint)"
        return 0
    fi
    if ! tmp="$(mktemp -d)"; then
        warn "maestro: could not create a temporary directory - skipping ($hint)"
        return 0
    fi
    if [ -n "$have" ] && [ "$have" != "$ver" ]; then
        info "Updating Maestro $have -> $ver (CLI for mobile_dev, ~300 MB)..."
    else
        info "Installing Maestro $ver (CLI for mobile_dev, ~300 MB; a slow link is given the time it needs)..."
    fi
    local hb_pid
    maestro_download_heartbeat "$tmp/$asset" &
    hb_pid=$!
    if ! curl -fsSL --connect-timeout 30 --speed-limit 10240 --speed-time 60 -o "$tmp/$asset" "$url"; then
        kill "$hb_pid" 2>/dev/null || true
        wait "$hb_pid" 2>/dev/null || true
        warn "maestro download failed or stalled - skipping ($hint)"
        rm -rf "$tmp"
        return 0
    fi
    kill "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true
    # shellcheck disable=SC2086  # sha256_cmd may be "shasum -a 256": word-split on purpose
    got="$($sha_cmd "$tmp/$asset" 2>/dev/null | cut -d' ' -f1)"
    if [ "$want" != "$got" ]; then
        warn "maestro CHECKSUM MISMATCH for $asset - not installing (pin stale? re-run scripts/update-versions.sh)"
        rm -rf "$tmp"
        return 0
    fi
    mkdir -p "$HOME/.local/opt" "$HOME/.local/bin"
    rm -rf "$root"
    if unzip -q "$tmp/$asset" -d "$HOME/.local/opt" \
        && chmod +x "$root/bin/maestro" \
        && ln -sf "$root/bin/maestro" "$HOME/.local/bin/maestro" \
        && printf '%s\n' "$ver" >"$marker"; then
        success "Maestro $ver installed (maestro)"
    else
        warn "maestro install failed - continuing ($hint)"
    fi
    rm -rf "$tmp"
    return 0
}

#-------------------------------------------------------------------------------
# skills_add_all - the curated third-party skills, installed via the `skills`
# CLI (vercel-labs/skills) for Claude Code / OpenCode / Antigravity / Codex.
#
# Caller-provided (dynamic scope):
#   AGENTS  array - adapters from .chezmoidata/agents.yaml skills.agents
#   record_cli_result <status> <count> - the caller's per-agent tally
#   info/warn - provided by this file
#
# Every call: `</dev/null` keeps any prompt from ever holding the terminal
# (chezmoi run_onchange scripts inherit the terminal's TTY on stdin; a CLI
# that decides to prompt - or a stalled fetch with no internal timeout - then
# blocks the whole run; confirmed live 2026-08-30). net_timeout stays as the
# wall-clock backstop.
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# agent_browser_doctor <agent-browser binary> - run `doctor --json` (60 s cap) and print
# a one-line summary plus one line per warn/fail check, instead of the ~3 KB JSON blob it
# used to dump on every run. Output that is not the expected JSON (or no jq) is printed
# raw, never dropped. Returns doctor's own exit status.
#
# Under agent_browser_sandbox_workaround's --no-sandbox, doctor runs with --quick: its live
# launch probe ignores ~/.agent-browser/config.json, and AGENT_BROWSER_ARGS and --args with it
# (agent-browser 0.39.2), so on a restricted kernel it failed with "No usable sandbox!" on
# every run while `agent-browser open` launched Chrome fine (issue #431 Run 8, clean Ubuntu
# 26.04 checkpoint). The skip is said on its own line.
#-------------------------------------------------------------------------------
agent_browser_doctor() {
    local out rc=0 quick=""
    agent_browser_no_sandbox_set && quick=1
    out="$(net_timeout 60 "$1" doctor --json ${quick:+--quick} 2>&1)" || rc=$?
    if command -v jq &>/dev/null && printf '%s' "$out" | jq -e '.summary' >/dev/null 2>&1; then
        printf '%s' "$out" | jq -b -r '"agent-browser doctor: \(.summary.pass // 0) pass, \(.summary.warn // 0) warn, \(.summary.fail // 0) fail", (.checks[]? | select(.status == "warn" or .status == "fail") | "  \(.status): \(.message)" + (if .fix then " (fix: \(.fix))" else "" end))'
    else
        printf '%s\n' "$out"
    fi
    [ -z "$quick" ] || echo "  skipped: doctor's launch test (it ignores the --no-sandbox in ~/.agent-browser/config.json this kernel needs)"
    return "$rc"
}

# agent_browser_no_sandbox_set - 0 when the kernel restricts unprivileged user namespaces AND
# ~/.agent-browser/config.json passes --no-sandbox (what agent_browser_sandbox_workaround sets).
# A user's own args without it keep doctor's full launch test, so a real failure still shows.
agent_browser_no_sandbox_set() {
    local proc_path="${AGENT_BROWSER_APPARMOR_PROC:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}"
    [ "$(cat "$proc_path" 2>/dev/null)" = 1 ] || return 1
    command -v jq &>/dev/null || return 1
    jq -b -e '(.args // "") | tostring | contains("--no-sandbox")' "$HOME/.agent-browser/config.json" >/dev/null 2>&1
}

#-------------------------------------------------------------------------------
# agent_browser_sandbox_workaround - Ubuntu 23.10+ (confirmed live on 26.04,
# issue #431 Run 4/Run 5) restricts unprivileged user namespaces via AppArmor
# by default, so Chrome's own sandboxed launch refuses to start at all:
# "No usable sandbox!" (zygote_host_impl_linux.cc), exiting before it ever
# writes DevToolsActivePort - `agent-browser doctor --json`'s own
# "launch.launch" check fails with exactly this on a plain VM, no sandbox
# hardening of ours involved. agent-browser documents its own escape hatch for
# this exact case ("required in containers, VMs, and some Linux setups"):
# --args "--no-sandbox", read from ~/.agent-browser/config.json (the first of
# its own three config-precedence sources) - set once here so every future
# invocation picks it up, not just this run's install/doctor calls. Checked
# against the actual kernel policy, not a distro/version guess, so a future
# release that changes the default is still handled correctly either way.
# Never overwrites an `args` key that is already there - a user's own choice
# wins, even if that means the restriction stays unworked-around.
# AGENT_BROWSER_APPARMOR_PROC overrides the proc path checked (tests only).
#-------------------------------------------------------------------------------
agent_browser_sandbox_workaround() {
    local proc_path="${AGENT_BROWSER_APPARMOR_PROC:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}"
    [ "$(cat "$proc_path" 2>/dev/null)" = 1 ] || return 0
    if ! command -v jq &>/dev/null; then
        warn "jq unavailable - could not set agent-browser's --no-sandbox workaround for this VM/container's restricted AppArmor policy"
        return 0
    fi
    local cfg="$HOME/.agent-browser/config.json"
    mkdir -p "$(dirname "$cfg")"
    if [ -f "$cfg" ]; then
        jq -e '.args' "$cfg" >/dev/null 2>&1 && return 0
        jq '.args = "--no-sandbox"' "$cfg" >"$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    else
        jq -n '{args: "--no-sandbox"}' >"$cfg"
    fi
}

#-------------------------------------------------------------------------------
# skills_up_to_date <owner/repo> <skill>... - 0 when this source need not be
# fetched again, 1 when it must be (or when anything is unknown).
#
# `skills add` re-fetches every skill on every run, and a cold `npx
# skills@latest` costs 30+ s even when nothing moved upstream. A source is
# skipped only when ALL of these hold:
#   - DOT_SKILLS_FORCE is not 1,
#   - every named skill is present for Claude (~/.claude/skills) and for
#     OpenCode/Codex (~/.agents/skills),
#   - upstream HEAD (one `git ls-remote`) equals the commit recorded after the
#     last successful install of this exact source + skill list + agent list.
# An unreachable remote never skips. Why not `skills update`: it takes no
# --copy / -a flags and re-links the Claude copy as a symlink into
# ~/.agents (measured on skills 1.7.0), but these installs are deliberately
# copies. This is the version check instead.
#
# Side effect: remembers the key and the HEAD it saw in SKILLS_PENDING_KEY /
# SKILLS_PENDING_HEAD, so skills_record_source (called after the add succeeds)
# stores exactly the commit that was checked.
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# quiet_apt_enable - make every `apt install|update` / `apt-get install|update` this shell runs
# print only what matters.
#
# A WSL `dot up` printed ~100 lines of apt chatter ("git is already the newest version",
# "Reading package lists...", "N upgraded, 0 newly installed...", the update's Hit:/Get: list)
# across ~13 install groups, while the Windows run (choco) was quiet. `apt -qq` still prints the
# "already the newest version" lines; `apt-get -qq` prints nothing but errors (and dpkg's own
# lines for a real install), and has no "apt does not have a stable CLI interface" warning. So
# install and update are routed to `apt-get -qq`; every other apt subcommand, and every other
# sudo command, passes through untouched. Done with functions so none of the ~40 call sites
# (pinned by tests/package_catalog_contract.sh) has to change, and
# with NO pipe, so prompts, sudo's password request and exit codes behave exactly as before.
# Call it only once the package manager is known to be apt.
#
# Two things are NOT optional, so DOT_APT_VERBOSE=1 (which only brings apt's output back to the
# terminal) keeps them:
#   - installs run non-interactively: DEBIAN_FRONTEND=noninteractive through `env` (sudo resets
#     the environment), keeping a changed conffile (confdef/confold) and needrestart's auto mode -
#     dotupgrade.sh's apt_upgrade_run does the same for upgrades. A fresh Ubuntu 26.04 VM
#     (2026-10-23) stopped on iperf3's "Start Iperf3 as a daemon automatically?" debconf dialog;
#     Ctrl+C killed the installer but left that sudo/apt/whiptail behind holding the dpkg lock,
#     and the next two runs did nothing but "Waiting for cache lock". Quiet mode would have been
#     worse: stdout goes to apt.log there, so the dialog would have hung with nothing on screen.
#   - install and update wait for the dpkg lock a bounded time (DOT_APT_LOCK_TIMEOUT seconds,
#     default 600) instead of apt-get's default of failing at once - first boot's
#     unattended-upgrades holds it legitimately - or apt's of waiting forever.
#-------------------------------------------------------------------------------
_qapt_rewrite() {
    QAPT_ARGS=("$@")
    QAPT_CAPTURE=0
    local quiet=() lockwait=(-o "DPkg::Lock::Timeout=${DOT_APT_LOCK_TIMEOUT:-600}")
    if [ "${QAPT_VERBOSE:-}" != 1 ]; then quiet=(-qq); QAPT_CAPTURE=1; fi
    case "$1:${2:-}" in
        apt:install | apt-get:install)
            QAPT_ARGS=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get ${quiet[@]+"${quiet[@]}"} "${lockwait[@]}"
                -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${@:2}") ;;
        apt:update | apt-get:update) QAPT_ARGS=(apt-get ${quiet[@]+"${quiet[@]}"} "${lockwait[@]}" "${@:2}") ;;
        *) QAPT_CAPTURE=0 ;;
    esac
}

# _qapt_run <argv...> - run the rewritten command. `apt-get -qq` silences apt but
# not dpkg: a real install still prints its "Selecting previously unselected
# package / Unpacking / Setting up / update-alternatives" wall (one JDK on a WSL
# `dot up`, 2026-10-11). For install/update (QAPT_CAPTURE=1) stdout goes to
# ~/.local/state/dotfiles/apt.log under a dated header and is replayed on the
# terminal only when the command fails; stderr, where apt and dpkg report errors
# (and where sudo prompts), is never touched. Exit code is the command's own.
_qapt_run() {
    if [ "${QAPT_CAPTURE:-0}" != 1 ]; then
        command "$@"
        return
    fi
    local dir log out rc=0
    dir="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles"
    log="$dir/apt.log"
    out="$(mktemp 2>/dev/null)" || out=""
    if [ -z "$out" ]; then
        command "$@"
        return
    fi
    command "$@" >"$out" || rc=$?
    if mkdir -p "$dir" 2>/dev/null; then
        { printf '=== %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)" "$*"; /bin/cat "$out"; } >>"$log" 2>/dev/null || true
    fi
    [ "$rc" -eq 0 ] || /bin/cat "$out"
    rm -f "$out"
    return "$rc"
}

quiet_apt_enable() {
    QAPT_VERBOSE="${DOT_APT_VERBOSE:-}" # decided once, like the shims themselves
    # shellcheck disable=SC2317  # defined here, called by the installer's own commands
    sudo() {
        if [ "${1:-}" = apt ] || [ "${1:-}" = apt-get ]; then
            _qapt_rewrite "$@"
            _qapt_run sudo "${QAPT_ARGS[@]}"
        else
            command sudo "$@"
        fi
    }
    # shellcheck disable=SC2317
    apt() { _qapt_rewrite apt "$@"; _qapt_run "${QAPT_ARGS[@]}"; }
    # shellcheck disable=SC2317
    apt-get() { _qapt_rewrite apt-get "$@"; _qapt_run "${QAPT_ARGS[@]}"; }
    [ "$QAPT_VERBOSE" = 1 ] ||
        info "apt install/update output is quiet (DOT_APT_VERBOSE=1 shows it; ~/.local/state/dotfiles/apt.log keeps it); errors are always shown."
}

# apt_lock_preflight - before an apt call, name whoever holds the package system instead
# of letting apt print "Waiting for cache lock ... held by process N" until someone gives up
# (two whole runs of it on 2026-10-23 - see quiet_apt_enable). A package manager that is merely
# busy (first boot's unattended-upgrades) is reported and waited for by the bounded lock timeout.
# Two shapes never finish on their own, so both stop the run with the same recovery line:
# one sitting under a debconf dialog (whiptail/dialog, left behind by an interrupted run), and
# one that is just plain STOPPED (ps state T) - net_timeout_tty's --foreground only ever signals
# its direct child, not that child's own descendants (its own documented trade-off), so a chain
# like sudo -> npx -> playwright -> apt-get can leave the apt-get grandchild alive, reparented to
# init/systemd, in state T, after `timeout` already reported 124/137 (issue #431 Run 2 - confirmed
# live, worked around by hand, never fixed here before). A merely-busy holder is never in state T.
# Processes are found by name (pgrep -x matches the 15-char comm, hence unattended-upgr): the
# lock files themselves are root-only, and nothing has prompted for sudo yet.
apt_lock_preflight() {
    local holders dialogs pid etime stat stopped=""
    # unattended-upgrade-shutdown shares the comm but only idles until shutdown - never a holder
    holders="$(pgrep -a -x 'apt|apt-get|aptitude|dpkg|unattended-upgr' 2>/dev/null | grep -v 'unattended-upgrade-shutdown')" || return 0
    warn "Another package manager is running - apt waits for it (up to ${DOT_APT_LOCK_TIMEOUT:-600}s per call):"
    while read -r pid _; do
        etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
        stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
        printf '    %s (running %s)\n' "$(grep -E "^$pid " <<<"$holders")" "${etime:-?}" >&2
        [[ "$stat" == T* ]] && stopped="$stopped $pid"
    done <<<"$holders"
    dialogs="$(pgrep -x 'whiptail|dialog' 2>/dev/null)" || true
    [[ -n "$dialogs" || -n "$stopped" ]] || return 0
    if [[ -n "$dialogs" ]]; then
        warn "...and it is stuck on a debconf question no one can see (left behind by an interrupted run?) - it will never finish."
    else
        warn "...and it is stopped (state T), not merely busy - an orphan left behind by an earlier timed-out step - it will never finish."
    fi
    local kill_pids
    kill_pids="$({ printf '%s\n' "$holders" | cut -d' ' -f1; printf '%s\n' "$dialogs"; } | sed '/^$/d' | tr '\n' ' ' | sed 's/ $//')"
    warn "Clear it, then re-run:  sudo kill $kill_pids && sudo dpkg --configure -a"
    return 1
}

#-------------------------------------------------------------------------------
# graft_retire [npm-sudo] - remove Graft (@nanonets/graft) from a machine that
# has it. The dotfiles installed it until 2026-10-09 and dropped it after a
# benchmark showed no accuracy or cost benefit; the installers and `dot upgrade`
# call this so it does not linger. Twin of Invoke-GraftRetirement in
# scripts/lib/ps-skills.ps1.
#
# Only what is unambiguously graft's goes:
#   - MCP entries named graft whose command runs graft: OpenCode's global
#     opencode.json (mcp.graft), agy's ~/.gemini/config/mcp_config.json
#     (mcpServers.graft), Codex (`codex mcp remove graft`), Claude Code's user
#     scope (`claude mcp remove graft -s user`);
#   - what `graft init` writes for every project: hook entries that run
#     graft-hooks.cjs in ~/.claude/settings.json and ~/.codex/hooks.json, a
#     statusLine that runs graft-statusline.cjs, graft's Bash allow entries and
#     its graft/ footer regex, the shims (~/.claude/helpers/graft-*.cjs,
#     ~/.codex/hooks/graft/) and its skill (a skills dir named graft whose
#     SKILL.md says `name: graft`);
#   - the global npm package, then graft's state dir ~/.graft. The package is
#     looked for in the prefix graft actually lives in (a ~/.local or nvm
#     install, not only npm's default), with npm-sudo (the installer's
#     decision) only when that prefix is not writable.
# Repos you ran `graft init` in keep their own graft/ directory and wiring.
#
# Quiet when there is nothing to do; best effort, never fails the run. The
# JSON edits need jq (without it they are skipped) and only touch a file that
# mentions graft at all.
#-------------------------------------------------------------------------------
_graft_json_edit() {
    local file="$1" filter="$2" tmp
    [ -f "$file" ] && grep -q graft "$file" 2>/dev/null || return 1
    tmp="$file.tmp.$$"
    if jq -b "$filter" "$file" >"$tmp" 2>/dev/null &&
        [ "$(jq -b -cS . "$file" 2>/dev/null)" != "$(jq -b -cS . "$tmp" 2>/dev/null)" ]; then
        mv "$tmp" "$file"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

graft_retire() {
    local npm_sudo="${1:-}" done_list="" real prefix pkg sudo_cmd skill
    # An entry is graft's when one of its strings is the graft command or the npm package.
    local is_graft='def is_graft: [.. | strings] | any(test("@nanonets[/\\\\]+graft") or test("(^|[/\\\\])graft(\\.cmd|\\.exe)?$"));'
    # graft init's own fragments in a Claude Code / Codex settings file.
    local hooks_filter='def graft_hook: tojson | contains("graft-hooks.cjs");
        if (.hooks | type) == "object" then
            .hooks |= with_entries(if (.value | type) == "array" and any(.value[]; graft_hook)
                then (.value |= map(select(graft_hook | not))) | select(.value != []) else . end)
            | if .hooks == {} then del(.hooks) else . end
        else . end'
    # shellcheck disable=SC2016 # $k is a jq variable, not a shell one.
    local claude_filter="$hooks_filter"'
        | reduce ("statusLine", "subagentStatusLine") as $k (.;
            if .[$k] != null and (.[$k] | tojson | contains("graft-statusline.cjs")) then del(.[$k]) else . end)
        | if (.permissions.allow | type) == "array"
            then .permissions.allow |= map(select(tostring | test("^Bash\\((graft|npx graft|graft-dev)(:|\\))") | not))
            else . end
        | if (.footerLinksRegexes | type) == "array"
            then .footerLinksRegexes |= map(select(tostring | contains("graft/") | not))
            else . end'

    if command -v jq &>/dev/null; then
        _graft_json_edit "$HOME/.config/opencode/opencode.json" \
            "$is_graft"' if (.mcp.graft? // null) != null and (.mcp.graft | is_graft) then del(.mcp.graft) else . end' &&
            done_list="$done_list OpenCode-MCP"
        _graft_json_edit "$HOME/.gemini/config/mcp_config.json" \
            "$is_graft"' if (.mcpServers.graft? // null) != null and (.mcpServers.graft | is_graft) then del(.mcpServers.graft) else . end' &&
            done_list="$done_list agy-MCP"
        _graft_json_edit "$HOME/.claude/settings.json" "$claude_filter" && done_list="$done_list Claude-hooks"
        _graft_json_edit "$HOME/.codex/hooks.json" "$hooks_filter" && done_list="$done_list Codex-hooks"
    fi
    if command -v codex &>/dev/null && grep -Eq '^\[mcp_servers\.graft\]' "$HOME/.codex/config.toml" 2>/dev/null; then
        net_timeout 60 codex mcp remove graft </dev/null >/dev/null 2>&1 && done_list="$done_list Codex-MCP"
    fi
    if command -v claude &>/dev/null && grep -Eq '@nanonets/graft|"command": *"graft"' "$HOME/.claude.json" 2>/dev/null; then
        net_timeout 60 claude mcp remove graft -s user </dev/null >/dev/null 2>&1 && done_list="$done_list Claude-MCP"
    fi
    for skill in "$HOME/.claude/skills/graft" "$HOME/.agents/skills/graft" \
        "$HOME/.gemini/skills/graft" "$HOME/.gemini/antigravity-cli/skills/graft"; do
        if grep -Eq '^name:[[:space:]]*graft[[:space:]]*$' "$skill/SKILL.md" 2>/dev/null; then
            rm -rf "$skill" && done_list="$done_list skill(${skill#"$HOME/"})"
        fi
    done
    if [ -e "$HOME/.claude/helpers/graft-hooks.cjs" ] || [ -e "$HOME/.claude/helpers/graft-statusline.cjs" ] || [ -d "$HOME/.codex/hooks/graft" ]; then
        rm -rf "$HOME/.claude/helpers/graft-hooks.cjs" "$HOME/.claude/helpers/graft-statusline.cjs" "$HOME/.codex/hooks/graft"
        done_list="$done_list hook-shims"
    fi

    # The package: in the prefix graft resolves from, else npm's default one.
    if command -v npm &>/dev/null && { command -v graft &>/dev/null || [ -d "$HOME/.graft" ]; }; then
        real="$(readlink -f "$(command -v graft 2>/dev/null)" 2>/dev/null || true)"
        prefix=""
        case "$real" in
            */lib/node_modules/@nanonets/graft/*) prefix="${real%/lib/node_modules/@nanonets/graft/*}" ;;
        esac
        [ -n "$prefix" ] || prefix="$(npm prefix -g 2>/dev/null || true)"
        pkg="$prefix/lib/node_modules/@nanonets/graft"
        if [ -n "$prefix" ] && [ -d "$pkg" ]; then
            sudo_cmd=""
            [ -w "$prefix/lib/node_modules" ] || sudo_cmd="$npm_sudo"
            # Not under net_timeout when sudo'd: the installer's sudo is a shell
            # function (dot_sudo), which `timeout` cannot run.
            if [ -n "$sudo_cmd" ]; then
                $sudo_cmd npm uninstall -g --prefix "$prefix" @nanonets/graft --loglevel=error </dev/null >/dev/null 2>&1 || true
            else
                net_timeout 120 npm uninstall -g --prefix "$prefix" @nanonets/graft --loglevel=error </dev/null >/dev/null 2>&1 || true
            fi
            if [ -d "$pkg" ]; then
                warn "Could not uninstall Graft from $prefix - remove it with: ${sudo_cmd:+sudo }npm uninstall -g @nanonets/graft"
            else
                done_list="$done_list npm-package"
            fi
        fi
        # graft's own state (telemetry id, update check): only once the package is gone.
        if [ -n "$prefix" ] && [ ! -d "$pkg" ] && [ -d "$HOME/.graft" ]; then
            rm -rf "${HOME:?}/.graft" && done_list="$done_list ~/.graft"
        fi
    fi
    [ -z "$done_list" ] || info "Retired Graft (dropped from the dotfiles):$done_list"
    return 0
}

#-------------------------------------------------------------------------------
# codex_superpowers_marketplace - print the marketplace that actually carries a
# superpowers plugin on THIS codex, or nothing.
#
# Never hardcode this name. Every consumer here used to pass
# `superpowers@openai-curated-remote`, which does not exist on the installed
# codex: `dot up` ended in "Error: plugin `superpowers` was not found in
# marketplace `openai-curated-remote`", and `dot upgrade` reported "Superpowers
# not installed for Codex" with the real error swallowed by a redirect. The
# name is genuinely volatile - it resolved to `openai-curated` one morning and
# `openai-api-curated` the same evening - so the only reliable source is codex
# itself: `codex plugin list` prints one `<plugin>@<marketplace>` row per
# available plugin. Shared by the installer template and the updater so the two
# can never drift again (the Windows twin is Get-CodexSuperpowersMarketplace in
# ps-skills.ps1); tests/codex_marketplace_contract.sh pins all four.
#
# Callers must tolerate empty output: a codex that cannot list (offline, first
# run, catalog needing auth) is a skip, never a hard failure.
#-------------------------------------------------------------------------------
codex_superpowers_marketplace() {
    command -v codex >/dev/null 2>&1 || return 0
    # The plugin cache names the marketplace the plugin came from
    # (${CODEX_HOME:-~/.codex}/plugins/cache/<marketplace>/superpowers/<version>/.codex-plugin), so
    # a machine that has it once never asks OpenAI's backend again (`codex plugin list`: 25 s on
    # WSL, 2026-10-12, together with the add).
    local d
    for d in "${CODEX_HOME:-$HOME/.codex}"/plugins/cache/*/superpowers/*/.codex-plugin; do
        [ -d "$d" ] || continue
        d="${d%/superpowers/*}"
        printf '%s\n' "${d##*/}"
        return 0
    done
    # `|| true` inside the substitution: the consumers set -e/pipefail, where a
    # codex that cannot list would otherwise abort the whole run on assignment.
    net_timeout 60 codex plugin list 2>/dev/null \
        | sed -n 's/^superpowers@\([^[:space:]]*\).*/\1/p' | head -n 1 || true
}

# codex_superpowers_installed_version - the version of the superpowers plugin codex reports as
# installed; empty and exit 1 when the row says "not installed" or there is no row. Same source
# as the marketplace name: `codex plugin list` prints one
# `superpowers@<marketplace>  <status>  <version>  <source>` row, <status> being
# "installed, enabled", "installed, disabled" or "not installed". `dot up` reads it before
# `codex plugin add`: re-adding an installed plugin re-fetches it (an upgrade, ~15 s on WSL),
# and `dot up` never upgrades.
# codex_superpowers_cached_version - the newest superpowers version Codex has fetched into its
# plugin cache: ${CODEX_HOME:-~/.codex}/plugins/cache/<marketplace>/superpowers/<version>/ with
# a .codex-plugin manifest inside (the path `codex plugin add` prints as "Installed plugin
# root"). A "<version>-<hash>" directory name counts as <version>. Empty when nothing is cached.
codex_superpowers_cached_version() {
    local d v
    for d in "${CODEX_HOME:-$HOME/.codex}"/plugins/cache/*/superpowers/*/; do
        [ -d "$d/.codex-plugin" ] || continue
        v="${d%/}"; v="${v##*/}"; v="${v%%-*}"
        printf '%s\n' "$v"
    done 2>/dev/null | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}
# The cache first: `codex plugin list` asks OpenAI's backend and took 19 s on a WSL `dot up`
# (2026-10-12, the "Codex: Superpowers" sub-mark named it); a cached version answers in no time.
# The CLI decides only when nothing is cached. `dot upgrade` re-adds the plugin regardless, so a
# cache left behind by a removed plugin costs one skipped `dot up` add, repaired on the next sweep.
codex_superpowers_installed_version() {
    command -v codex >/dev/null 2>&1 || return 1
    local v
    v="$(codex_superpowers_cached_version)"
    if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
    v="$(net_timeout 60 codex plugin list 2>/dev/null \
        | sed -nE 's/^superpowers@[^[:space:]]+[[:space:]]+installed(,[[:space:]]*[a-z]+)?[[:space:]]+([^[:space:]]+).*/\2/p' | head -n 1 || true)"
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

# codex_superpowers_catalog_version - the version the marketplace offers, installed or not
# (empty when no marketplace lists the plugin). The official catalog can lag obra/superpowers'
# releases; when it does, `codex plugin add` has nothing newer to install and the report says so.
codex_superpowers_catalog_version() {
    command -v codex >/dev/null 2>&1 || return 1
    net_timeout 60 codex plugin list 2>/dev/null \
        | sed -nE 's/^superpowers@[^[:space:]]+[[:space:]]+(installed(,[[:space:]]*[a-z]+)?|not installed)[[:space:]]+([^[:space:]]+).*/\3/p' | head -n 1 || true
}

# agy_superpowers_installed - 0 when agy lists superpowers among its imported plugins (`agy plugin
# list` prints a JSON document with an "imports" array of {"name": ...}). `dot up` reads it before
# `agy plugin install`, which re-clones the plugin on every run (an upgrade).
agy_superpowers_installed() {
    command -v agy >/dev/null 2>&1 || return 1
    net_timeout 30 agy plugin list 2>/dev/null | grep -Eq '"name":[[:space:]]*"superpowers"'
}

# antigravity_superpowers_version - the version of the plugin agy installed, read from the
# plugin.json under agy's plugin store (best effort: the store moved once already, so every
# `~/.gemini/*/plugins/superpowers` is tried; empty when none is found).
antigravity_superpowers_version() {
    local f
    for f in "$HOME"/.gemini/*/plugins/superpowers/.claude-plugin/plugin.json "$HOME"/.gemini/plugins/superpowers/.claude-plugin/plugin.json; do
        [ -f "$f" ] || continue
        sed -nE 's/^[[:space:]]*"version":[[:space:]]*"([^"]+)".*/\1/p' "$f" | head -n 1
        return 0
    done
    return 1
}

# tool_current_report <name> <version> - "<name> is current (<version>)". Inside a
# tool_current_collect ... tool_current_flush span the line is held and the span's end prints one
# line for all of them: `dot upgrade` printed five "is current" lines in a row for delta, dust,
# procs, lychee and vale (2026-10-12). A tool with news (upgraded, pin behind upstream) keeps its
# own line.
TOOL_CURRENT_LIST=""
TOOL_CURRENT_COLLECTING=0
tool_current_collect() { TOOL_CURRENT_LIST=""; TOOL_CURRENT_COLLECTING=1; }
tool_current_report() {
    if [ "$TOOL_CURRENT_COLLECTING" = 1 ]; then
        TOOL_CURRENT_LIST="$TOOL_CURRENT_LIST, $1 $2"
    else
        echo "   $1 is current ($2)"
    fi
}
tool_current_flush() { # <label>
    TOOL_CURRENT_COLLECTING=0
    [ -n "$TOOL_CURRENT_LIST" ] || return 0
    echo "   $1 current: ${TOOL_CURRENT_LIST#, }"
    TOOL_CURRENT_LIST=""
}

# apt_missing_packages <name...> - the names dpkg does not report as installed, space-separated
# (empty: all present). `apt install -y` of an installed set is not a no-op: it upgrades to the
# candidate version, which `dot up` promises never to do, and it printed "Installing ..." on
# every run (2026-10-12). The installer asks this first and skips the install when nothing is
# missing. No dpkg-query: every name reads as missing, and the install runs as before.
apt_missing_packages() {
    local n st
    command -v dpkg-query >/dev/null 2>&1 || { printf '%s\n' "$*"; return 0; }
    for n in "$@"; do
        st="$(dpkg-query -W -f='${Status}' "$n" 2>/dev/null)" || st=""
        case "$st" in *" installed") ;; *) printf '%s ' "$n" ;; esac
    done | sed 's/ $//'
}

# apt_index_age_hours - whole hours since the newest release file under /var/lib/apt/lists
# (APT_LISTS_DIR for tests) was written, i.e. since the last `apt update`; empty and exit 1 when
# there is none. The installer skips its refresh while the index is younger than a day.
apt_index_age_hours() {
    local dir="${APT_LISTS_DIR:-/var/lib/apt/lists}" newest=0 f m
    for f in "$dir"/*Release "$dir"/*InRelease; do
        [ -f "$f" ] || continue
        m="$(stat -c %Y "$f" 2>/dev/null)" || m=0
        [ "$m" -gt "$newest" ] && newest="$m"
    done
    [ "$newest" -gt 0 ] || return 1
    printf '%s\n' "$(( ($(date +%s) - newest) / 3600 ))"
}

# github_latest_tag <owner/repo> - the newest release-looking tag (X.Y or X.Y.Z, after dropping a
# "<name>-" and/or "v" prefix: v7.0.0, lychee-v0.24.2, 0.20.1), via one `git ls-remote` - no API
# quota, and the same proxy git itself uses. Empty when unreachable. Sorted numerically field by
# field: `sort -V` is GNU-only, and macOS and uutils hosts run this too.
github_latest_tag() {
    net_timeout 20 git ls-remote --tags --refs "https://github.com/$1.git" 2>/dev/null \
        | sed -E 's#.*refs/tags/##; s#^[A-Za-z_-]*-?v?##' \
        | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

#-------------------------------------------------------------------------------
# GitHub-release tools: delta, dust, procs. On Debian/Ubuntu none has an apt
# repo (dust and procs reach the archive only in 25.04), so they come from
# GitHub release assets. Shared by the installer (install when missing) and
# `dot upgrade` (upgrade when behind); on macOS and Windows the same tools
# come from brew and winget, which the upgrade sweep already covers.
#
# Until 2026-10-11 the installer had three near-identical blocks gated on
# `command -v`, with no pin and no upgrade path: `dot upgrade` ended with
# "delta 0.19.2 (0.20.1 available) ... re-run the installer", and re-running
# did nothing because the binary existed. The newest tag comes from
# github_latest_tag (git ls-remote), not the unauthenticated GitHub API the
# blocks used (60 requests/hour, then "Could not determine latest version").
# The download is stall-guarded like Maestro's. Assets are amd64 only.
# tests/github_tools_contract.sh executes these against fake curl/dpkg/sudo.
#
#   github_tool_sync <name> <sudo-cmd> <install|upgrade>
#     install  present: nothing (silent); missing: install the newest release
#     upgrade  missing: nothing (silent); current or ahead: "is current";
#              behind: download + install, "upgraded to"; newest unknown: say so
#     <sudo-cmd> is "sudo", the installer's dot_sudo, or "" as root. Always 0.
#   GITHUB_TOOL_BIN (default /usr/local/bin): where procs' binary lands.
#-------------------------------------------------------------------------------
github_tool_repo() {
    case "$1" in
        delta) echo dandavison/delta ;;
        dust) echo bootandy/dust ;;
        procs) echo dalance/procs ;;
        *) return 1 ;;
    esac
}
# github_tool_asset_url <name> <version> - the amd64 release asset (delta tags carry no "v")
github_tool_asset_url() {
    case "$1" in
        delta) echo "https://github.com/dandavison/delta/releases/download/$2/git-delta_$2_amd64.deb" ;;
        dust) echo "https://github.com/bootandy/dust/releases/download/v$2/du-dust_$2-1_amd64.deb" ;;
        procs) echo "https://github.com/dalance/procs/releases/download/v$2/procs-v$2-x86_64-linux.zip" ;;
        *) return 1 ;;
    esac
}
# github_tool_installed_version <name> - the first X.Y.Z in `--version` (empty: unknown)
github_tool_installed_version() {
    command -v "$1" >/dev/null 2>&1 || return 1
    "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}
# github_tool_install <name> <version> <sudo-cmd> - fetch and install one release; 1 on any
# failure, quietly (the caller does the talking). dpkg's own chatter stays off the terminal.
github_tool_install() {
    local name="$1" ver="$2" run_as="$3" url tmp asset rc=0
    url="$(github_tool_asset_url "$name" "$ver")" || return 1
    tmp="$(mktemp -d)" || return 1
    asset="$tmp/${url##*/}"
    if ! curl -fsSL --connect-timeout 30 --speed-limit 10240 --speed-time 60 -o "$asset" "$url"; then
        rm -rf "$tmp"
        return 1
    fi
    # shellcheck disable=SC2086  # $run_as is "sudo", "dot_sudo" or empty (root): word-split on purpose
    case "$asset" in
        *.deb)
            $run_as env DEBIAN_FRONTEND=noninteractive dpkg -i "$asset" >/dev/null || $run_as apt-get install -f -y >/dev/null || rc=1
            ;;
        *.zip)
            if ! command -v unzip >/dev/null 2>&1; then
                $run_as apt-get install -y unzip >/dev/null 2>&1 || rc=1
            fi
            if [ "$rc" -eq 0 ]; then
                mkdir -p "$tmp/x" && unzip -qo "$asset" -d "$tmp/x" \
                    && $run_as install "$tmp/x/$name" "${GITHUB_TOOL_BIN:-/usr/local/bin}/$name" || rc=1
            fi
            ;;
        *) rc=1 ;;
    esac
    rm -rf "$tmp"
    return "$rc"
}
github_tool_sync() {
    local name="$1" run_as="$2" mode="$3" have latest newest arch
    github_tool_repo "$name" >/dev/null || return 0
    if [ "$mode" = install ]; then
        command -v "$name" >/dev/null 2>&1 && return 0
    else
        command -v "$name" >/dev/null 2>&1 || return 0
    fi
    have="$(github_tool_installed_version "$name" 2>/dev/null || true)"
    arch="$(uname -m)"
    if [ "$arch" != x86_64 ]; then
        if [ "$mode" = install ]; then
            info "$name: only an amd64 asset is published - skipping on $arch"
        else
            echo "   $name: only an amd64 asset is published - left at ${have:-?} on $arch"
        fi
        return 0
    fi
    latest="$(github_latest_tag "$(github_tool_repo "$name")" 2>/dev/null || true)"
    if [ -z "$latest" ]; then
        if [ "$mode" = install ]; then
            warn "Could not determine the latest $name release - skipping"
        else
            echo "   $name: newest release unknown (offline?) - left at ${have:-?}"
        fi
        return 0
    fi
    if [ "$mode" = upgrade ]; then
        if [ -z "$have" ]; then
            echo "   $name: installed version unknown - left as is (newest is $latest)"
            return 0
        fi
        newest="$(printf '%s\n%s\n' "$have" "$latest" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
        if [ "$have" = "$latest" ] || [ "$newest" = "$have" ]; then
            tool_current_report "$name" "$have"
            return 0
        fi
        echo "   Upgrading $name $have -> $latest..."
        if github_tool_install "$name" "$latest" "$run_as"; then
            echo "   $name upgraded to $latest"
        else
            echo "   Warning: $name upgrade failed (download stalled or install error) - still $have"
        fi
        return 0
    fi
    info "Installing $name $latest..."
    github_tool_install "$name" "$latest" "$run_as" \
        || warn "Failed to install $name $latest (download stalled or install error) - continuing"
    return 0
}

#-------------------------------------------------------------------------------
# Pinned release tools: lychee and vale (modern_cli docs tooling). On Linux they
# are release tarballs with no apt package; the installer verifies them against
# the pins in .chezmoidata.yaml (versions.<tool>_version, _sha256_x86_64,
# _sha256_aarch64). Until 2026-10-11 those were literals inside the template:
# nothing bumped them and `dot upgrade` only listed the two names. Now
# scripts/update-versions.sh moves the pins (the weekly auto-update PR) and
# `dot upgrade` reinstalls at the pin. On macOS and Windows both come from brew,
# winget and choco, which the upgrade sweep covers.
# tests/release_tool_pins_contract.sh executes these against fixtures.
#
#   release_tool_repo <name>                 lycheeverse/lychee | errata-ai/vale
#   release_tool_url <name> <version> <arch> the Linux tarball (x86_64|aarch64;
#                                            amd64/arm64 accepted); the installer
#                                            template writes the same URL shape
#   release_tool_member <name> <arch>        the binary's path inside the tarball
#   release_tool_pin_sync <name> <pin> <sha> <sudo-cmd>   (`dot upgrade`)
#     absent: nothing; installed outside GITHUB_TOOL_BIN (/usr/local/bin): not
#     ours, left alone; at the pin: "is current", naming a newer upstream release
#     and the remedy; otherwise download (stall-guarded), verify, reinstall.
#     Always returns 0.
#   release_tool_pins_upgrade <sudo-cmd>     both tools, pins read from chezmoi
#-------------------------------------------------------------------------------
release_tool_arch() {
    case "${1:-$(uname -m)}" in
        x86_64 | amd64) echo x86_64 ;;
        aarch64 | arm64) echo aarch64 ;;
        *) return 1 ;;
    esac
}
release_tool_repo() {
    case "$1" in
        lychee) echo lycheeverse/lychee ;;
        vale) echo errata-ai/vale ;;
        *) return 1 ;;
    esac
}
release_tool_url() {
    local arch
    arch="$(release_tool_arch "$3")" || return 1
    case "$1" in
        lychee) echo "https://github.com/lycheeverse/lychee/releases/download/lychee-v$2/lychee-$arch-unknown-linux-gnu.tar.gz" ;;
        vale)
            if [ "$arch" = x86_64 ]; then
                echo "https://github.com/errata-ai/vale/releases/download/v$2/vale_$2_Linux_64-bit.tar.gz"
            else
                echo "https://github.com/errata-ai/vale/releases/download/v$2/vale_$2_Linux_arm64.tar.gz"
            fi
            ;;
        *) return 1 ;;
    esac
}
release_tool_member() {
    local arch
    arch="$(release_tool_arch "$2")" || return 1
    case "$1" in
        lychee) echo "lychee-$arch-unknown-linux-gnu/lychee" ;;
        vale) echo vale ;;
        *) return 1 ;;
    esac
}
release_tool_pin_sync() {
    local name="$1" pin="$2" sha="$3" run_as="$4" path bindir have arch url member tmp sha_cmd latest note=""
    path="$(command -v "$name" 2>/dev/null)" || return 0
    bindir="${GITHUB_TOOL_BIN:-/usr/local/bin}"
    have="$("$name" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)" || have=""
    if [ "$path" != "$bindir/$name" ]; then
        echo "   $name ${have:-?} at $path is not the dotfiles' install - left alone"
        return 0
    fi
    if [ "$have" = "$pin" ]; then
        latest="$(github_latest_tag "$(release_tool_repo "$name")" 2>/dev/null || true)"
        if [ -n "$latest" ] && [ "$latest" != "$pin" ]; then
            note="; upstream $latest - the weekly auto-update PR bumps the pin"
        fi
        if [ -n "$note" ]; then echo "   $name is current ($pin$note)"; else tool_current_report "$name" "$pin"; fi
        return 0
    fi
    if ! arch="$(release_tool_arch)"; then
        echo "   $name: no Linux asset for $(uname -m) - left at ${have:-?}"
        return 0
    fi
    url="$(release_tool_url "$name" "$pin" "$arch")"
    member="$(release_tool_member "$name" "$arch")"
    sha_cmd="$(sha256_cmd)"
    if [ -z "$sha_cmd" ]; then
        echo "   Warning: $name: no SHA-256 tool found - cannot verify the download, still ${have:-?}"
        return 0
    fi
    if ! tmp="$(mktemp -d)"; then
        echo "   Warning: $name: could not create a temporary directory - still ${have:-?}"
        return 0
    fi
    echo "   Reinstalling $name at pin $pin (installed ${have:-?})..."
    # shellcheck disable=SC2086  # $run_as is "sudo", "dot_sudo" or empty (root): word-split on purpose
    if ! curl -fsSL --connect-timeout 30 --speed-limit 10240 --speed-time 60 -o "$tmp/release.tar.gz" "$url"; then
        echo "   Warning: $name download failed or stalled - still ${have:-?}"
    elif ! printf '%s  %s\n' "$sha" "$tmp/release.tar.gz" | $sha_cmd -c - >/dev/null 2>&1; then
        echo "   Warning: $name checksum verification failed - not installed, still ${have:-?} (pin stale? re-run scripts/update-versions.sh)"
    elif ! tar -xzf "$tmp/release.tar.gz" -C "$tmp" "$member" 2>/dev/null; then
        echo "   Warning: $name: $member not found in the release archive - still ${have:-?}"
    elif ! $run_as install "$tmp/$member" "$bindir/$name"; then
        echo "   Warning: $name install failed - still ${have:-?}"
    else
        echo "   $name reinstalled at pin $pin (was ${have:-?})"
    fi
    rm -rf "$tmp"
    return 0
}
release_tool_pins_upgrade() {
    local run_as="$1" arch name pin sha
    arch="$(release_tool_arch)" || return 0
    if ! command -v chezmoi >/dev/null 2>&1; then
        echo "   lychee, vale: chezmoi not found - pins unknown, left as they are"
        return 0
    fi
    for name in lychee vale; do
        command -v "$name" >/dev/null 2>&1 || continue
        pin="$(chezmoi execute-template "{{ .versions.${name}_version }}" 2>/dev/null || true)"
        sha="$(chezmoi execute-template "{{ .versions.${name}_sha256_${arch} }}" 2>/dev/null || true)"
        if [ -z "$pin" ] || [ -z "$sha" ]; then
            echo "   $name: pin unavailable from chezmoi data - left as is"
            continue
        fi
        release_tool_pin_sync "$name" "$pin" "$sha" "$run_as"
    done
    return 0
}

#-------------------------------------------------------------------------------
# Agent config probes: answers from the agents' own files instead of CLI
# round-trips. A no-op WSL `dot up` (2026-10-11) spent 17 s in
# install_claude_cli - `claude plugin install` 7.8 s and two `claude mcp get`
# probes 8.8 s - plus `serena setup codex` 2 s every run, for facts that sit in
# ~/.claude/plugins/*.json, ~/.claude.json and ~/.codex/config.toml. Twins:
# Test-ClaudeMarketplaceKnown / Test-ClaudePluginInstalled / Test-McpRegistered
# in scripts/lib/ps-skills.ps1. tests/agent_config_probes_contract.sh executes
# both against fixture files and fake CLIs.
#
#   claude_marketplace_known <name>   0 yes, 1 no, 2 unknown (no jq, no file,
#   claude_plugin_installed <id>      unreadable). <id> at USER scope: a project
#                                     or local install is not "installed" here.
#   mcp_registered <claude|codex> <server>  0 yes / 1 no, always definitive:
#                                     the file first, the agent's own `mcp get`
#                                     only when the file cannot say.
# Callers treat 2 as "run the CLI": the old behaviour, so a machine without jq
# or with a moved config loses nothing but the shortcut.
#-------------------------------------------------------------------------------
claude_plugins_dir() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"; }
claude_user_config() {
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then printf '%s\n' "$CLAUDE_CONFIG_DIR/.claude.json"; else printf '%s\n' "$HOME/.claude.json"; fi
}
_jq_bool_rc() { # <rc of jq -e> -> 0 true, 1 false, 2 anything else (parse error, no output)
    case "$1" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}
claude_marketplace_known() {
    local f rc
    f="$(claude_plugins_dir)/known_marketplaces.json"
    command -v jq >/dev/null 2>&1 && [ -f "$f" ] || return 2
    jq -e --arg n "$1" 'type == "object" and has($n)' "$f" >/dev/null 2>&1; rc=$?
    _jq_bool_rc "$rc"
}
claude_plugin_installed() {
    local f rc
    f="$(claude_plugins_dir)/installed_plugins.json"
    command -v jq >/dev/null 2>&1 && [ -f "$f" ] || return 2
    # {"version": 2, "plugins": {...}} today; a flat {id: entries} before that. An entry is one
    # object or a list of them (one per scope/project).
    jq -e --arg id "$1" '(if type == "object" and has("plugins") then .plugins else . end)
        | (.[$id] // []) | (if type == "array" then . else [.] end)
        | map(select(.scope == "user")) | length > 0' "$f" >/dev/null 2>&1; rc=$?
    _jq_bool_rc "$rc"
}
mcp_registered() {
    local agent="$1" server="$2" f rc
    case "$agent" in
        claude)
            f="$(claude_user_config)"
            if command -v jq >/dev/null 2>&1 && [ -f "$f" ]; then
                jq -e --arg s "$server" '(.mcpServers // {}) | has($s)' "$f" >/dev/null 2>&1; rc=$?
                case "$rc" in 0) return 0 ;; 1) return 1 ;; esac
            fi
            claude mcp get "$server" >/dev/null 2>&1
            ;;
        codex)
            f="${CODEX_HOME:-$HOME/.codex}/config.toml"
            if [ -f "$f" ]; then
                grep -Eq "^\[mcp_servers\.\"?${server}\"?\]" "$f"
                return $?
            fi
            codex mcp get "$server" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

# superpowers_latest_version - obra/superpowers' newest release (empty: unreachable).
superpowers_latest_version() { github_latest_tag obra/superpowers; }

# opencode_superpowers_cache_dirs - where OpenCode keeps the superpowers plugin it actually loads.
# For every `plugin` entry in opencode.json OpenCode installs the package into its OWN cache,
# `<cache>/packages/<name>@<spec>/` (package.json + lockfile + node_modules), on the first start
# that sees the entry, and reuses that directory for as long as it exists - a git spec without a
# version is resolved once and pinned by the lockfile from then on. Nothing under
# ~/.config/opencode is consulted for it: the `npm install --prefix ~/.config/opencode` the
# updater ran until 2026-10-10 refreshed a tree OpenCode never read, while the loaded copy sat at
# 6.3.0 for two months. One line per directory (normally one), none when OpenCode has not
# installed it yet.
opencode_superpowers_cache_dirs() {
    local root="${XDG_CACHE_HOME:-$HOME/.cache}/opencode/packages"
    [ -d "$root" ] || return 0
    # The spec is part of the path, slashes included: `superpowers@git+https:/github.com/obra/
    # superpowers.git/package.json` is four levels down, so this is a find, not a glob.
    find "$root" -maxdepth 6 -path '*/superpowers@*' -name package.json -not -path '*/node_modules/*' 2>/dev/null \
        | sed 's#/package.json$##' | sort
    return 0
}

# opencode_superpowers_version - the version in the first cache directory (empty when none).
opencode_superpowers_version() {
    local d
    d="$(opencode_superpowers_cache_dirs | head -n 1)"
    [ -n "$d" ] || return 1
    sed -nE 's/^[[:space:]]*"version":[[:space:]]*"([^"]+)".*/\1/p' "$d/node_modules/superpowers/package.json" 2>/dev/null | head -n 1
}

# opencode_superpowers_refresh <npm> - re-resolve the git dependency in every cache directory to
# upstream HEAD, in place: npm rewrites the lockfile and node_modules there, and OpenCode's next
# start loads the new copy (the directory it checks for is the same one). --ignore-scripts as
# OpenCode's own installer (@npmcli/arborist, ignoreScripts: true) does. Exit 1 when any
# directory failed; npm's own output is shown only then.
opencode_superpowers_refresh() {
    local npm="$1" d out rc=0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if ! out="$(net_timeout 300 "$npm" install --prefix "$d" "superpowers@github:obra/superpowers" --ignore-scripts --allow-git=all --loglevel=error --no-progress --fund=false --audit=false 2>&1)"; then
            printf '%s\n' "$out" >&2
            rc=1
        fi
    done <<<"$(opencode_superpowers_cache_dirs)"
    return "$rc"
}

# claude_superpowers_installs - one "<version>\t<scope>\t<projectPath>" line per superpowers
# install Claude Code knows of (`claude plugin list --json`), the user-scope one included.
# Project- and local-scope installs are per repository and `claude plugin update` run from
# elsewhere never touches them, so they fall behind quietly; the report names them.
# The file first (claude_superpowers_installs_file): Claude writes every install there with its
# version, scope and projectPath, so the answer is instant and the CLI (2 s here, and once stopped
# for 60 s on WSL) is asked only when the file cannot say.
claude_superpowers_installs() {
    local list
    if list="$(claude_superpowers_installs_file)"; then printf '%s\n' "$list"; return 0; fi
    command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
    # Exit 1 when the lookup itself fails (timed out, errored): the caller must not
    # read an empty answer as "not installed" (2026-10-11: a 60 s hang did exactly that
    # on a box with a user-scope 7.0.0 install).
    # net_timeout_tty, not net_timeout (2026-10-11 WSL incident, same class as #355's `claude mcp
    # add`): plain `timeout` runs claude in a new process group, and a tty-touching claude outside
    # the terminal's foreground group gets stopped by the kernel (SIGTTIN) - and once stopped, the
    # stopped `timeout` process can't act on its own alarm to kill it either.
    list="$(net_timeout_tty 60 claude plugin list --json 2>/dev/null)" || return 1
    printf '%s\n' "$list" \
        | jq -b -r '.[]? | select((.id // "") | startswith("superpowers@")) | [(.version // ""), (.scope // ""), (.projectPath // "")] | @tsv' 2>/dev/null
}

# claude_superpowers_installs_file - the same lines from ~/.claude/plugins/installed_plugins.json
# (every marketplace's superpowers@ entry, every scope). Exit 2 when the file cannot answer: no jq,
# no file, unreadable or not the known shape - the caller asks the CLI then. Exit 0 with no output
# means Claude has no superpowers install at all.
claude_superpowers_installs_file() {
    local f
    f="$(claude_plugins_dir)/installed_plugins.json"
    command -v jq >/dev/null 2>&1 && [ -f "$f" ] || return 2
    jq -b -r '(if type == "object" and has("plugins") then .plugins else . end)
        | to_entries[] | select(.key | startswith("superpowers@"))
        | .value | (if type == "array" then . else [.] end) | .[]
        | [(.version // ""), (.scope // ""), (.projectPath // "")] | @tsv' "$f" 2>/dev/null || return 2
}

# claude_superpowers_user_version - the user-scope install's version (the one `dot upgrade`
# updates); empty and exit 1 when there is none or the lookup failed.
claude_superpowers_user_version() {
    local v
    v="$(claude_superpowers_installs | awk -F'\t' '$2 == "user" { print $1; exit }')" || v=""
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

# superpowers_refresh_line <harness> <version> <upstream> <behind> - the outcome line under an
# "Updating Superpowers (<harness>)..." header (the Antigravity and Codex headers printed nothing,
# 2026-10-12): "is current (v)", "is v (upstream unreachable)", or "is v - <behind>" where
# <behind> says why the harness is not at upstream. No version known: nothing printed.
superpowers_refresh_line() {
    local harness="$1" ver="$2" upstream="$3" behind="$4"
    [ -n "$ver" ] || return 0
    if [ -z "$upstream" ]; then
        printf '   Superpowers (%s) is %s (upstream unreachable)\n' "$harness" "$ver"
    elif [ "$ver" = "$upstream" ]; then
        printf '   Superpowers (%s) is current (%s)\n' "$harness" "$ver"
    else
        printf '   Superpowers (%s) is %s - %s\n' "$harness" "$ver" "$behind"
    fi
}

# superpowers_version_line <harness> <version> <upstream> [note] - one report line. A version
# equal to upstream is "current"; an older one says "behind upstream vX" plus the note (why, or
# what to do); an empty version reads as "not installed"; an empty upstream cannot judge.
superpowers_version_line() {
    local harness="$1" ver="$2" upstream="$3" note="${4:-}"
    if [ -z "$ver" ]; then
        printf '   %s: not installed\n' "$harness"
    elif [ -z "$upstream" ]; then
        printf '   %s: %s (upstream unreachable)\n' "$harness" "$ver"
    elif [ "$ver" = "$upstream" ]; then
        printf '   %s: %s (current)\n' "$harness" "$ver"
    else
        printf '   %s: %s - behind upstream v%s%s\n' "$harness" "$ver" "$upstream" "${note:+ ($note)}"
    fi
}

# playwright_chromium_installed - 0 when a COMPLETE Playwright Chromium build is in its browser
# cache (PLAYWRIGHT_BROWSERS_PATH unless it is the literal "0", else ~/.cache/ms-playwright on
# Linux, ~/Library/Caches/ms-playwright on macOS). Playwright marks a finished download with an
# INSTALLATION_COMPLETE file; a chromium-* directory without it is an interrupted one and must
# install again. `dot up` reads this before `npx playwright install-deps` + `install`: both re-ran
# on every apply (~20 s on WSL: install-deps runs its own apt-get update) although `install` only
# downloads when the build is missing, and `dot upgrade` re-runs `install` anyway.
playwright_chromium_installed() {
    local d="${PLAYWRIGHT_BROWSERS_PATH:-}" f
    if [ -z "$d" ] || [ "$d" = 0 ]; then
        case "$(uname -s 2>/dev/null)" in
            Darwin) d="$HOME/Library/Caches/ms-playwright" ;;
            *) d="$HOME/.cache/ms-playwright" ;;
        esac
    fi
    for f in "$d"/chromium-*/; do
        [ -f "$f/INSTALLATION_COMPLETE" ] && return 0
    done
    return 1
}

#-------------------------------------------------------------------------------
# guardrail_console_filter - stdin: the agent-guardrails installer's output; stdout: the
# same, minus the routine status lines.
#
# The installer ends every run with a ~45-line doctor dump (policy, recipes, audit log, hook
# latency, four planes registered, four probe summaries, MCP coverage...). On a healthy run
# that is the same text every time and it buried the lines that matter. The FULL output still
# goes to the apply log (tee, upstream of this filter); the console loses only the lines whose
# shape is on the list below. Everything else stays: a warning, a problem, a verdict, the hook
# latency, and anything this list has never seen - above all an approval prompt or URL, which
# the installer blocks on, so nothing is ever hidden by default.
# DOT_GUARDRAIL_VERBOSE=1 shows everything.
#
# Why perl and not awk (the shape this started as): the installer's approval prompt
# ("Approve register guardrail on planes ...? [y/N] ") carries NO trailing newline, because the
# cursor is meant to sit after it. awk is RECORD-oriented - it hands you a line only once it has
# seen the record separator - so an unterminated prompt sat in awk's input buffer and reached the
# screen only at EOF, i.e. after the installer had already exited. The operator saw a blank
# terminal, typed blind, and the keystrokes did land (the apply completed) with nothing echoed:
# indistinguishable from a hung terminal, and it cost a real session a restart. fflush() does not
# help - that flushes OUTPUT, and the problem is an input record that never terminated. Nor does a
# different RS: "bytes arrived but no newline followed" is a TIMING condition, not a textual one
# (and regex RS is GNU-only, while macOS ships BSD awk).
#
# So this reads BYTES (sysread) instead of records, and uses select() to tell the two kinds of
# incomplete line apart:
#   - a chunk boundary that fell mid-line     -> more bytes arrive at once, so keep buffering;
#   - a prompt the writer is now blocked on   -> the stream goes quiet, so release it immediately.
# GRACE is that "gone quiet" threshold. The blocking select has no timeout while nothing is
# pending, so this never spins. Deliberate trade-off in the release path: a routine line that is
# BOTH split by a chunk boundary AND followed by a >GRACE pause leaks to the console unfiltered.
# That direction is the safe one - showing one extra status line costs nothing, hiding a prompt
# costs a terminal restart - and a released prefix is never re-printed or re-hidden when its
# newline finally arrives (see $shown).
#
# Falls back to an unfiltered pass-through when perl is absent: losing the noise reduction is
# always better than losing the installer's output.
#-------------------------------------------------------------------------------
guardrail_console_filter() {
    if [ "${DOT_GUARDRAIL_VERBOSE:-}" = 1 ]; then cat; return 0; fi
    command -v perl >/dev/null 2>&1 || { cat; return 0; }
    # LC_ALL=C for the same reason dotfiles-doctor.sh pins it on its own perl call: a host whose
    # exported LANG was never generated makes perl print a 15-line "Setting locale failed" block
    # before doing any work, and this filter sits in front of the guardrail output on EVERY
    # `dot up` and `dot upgrade`. Nothing below is locale-sensitive - it is byte-oriented by
    # construction - so pinning C costs nothing and keeps the console clean regardless of host.
    LC_ALL=C perl -e '
        my $GRACE = 0.2;            # seconds of silence that mark an unterminated line a prompt
        my $hidden = 0;
        my $buf = "";               # bytes of the line currently being assembled
        my $shown = 0;              # how many of those bytes are already on screen
        $| = 1;

        # The hide list. Identical in content and order to the awk twin it replaces, and to
        # Select-GuardrailConsoleLine in ps-skills.ps1 - tests/guardrail_console_filter_contract.sh
        # executes all of them against the same captured installer output.
        sub routine {
            my ($l) = @_;
            return 1 if $l =~ /^(cwd|GUARDRAIL_CONFIG|overlay|policy warnings|waivers|audit log|approval mode|operator authenticators|engine health|spawn latency):/;
            return 1 if $l =~ /^web-research enforcement:/;
            return 1 if $l =~ /^recipes /;
            return 1 if $l =~ /^(claude|opencode|antigravity|codex): (already enabled|probes pass|guardrail (hook|hooks|integration) registered)/;
            return 1 if $l =~ /^(claude|opencode|antigravity|codex) settings: guardrail (hook|hooks|integration) registered($|;)/;
            return 1 if $l =~ /^(claude|opencode|antigravity|codex) ownership: (manifest matches settings|no manifest)/;
            return 1 if $l =~ /^antigravity coverage:/;
            return 1 if $l =~ /^  (configured MCP servers|declared MCP tools|uncontracted)/;
            return 1 if $l =~ /^note: codex probes invoke the hook directly/;
            return 1 if $l =~ /^setup: (registering|plane status)/;
            return 1 if $l =~ /^guardrail v[0-9]/;
            return 0;
        }

        # One assembled line. A line whose prefix was already released as a prompt is FINISHED,
        # never re-filtered: those bytes cannot be taken back off the screen.
        sub emit {
            my ($line) = @_;
            if ($shown) { print substr($line, $shown), "\n"; $shown = 0 }
            elsif (routine($line)) { $hidden++ }
            else { print $line, "\n" }
        }

        my $rin = "";
        vec($rin, fileno(STDIN), 1) = 1;
        while (1) {
            # No pending fragment -> block indefinitely (undef); otherwise wake after GRACE so a
            # prompt from a writer that has gone quiet can be released.
            my $timeout = (length($buf) > $shown) ? $GRACE : undef;
            my $ready = select(my $rout = $rin, undef, undef, $timeout);
            if ($ready) {
                my $chunk;
                my $n = sysread(STDIN, $chunk, 65536);
                next unless defined $n;     # EINTR: retry
                last if $n == 0;            # EOF
                $buf .= $chunk;
                while ($buf =~ s/^([^\n]*)\n//) { emit($1) }
            } elsif (length($buf) > $shown) {
                # Gone quiet mid-line: this is a prompt. Show it now, and remember how much of it
                # the screen already has so the completion does not duplicate it.
                print substr($buf, $shown);
                $shown = length($buf);
            }
        }
        emit($buf) if length($buf);         # unterminated final line
        printf "  (%d routine guardrail status line(s) hidden; full output in the apply log, or DOT_GUARDRAIL_VERBOSE=1)\n", $hidden if $hidden > 0;
    '
}

#-------------------------------------------------------------------------------
# skills_remove_retired <list-file> - remove skills listed in
# scripts/retired-agent-skills.txt (`<skill> <source>` per line) from every agent
# directory, the OpenCode command shim we generated, and the skills CLI lock.
#
# Only when the lock records that exact source for the skill: a skill of the same
# name written by hand (no lock entry, or another source) is never touched. The
# name is restricted to [a-z0-9-] so a malformed list cannot reach another path.
# Best effort and idempotent; needs jq (without it nothing is removed).
#-------------------------------------------------------------------------------
skills_remove_retired() {
    local list="${1:-}" lock="$HOME/.agents/.skill-lock.json" name source shim tmp
    [ -r "$list" ] && [ -r "$lock" ] && command -v jq &>/dev/null || return 0
    while read -r name source _; do
        case "$name" in '' | '#'*) continue ;; esac
        [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || continue
        [ "$(jq -b -r --arg n "$name" '.skills[$n].source // empty' "$lock" 2>/dev/null)" = "$source" ] || continue
        rm -rf "${HOME:?}/.claude/skills/$name" "${HOME:?}/.agents/skills/$name" "${HOME:?}/.gemini/antigravity-cli/skills/$name"
        shim="$HOME/.config/opencode/commands/$name.md"
        if [ -f "$shim" ] && grep -Fq 'managed-by: chezmoi-curated-skills' "$shim" 2>/dev/null; then
            rm -f "$shim"
        fi
        tmp="$lock.tmp.$$"
        if jq --arg n "$name" 'del(.skills[$n])' "$lock" >"$tmp" 2>/dev/null; then
            mv "$tmp" "$lock"
        else
            rm -f "$tmp"
        fi
        info "Removed retired skill: $name"
    done <"$list"
    return 0
}

skills_source_state() {
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/skills-sources"
}

# Every source key a run checked (skills_up_to_date appends); skills_prune_state keeps those.
SKILLS_SEEN_KEYS=()
SKILLS_STALE_REASON=""

# skills_remote_head <owner/repo> - upstream HEAD, '' when unknown. Answered from the cache
# skills_prefetch_heads filled when it has the repo (one parallel round for every source instead
# of eight sequential ls-remotes - two repos were asked twice), else asked now.
SKILLS_HEAD_DIR=""
skills_remote_head() {
    local repo="$1" cached
    if [ -n "$SKILLS_HEAD_DIR" ]; then
        cached="$SKILLS_HEAD_DIR/${repo//\//_}"
        if [ -f "$cached" ]; then cat "$cached"; return 0; fi
    fi
    net_timeout 20 git ls-remote "https://github.com/$repo.git" HEAD 2>/dev/null | cut -f1 | head -n 1
}

# skills_prefetch_heads <owner/repo...> - ask every repo at once, in the background; each answer
# (possibly empty: unreachable) lands in a file skills_remote_head reads. Best effort.
skills_prefetch_heads() {
    local repo pids=()
    SKILLS_HEAD_DIR="$(mktemp -d 2>/dev/null)" || { SKILLS_HEAD_DIR=""; return 0; }
    for repo in "$@"; do
        ( net_timeout 20 git ls-remote "https://github.com/$repo.git" HEAD 2>/dev/null | cut -f1 | head -n 1 >"$SKILLS_HEAD_DIR/${repo//\//_}" ) &
        pids+=("$!")
    done
    # Only these: a bare `wait` also waits for every other background job of the caller - the
    # installer's sudo keep-alive loop never ends (it hung `dot up` on WSL, 2026-10-07), and dot
    # upgrade's VS Code extension update can take minutes.
    # A failed lookup is fine (it reads as "unknown" and the source reinstalls); `wait <pids>`
    # returns the lookups' status, which must not end a `set -e` caller.
    wait "${pids[@]}" || true
}

skills_up_to_date() {
    local repo="$1"; shift
    local skill recorded
    SKILLS_PENDING_KEY="$repo|$*|${AGENTS[*]}"
    SKILLS_SEEN_KEYS+=("$SKILLS_PENDING_KEY")
    SKILLS_PENDING_HEAD="$(skills_remote_head "$repo")" || SKILLS_PENDING_HEAD=""
    # Why the answer is "not current", printed with the install line (twin of
    # $script:SkillsStaleReason): a reinstall on every run then says why.
    SKILLS_STALE_REASON=""
    if [ "${DOT_SKILLS_FORCE:-}" = 1 ]; then SKILLS_STALE_REASON="DOT_SKILLS_FORCE=1"; return 1; fi
    for skill in "$@"; do
        if [ ! -f "$HOME/.claude/skills/$skill/SKILL.md" ]; then SKILLS_STALE_REASON="$skill missing from ~/.claude/skills"; return 1; fi
        if [ ! -f "$HOME/.agents/skills/$skill/SKILL.md" ]; then SKILLS_STALE_REASON="$skill missing from ~/.agents/skills"; return 1; fi
    done
    if [ -z "$SKILLS_PENDING_HEAD" ]; then SKILLS_STALE_REASON="upstream unreachable"; return 1; fi
    recorded="$(awk -F'\t' -v k="$SKILLS_PENDING_KEY" '$1 == k { print $2 }' "$(skills_source_state)" 2>/dev/null || true)"
    if [ -z "$recorded" ]; then SKILLS_STALE_REASON="no install recorded for this selection"; return 1; fi
    if [ "$recorded" != "$SKILLS_PENDING_HEAD" ]; then SKILLS_STALE_REASON="upstream changed"; return 1; fi
}

# skills_prune_state - drop state lines this run superseded. A source key is
# repo|skills|agents, so changing a selection (a skill added or retired) leaves the old key
# behind for good. For every repo this run checked, keep only the keys it checked; lines for
# repos it did not touch are never removed. Best effort: the state is only a cache, and a
# wrongly dropped line costs one reinstall.
skills_prune_state() {
    local state tmp seen
    [ "${#SKILLS_SEEN_KEYS[@]}" -gt 0 ] || return 0
    state="$(skills_source_state)"
    [ -f "$state" ] || return 0
    seen="$(mktemp 2>/dev/null)" || return 0
    printf '%s\n' "${SKILLS_SEEN_KEYS[@]}" >"$seen"
    tmp="$state.tmp.$$"
    if awk -F'\t' -v seenfile="$seen" '
        BEGIN { while ((getline k < seenfile) > 0) { keys[k] = 1; split(k, p, "|"); repos[p[1]] = 1 } }
        { split($1, q, "|"); if (!(q[1] in repos) || ($1 in keys)) print }
    ' "$state" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$state" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
    rm -f "$seen"
    return 0
}

# skills_record_source - after a successful add: store the HEAD that
# skills_up_to_date saw for the same key. Best effort (state is only a cache).
skills_record_source() {
    [ -n "${SKILLS_PENDING_HEAD:-}" ] || return 0
    local state tmp
    state="$(skills_source_state)"
    mkdir -p "${state%/*}" 2>/dev/null || return 0
    tmp="$state.tmp.$$"
    {
        awk -F'\t' -v k="$SKILLS_PENDING_KEY" '$1 != k' "$state" 2>/dev/null || true
        printf '%s\t%s\n' "$SKILLS_PENDING_KEY" "$SKILLS_PENDING_HEAD"
    } >"$tmp"
    mv "$tmp" "$state" 2>/dev/null || rm -f "$tmp"
    return 0
}

# skills_cli <seconds> <cmd...> - net_timeout for a `skills` CLI call. Each call prints a banner, a
# summary box and a security table (about 35 lines, eight calls per run) that say nothing a
# "installed" line does not. Shown only when the call fails, or with DOT_SKILLS_VERBOSE=1.
skills_cli() {
    local secs="$1" out rc=0
    shift
    if [ "${DOT_SKILLS_VERBOSE:-}" = 1 ]; then
        net_timeout "$secs" "$@"
        return
    fi
    out="$(mktemp)"
    net_timeout "$secs" "$@" >"$out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then cat "$out" >&2; fi
    rm -f "$out"
    return "$rc"
}

skills_add_all() {
    # The npx wrapper is identical for every consumer, so the function that
    # uses it owns the definition (it used to sit in each consumer and drift).
    local -a SK=(npx --yes --loglevel=error skills@latest)
    # Every source's upstream HEAD in one parallel round (see skills_remote_head).
    skills_prefetch_heads mattpocock/skills anthropics/skills vercel-labs/skills vercel-labs/agent-browser CtrlCarlitos/skills Leonxlnx/taste-skill

    # Matt Pocock's engineering/productivity skills - 12 installed as-is (pr and retro added
    # 2026-10-05, #269; the count below is the array length, never a literal).
    # teach + writing-for-agents live under skills/productivity/, the rest under
    # skills/engineering/; the CLI resolves by skill name, not path (grilling and
    # handoff are already productivity/ skills that resolve fine here).
    local -a mp_skills=(codebase-design domain-modeling grill-with-docs improve-codebase-architecture
        prototype research grilling handoff teach writing-for-agents pr retro)
    if skills_up_to_date mattpocock/skills "${mp_skills[@]}"; then
        info "Matt Pocock's skills: up to date"
        record_cli_result installed "${#mp_skills[@]}"
    elif info "Installing Matt Pocock's skills (Claude Code / OpenCode / Antigravity)..." && skills_cli 300 "${SK[@]}" add mattpocock/skills \
        -s "${mp_skills[@]}" \
        -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed "${#mp_skills[@]}"
        info "Matt Pocock's skills: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed "${#mp_skills[@]}"
        warn "Matt Pocock skills install failed or timed out - continuing"
    fi

    # code-review -> mp-code-review. The `skills` CLI has no rename flag, so
    # stage a renamed copy with its `name:` frontmatter patched and install
    # that local directory. "mp-" keeps it distinct from this repo's own
    # /code-review command and Superpowers' receiving-code-review skill.
    if skills_up_to_date mattpocock/skills mp-code-review; then
        info "mp-code-review: up to date"
        record_cli_result installed 1
    else
        local sk_tmp; sk_tmp="$(mktemp -d)"
        # net_timeout: same wall-clock contract as every other network fetch here
        # (docs/tool-parity.md's Network-step timeouts section includes git clones).
        if net_timeout 60 git clone --quiet --depth 1 https://github.com/mattpocock/skills "$sk_tmp/repo" 2>/dev/null; then
            local src="$sk_tmp/repo/skills/engineering/code-review"
            [[ -d "$src" ]] || src="$sk_tmp/repo/code-review"
            if [[ -d "$src" ]]; then
                mkdir -p "$sk_tmp/stage/mp-code-review"
                cp -r "$src/." "$sk_tmp/stage/mp-code-review/"
                local skf="$sk_tmp/stage/mp-code-review/SKILL.md"
                if [[ -f "$skf" ]]; then
                    # portable in-place edit (GNU and BSD sed differ on -i).
                    # Guarded: a bare failing `sed ... && mv` here would trip
                    # set -e and abort the whole run - frontend-design, Playwright,
                    # act, desktop apps and shell setup all come after this.
                    sed 's/^name:[[:space:]].*/name: mp-code-review/' "$skf" > "$skf.tmp" && mv "$skf.tmp" "$skf"
                    if skills_cli 120 "${SK[@]}" add "$sk_tmp/stage" -s mp-code-review -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
                        record_cli_result installed 1
                        skills_record_source
                        info "mp-code-review: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
                    else
                        record_cli_result failed 1
                        warn "mp-code-review skill install failed - continuing"
                    fi
                else
                    record_cli_result skipped 1
                    warn "SKILL.md missing from staged code-review - upstream layout changed? Skipping mp-code-review."
                fi
            else
                record_cli_result skipped 1
                warn "code-review skill dir not found in mattpocock/skills - upstream layout changed?"
            fi
        else
            record_cli_result failed 1
            warn "mp-code-review skill source clone failed or timed out - continuing"
        fi
        rm -rf "$sk_tmp"
    fi

    # Anthropic's frontend-design skill - distinctive visual direction for new UI.
    if skills_up_to_date anthropics/skills frontend-design; then
        info "frontend-design: up to date"
        record_cli_result installed 1
    elif info "Installing Anthropic's frontend-design skill..." && skills_cli 300 "${SK[@]}" add anthropics/skills -s frontend-design -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
        info "frontend-design: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed 1
        warn "frontend-design skill install failed or timed out - continuing"
    fi

    # find-skills (vercel-labs/skills, 3.4M installs on skills.sh) - lets an
    # agent search and install skills from skills.sh mid-session.
    if skills_up_to_date vercel-labs/skills find-skills; then
        info "find-skills: up to date"
        record_cli_result installed 1
    elif info "Installing find-skills skill..." && skills_cli 300 "${SK[@]}" add vercel-labs/skills -s find-skills -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
        info "find-skills: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed 1
        warn "find-skills skill install failed or timed out - continuing"
    fi

    # agent-browser (vercel-labs/agent-browser, 843.8K installs) - browser
    # automation: navigate, click, fill, scrape, screenshot.
    if skills_up_to_date vercel-labs/agent-browser agent-browser; then
        info "agent-browser: up to date"
        record_cli_result installed 1
    elif info "Installing agent-browser skill..." && skills_cli 300 "${SK[@]}" add vercel-labs/agent-browser -s agent-browser -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
        info "agent-browser: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed 1
        warn "agent-browser skill install failed or timed out - continuing"
    fi

    # skill-creator (CtrlCarlitos/skills) - our drop-in fork of Anthropic's skill-creator with Windows fixes (pipe reader, UTF-8 file I/O, --project-root); pinned upstream commit + patch queue in that repo, drop when anthropics/skills#1827 lands.
    # Upstream was: (anthropics/skills, 380K installs) - Anthropic's
    # skill-authoring lifecycle tool with benchmarks and eval viewer.
    if skills_up_to_date CtrlCarlitos/skills skill-creator; then
        info "skill-creator: up to date"
        record_cli_result installed 1
    elif info "Installing Anthropic's skill-creator skill..." && skills_cli 300 "${SK[@]}" add CtrlCarlitos/skills -s skill-creator -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
        info "skill-creator: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed 1
        warn "skill-creator skill install failed or timed out - continuing"
    fi

    # taste skill (Leonxlnx/taste-skill, MIT): design-taste-frontend infers a
    # visual direction behind tunable dials plus an anti-slop checklist, for new
    # pages and existing ones alike. Chosen 2026-09-24 for function, not
    # popularity (docs/skills-install-strategy.md). Upstream folded its
    # companion, redesign-existing-projects, into it on 2026-10-19 (the name is
    # in retired-agent-skills.txt). Overlaps anthropics/frontend-design on
    # purpose; drop one if they double-trigger.
    if skills_up_to_date Leonxlnx/taste-skill design-taste-frontend; then
        info "taste skills: up to date"
        record_cli_result installed 1
    elif info "Installing taste skill (design-taste-frontend)..." && skills_cli 300 "${SK[@]}" add Leonxlnx/taste-skill -s design-taste-frontend -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
        info "taste skills: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed 1
        warn "taste skills install failed or timed out - continuing"
    fi

    # code-search (CtrlCarlitos/skills, MIT): our own search-escalation skill.
    # Probes once per session which tools can see the code (a repo graph when
    # one is built, serena LSP, rg, grep), routes each question down that
    # ladder, and stops re-asking a semantic tool after one empty result.
    # Added 2026-09-24 after graft's (since removed) "graph first for ANY
    # task" block cost every session in this repo two empty queries (the graph
    # covers one Lua file here) - docs/skills-install-strategy.md.
    if skills_up_to_date CtrlCarlitos/skills code-search; then
        info "code-search: up to date"
        record_cli_result installed 1
    elif info "Installing code-search skill..." && skills_cli 300 "${SK[@]}" add CtrlCarlitos/skills -s code-search -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
        info "code-search: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed 1
        warn "code-search skill install failed or timed out - continuing"
    fi

    # (writing-great-skills removed 2026-09-14: mattpocock renamed it upstream to
    #  writing-for-agents, which is already in the batch above — the old name
    #  failed silently on every run.)

    skills_prune_state
    if [ -n "$SKILLS_HEAD_DIR" ]; then rm -rf "$SKILLS_HEAD_DIR"; SKILLS_HEAD_DIR=""; fi
}

#-------------------------------------------------------------------------------
# verify_curated_skill_targets <claude_reported> <opencode_reported> <codex_reported>
# - the post-install verification pass over the catalog
# (scripts/curated-agent-skills.txt), shared verbatim.
#
# Arguments: the CLI-phase tallies from the caller's skills_add_all phase -
# a target is only counted "failed" when its CLI phase actually ran. Passed
# explicitly rather than via dynamic scope so the data flow stays visible.
#
# Caller-provided (dynamic scope):
#   catalog         - path to the curated catalog
#   claude_installed / opencode_installed / codex_installed /
#   antigravity_installed / antigravity_skipped / antigravity_failed - tallies
#   info/warn - provided by this file
#
# A successful CLI exit only means its copy operation completed: an agent is
# counted installed only after its supported discovery target exists, the
# Claude copy is fanned out to Antigravity with backup/restore, and a
# managed-by marker guards the OpenCode command shim.
# catalog is resolved from the caller's scope (the installer renders its
# sourceDir; the updater derives it from BASH_SOURCE) - invisible to static
# analysis by design, hence the whole-function suppression.
# shellcheck disable=SC2154
#-------------------------------------------------------------------------------
verify_curated_skill_targets() {
    local claude_reported="$1" opencode_reported="$2" codex_reported="$3"
    local skill source target tmp backup command_dir command_file antigravity_status
    while IFS= read -r skill || [[ -n "$skill" ]]; do
        [[ -z "$skill" || "$skill" == \#* ]] && continue

        # Count an agent installed only after its supported discovery target
        # exists; the CLI exit status alone is insufficient.
        if [[ -f "$HOME/.claude/skills/$skill/SKILL.md" ]]; then
            claude_installed=$((claude_installed + 1))
        elif ((claude_reported > 0)); then
            claude_failed=$((claude_failed + 1))
        fi
        if [[ -f "$HOME/.agents/skills/$skill/SKILL.md" ]]; then
            opencode_installed=$((opencode_installed + 1))
            codex_installed=$((codex_installed + 1))
        else
            if ((opencode_reported > 0)); then
                opencode_failed=$((opencode_failed + 1))
            fi
            if ((codex_reported > 0)); then
                codex_failed=$((codex_failed + 1))
            fi
        fi

        source="$HOME/.claude/skills/$skill"
        target="$HOME/.gemini/antigravity-cli/skills/$skill"
        if [[ -f "$source/SKILL.md" ]]; then
            antigravity_status=failed
            mkdir -p "$HOME/.gemini/antigravity-cli/skills"
            tmp="$(mktemp -d "$HOME/.gemini/antigravity-cli/skills/.${skill}.tmp.XXXXXX")"
            if cp -R "$source/." "$tmp/"; then
                backup="$(mktemp -d "$HOME/.gemini/antigravity-cli/skills/.${skill}.backup.XXXXXX")"
                if ! rmdir "$backup"; then
                    rm -rf "$tmp"
                    warn "Failed to prepare Antigravity skill backup: $skill"
                elif [[ -e "$target" || -L "$target" ]]; then
                    if mv "$target" "$backup"; then
                        if mv "$tmp" "$target"; then
                            rm -rf "$backup"
                            antigravity_status=installed
                        else
                            rm -rf "$tmp"
                            warn "Failed to promote curated skill for Antigravity: $skill"
                            mv "$backup" "$target" || warn "Failed to restore Antigravity skill backup: $skill"
                        fi
                    else
                        rm -rf "$tmp"
                        warn "Failed to back up existing Antigravity skill: $skill"
                    fi
                elif mv "$tmp" "$target"; then
                    antigravity_status=installed
                else
                    rm -rf "$tmp"
                    warn "Failed to promote curated skill for Antigravity: $skill"
                fi
            else
                rm -rf "$tmp"
                warn "Failed to copy curated skill for Antigravity: $skill"
            fi
        else
            antigravity_status=skipped
            warn "Claude skill missing; skipping Antigravity copy: $skill"
        fi

        case "$antigravity_status" in
            installed) ((antigravity_installed += 1)) ;;
            skipped) ((antigravity_skipped += 1)) ;;
            *) ((antigravity_failed += 1)) ;;
        esac

        command_dir="$HOME/.config/opencode/commands"
        command_file="$command_dir/$skill.md"
        source="$HOME/.agents/skills/$skill"
        if [[ -f "$source/SKILL.md" ]]; then
            mkdir -p "$command_dir"
            if [[ -f "$command_file" ]] && ! grep -Fq 'managed-by: chezmoi-curated-skills' "$command_file"; then
                warn "OpenCode command is user-managed; leaving unchanged: $command_file"
            else
                tmp="$(mktemp "$command_dir/.${skill}.tmp.XXXXXX")"
                {
                    printf '%s\n' '<!-- managed-by: chezmoi-curated-skills -->' '---'
                    printf 'description: Run the %s skill\n' "$skill"
                    printf '%s\n' '---'
                    # shellcheck disable=SC2016 # OpenCode expands this placeholder at command invocation.
                    printf 'Load the native `%s` skill with the skill tool, then follow it for: $ARGUMENTS\n' "$skill"
                } > "$tmp"
                mv "$tmp" "$command_file"
            fi
        elif [[ -f "$command_file" ]] && grep -Fq 'managed-by: chezmoi-curated-skills' "$command_file"; then
            rm -f "$command_file"
        fi
    done < "$catalog"
}
