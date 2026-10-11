#!/bin/bash
# scripts/lib/netspeed.sh - say so when the link is slow, before dot upgrade's big downloads.
# Twin of Invoke-DotNetworkCheck in scripts/lib/ps-common.ps1.
#
# A Windows `dot upgrade` spent 21 of its 23 minutes on one winget package while the ISP was
# degraded (2026-10-11) and nothing said why. The check times a 10 MB download and, under
# DOT_SLOW_MBPS (default 50) Mbit/s, tells the operator; at a terminal they may skip the package
# sweep or stop. Unmeasurable (no curl, offline, blocked endpoint) never blocks anything.
#   DOT_SPEED_CHECK=0      turn it off          DOT_SPEED_TEST_URL=<url>   another endpoint
#   dot_net_speed_mbps     prints Mbit/s (one decimal); fails when it cannot measure
#   net_speed_check        sets NET_CHOICE to continue | skip | stop (needs dot_ask, lib/timing.sh)
# shellcheck disable=SC2034  # NET_CHOICE is read by the sourcing script
# An unattended run (--yes, or no terminal) always continues.

dot_net_speed_mbps() {
    local url="${DOT_SPEED_TEST_URL:-https://speed.cloudflare.com/__down?bytes=10000000}" raw
    command -v curl >/dev/null 2>&1 || return 1
    raw="$(curl -sL -o /dev/null -w '%{speed_download}|%{size_download}' --connect-timeout 5 --max-time 15 "$url" 2>/dev/null)" || true
    case "$raw" in *'|'*) ;; *) return 1 ;; esac
    awk -v raw="$raw" 'BEGIN { split(raw, a, "|"); if (a[2] + 0 <= 0) exit 1; printf "%.1f\n", a[1] * 8 / 1000000 }'
}

net_speed_check() {
    local threshold="${DOT_SLOW_MBPS:-50}" mbps answer=""
    NET_CHOICE='continue'
    [ "${DOT_SPEED_CHECK:-}" = 0 ] && return 0
    case "$threshold" in '' | *[!0-9]*) threshold=50 ;; esac
    if ! mbps="$(dot_net_speed_mbps)"; then
        echo "  Network speed: could not be measured (the check is skipped)."
        return 0
    fi
    if awk -v m="$mbps" -v t="$threshold" 'BEGIN { exit !(m + 0 >= t + 0) }'; then
        echo "  Network speed: $mbps Mbit/s."
        return 0
    fi
    echo "  Network is slow: $mbps Mbit/s (under $threshold). Large downloads (apt, brew) may take a long time."
    if [ "${DOTUPGRADE_YES:-0}" = 1 ] || ! { [ -t 0 ] && [ -t 1 ]; }; then
        echo "  Continuing (unattended)."
        return 0
    fi
    printf '  [c] continue with everything (default)  [s] skip the system package sweep  [q] stop%s: ' "$(dot_ask_hint)"
    dot_timing_wait 2>/dev/null || true
    dot_ask answer
    dot_timing_resume 2>/dev/null || true
    case "$answer" in
        [sS]*) NET_CHOICE='skip' ;;
        [qQ]*) NET_CHOICE='stop' ;;
    esac
    return 0
}
