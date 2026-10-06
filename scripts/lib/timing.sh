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
        for i in "${!DOT_TIMING_NAMES[@]}"; do
            [ "${DOT_TIMING_SECS[$i]}" -ge "$min" ] && printf '%s %s\n' "${DOT_TIMING_SECS[$i]}" "${DOT_TIMING_NAMES[$i]}"
        done | sort -rn -s
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
