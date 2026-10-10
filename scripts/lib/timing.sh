#!/usr/bin/env bash
# scripts/lib/timing.sh - where the time of a `dot upgrade` goes.
#
# A Windows `dot upgrade` took 13m03s and nothing said which part. The scripts now put a
# mark at the start of each section; the end of the run prints the slowest ones and appends
# the same line to ~/.local/state/dotfiles/upgrade.log, so one run can be compared with the
# next. Template-free plain bash, sourced by scripts/dotupgrade.sh and scripts/update_ai_tools.sh.
# Twin of Add-DotTimingMark / Write-DotTimingSummary in scripts/lib/ps-common.ps1.
#
#   dot_timing_mark <name>           the previous section ends now, <name> starts now
#   dot_timing_summary <title>       close the open section, print "Timings (<title>, <total>): ..."
#
# Only sections of DOT_TIMING_MIN_SECONDS (default 5) or more are listed, slowest first, at most
# six; the total always is. Seconds resolution is enough for a minutes-long upgrade.

DOT_TIMING_NAMES=()
DOT_TIMING_SECS=()
DOT_TIMING_LAST=""
DOT_TIMING_FROM=0
DOT_TIMING_START=0

dot_timing_now() { date +%s; }

dot_timing_mark() {
    local now
    now="$(dot_timing_now)"
    if [ "$DOT_TIMING_START" = 0 ]; then DOT_TIMING_START="$now"; fi
    if [ -n "$DOT_TIMING_LAST" ]; then
        DOT_TIMING_NAMES+=("$DOT_TIMING_LAST")
        DOT_TIMING_SECS+=("$((now - DOT_TIMING_FROM))")
    fi
    DOT_TIMING_LAST="$1"
    DOT_TIMING_FROM="$now"
}

# 125 -> 2m05s, 45 -> 45s
# dot_timing_wait [name] / dot_timing_resume around a prompt: the time spent answering is its
# own section ("your answers" unless named - the installer's sudo prime names it "sudo
# password"), so it is not counted as the work it interrupted. No-ops when no section is open
# (callers outside a timed run, tests).
DOT_TIMING_RESUME=""
dot_timing_wait() {
    [ -n "$DOT_TIMING_LAST" ] || return 0
    DOT_TIMING_RESUME="$DOT_TIMING_LAST"
    dot_timing_mark "${1:-your answers}"
}
dot_timing_resume() {
    [ -n "$DOT_TIMING_RESUME" ] || return 0
    dot_timing_mark "$DOT_TIMING_RESUME"
    DOT_TIMING_RESUME=""
}

# A question nobody is there to answer must not hold the run: a dot upgrade sat 26 minutes on
# "Stop them so everything upgrades now?" while its operator was out (2026-10-07).
#   dot_ask_hint       " (60s)" - append to a prompt so the wait is visible
#   dot_ask <var>      read one answer into <var>: "y" without asking under --yes
#                      (DOTUPGRADE_YES=1); after DOTUPGRADE_PROMPT_TIMEOUT seconds (default
#                      60, 0 = wait as long as it takes) the empty answer - every question's
#                      safe default (keep, defer).
dot_ask_timeout() {
    local t="${DOTUPGRADE_PROMPT_TIMEOUT:-60}"
    case "$t" in '' | *[!0-9]*) t=60 ;; esac
    printf '%s' "$t"
}
dot_ask_hint() {
    local t
    t="$(dot_ask_timeout)"
    [ "${DOTUPGRADE_YES:-0}" = 1 ] || [ "$t" = 0 ] || printf ' (%ss)' "$t"
}
dot_ask() {
    local __ans="" __t __rc=0
    if [ "${DOTUPGRADE_YES:-0}" = 1 ]; then
        echo "y (--yes)" >&2
        printf -v "$1" '%s' y
        return 0
    fi
    __t="$(dot_ask_timeout)"
    if [ "$__t" -gt 0 ]; then
        read -r -t "$__t" __ans || __rc=$?
        if [ "$__rc" -gt 128 ]; then
            echo >&2
            echo "  (no answer in ${__t}s - taking the default: no)" >&2
            __ans=""
        fi
    else
        read -r __ans || __ans=""
    fi
    printf -v "$1" '%s' "$__ans"
}

dot_timing_format() {
    local s="$1"
    if [ "$s" -ge 60 ]; then printf '%dm%02ds' "$((s / 60))" "$((s % 60))"; else printf '%ds' "$s"; fi
}

dot_timing_summary() {
    local title="${1:-run}" min="${DOT_TIMING_MIN_SECONDS:-5}" now total i line="" shown=0 log
    now="$(dot_timing_now)"
    if [ -n "$DOT_TIMING_LAST" ]; then
        DOT_TIMING_NAMES+=("$DOT_TIMING_LAST")
        DOT_TIMING_SECS+=("$((now - DOT_TIMING_FROM))")
        DOT_TIMING_LAST=""
    fi
    [ "${#DOT_TIMING_NAMES[@]}" -gt 0 ] || return 0
    total=$((now - DOT_TIMING_START))
    # "<seconds> <name>" per line, slowest first
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        [ "$shown" -lt 6 ] || break
        line="${line:+$line, }${row#* } $(dot_timing_format "${row%% *}")"
        shown=$((shown + 1))
    done < <(
        # a section can recur (work resumes after "your answers"): its parts add up
        for i in "${!DOT_TIMING_NAMES[@]}"; do
            printf '%s\t%s\n' "${DOT_TIMING_NAMES[$i]}" "${DOT_TIMING_SECS[$i]}"
        done | awk -F'\t' -v min="$min" '
            { if (!($1 in s)) order[++n] = $1; s[$1] += $2 }
            END { for (i = 1; i <= n; i++) if (s[order[i]] >= min) print s[order[i]] " " order[i] }' | sort -rn -s
    )
    local text total_text
    total_text="$(dot_timing_format "$total")"
    text="Timings ($title, $total_text)${line:+: $line}"
    echo "  $text"
    log="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/upgrade.log"
    if mkdir -p "${log%/*}" 2>/dev/null; then
        printf '=== %s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$text" >>"$log" 2>/dev/null || true
    fi
    DOT_TIMING_NAMES=()
    DOT_TIMING_SECS=()
    DOT_TIMING_START=0
    return 0
}
