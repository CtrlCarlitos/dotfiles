#!/usr/bin/env bash
#
# select-packages.sh — interactive package-group menu (gum), persisting the
# 12-group selection to [data.packages] in ~/.config/chezmoi/chezmoi.toml.
#
# Run standalone to re-choose groups at any time, or from install.sh before
# `chezmoi init --apply` (spec §4). Design contracts:
#
#   - CI-safe: without a TTY on stdin or gum on PATH this is a no-op that
#     exits 0 printing "skipping menu" — pre-seeded CI configs never prompt.
#   - The menu OWNS [data.packages]: a rewrite replaces the whole section
#     (hand-edited keys inside it are intentionally overwritten — re-running
#     the menu means re-choosing). Everything outside the section is
#     byte-preserved (accounts etc.).
#   - On rewrite the section is re-emitted at EOF (the old block is cut and a
#     fresh one appended). TOML tables are order-independent, so this is
#     valid; just be aware the block moves to the end of the file.
#   - Presets are pre-check sets for the menu only, never persisted.
#
# gum invocation shapes (verified against installed gum 2.0.1 — v2 has no
# --multi flag; --no-limit is the multi-select, --selected is comma-separated
# and matches the option strings exactly):
#   preset: gum choose --header "..." "minimal" "standard" "full" "custom"
#   groups: gum choose --no-limit --header "..." --selected "core,fonts" \
#             core modern_cli ...

set -euo pipefail

info() { printf '▸ %s\n' "$1"; }
warn() { printf '⚠ %s\n' "$1" >&2; }

CONFIG_FILE="$HOME/.config/chezmoi/chezmoi.toml"

# The 12 package groups, taxonomy order (docs/research/package-groups-spec.md §2).
# This is the single vocabulary shared with the config template, installers, and CI.
PKG_GROUPS=(core modern_cli fonts agent_toolkit claude_cli claude_desktop \
    chatgpt_cli chatgpt_desktop antigravity_cli antigravity_desktop \
    dev_desktop guardrail)

# Preset → pre-check sets (spec §3). Presets are NOT persisted.
preset_set() {
    # one key per line so callers can mapfile it into a proper array
    case "$1" in
    minimal) printf '%s\n' "core" ;;
    standard) printf '%s\n' core modern_cli fonts agent_toolkit claude_cli guardrail ;;
    full) printf '%s\n' "${PKG_GROUPS[@]}" ;;
    *) return 0 ;; # custom (or anything unexpected): nothing pre-checked
    esac
}

# True-valued keys of the existing [data.packages] section, taxonomy order.
# Plain $HOME path by design — not $CHEZMOI_CONFIG_DIR (this runs before
# chezmoi exists on a brand-new machine).
existing_true_keys() {
    [ -f "$CONFIG_FILE" ] || return 0
    awk '
        /^[[:space:]]*\[data\.packages\][[:space:]]*$/ { insec = 1; next }
        insec && /^[[:space:]]*\[/ { insec = 0 }
        insec && $0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*true[[:space:]]*$/ {
            print $1
        }
    ' "$CONFIG_FILE"
}

has_packages_section() {
    [ -f "$CONFIG_FILE" ] && grep -Eq '^[[:space:]]*\[data\.packages\][[:space:]]*$' "$CONFIG_FILE"
}

# ---------------------------------------------------------------- gate ------

if [ ! -t 0 ] || ! command -v gum >/dev/null 2>&1; then
    info "skipping menu (no TTY/gum) - config template prompts or existing config apply as-is"
    exit 0
fi

# ---------------------------------------------------------- pre-check -------

if has_packages_section; then
    # Re-run: the user's current keys ARE the pre-check (one Enter accepts
    # unchanged). No preset prompt — presets are first-run scaffolding only.
    mapfile -t precheck < <(existing_true_keys)
else
    preset="$(gum choose \
        --header "Preset? minimal=core only | standard=recommended | full=everything | custom=hand-pick" \
        "minimal" "standard" "full" "custom")" || {
        warn "preset prompt canceled - config unchanged"
        exit 0
    }
    mapfile -t precheck < <(preset_set "$preset")
fi

# ------------------------------------------------------------- menu ---------

menu_args=(--no-limit --header "Toggle package groups (space=toggle, a=all, enter=confirm)")
if [ "${#precheck[@]}" -gt 0 ] && [ -n "${precheck[0]:-}" ]; then
    comma_list="$(IFS=,; echo "${precheck[*]}")"
    menu_args+=(--selected "$comma_list")
fi

if ! chosen_raw="$(gum choose "${menu_args[@]}" "${PKG_GROUPS[@]}")"; then
    # gum exits non-zero on cancel/empty selection ("nothing selected") —
    # that's an abort, not a hard failure: leave the config untouched.
    warn "menu canceled - config unchanged"
    exit 0
fi

# Map chosen lines back to known keys (ignore anything unrecognized).
declare -A chosen=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    case " ${PKG_GROUPS[*]} " in
    *" $line "*) chosen["$line"]=1 ;;
    esac
done <<<"$chosen_raw"

# ------------------------------------------------------------ persist -------

section="[data.packages]"
for group in "${PKG_GROUPS[@]}"; do
    if [ -n "${chosen[$group]:-}" ]; then
        section+=$'\n  '"$group"' = true'
    else
        section+=$'\n  '"$group"' = false'
    fi
done

if [ ! -f "$CONFIG_FILE" ]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    printf '%s\n' "$section" >"$CONFIG_FILE"
else
    # Section-replace: strip the old [data.packages] block (up to the next
    # section header or EOF), trim trailing blank lines, then append the
    # fresh block after one blank separator line. `cat` back into the
    # original file preserves its inode and mode.
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    awk '
        /^[[:space:]]*\[data\.packages\][[:space:]]*$/ { insec = 1; next }
        insec && /^[[:space:]]*\[/ { insec = 0 }
        !insec { lines[++n] = $0 }
        END {
            while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--  # drop EOF blanks
            for (i = 1; i <= n; i++) print lines[i]
        }
    ' "$CONFIG_FILE" >"$tmp"
    if [ -s "$tmp" ]; then
        printf '\n%s\n' "$section" >>"$tmp"
    else
        printf '%s\n' "$section" >>"$tmp"
    fi
    cat "$tmp" >"$CONFIG_FILE"
    rm -f "$tmp"
    trap - EXIT
fi

true_keys=()
for group in "${PKG_GROUPS[@]}"; do
    [ -n "${chosen[$group]:-}" ] && true_keys+=("$group")
done
info "saved [data.packages]: ${true_keys[*]:-none} (chezmoi apply installs the difference)"
