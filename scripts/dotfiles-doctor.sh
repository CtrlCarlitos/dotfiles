#!/usr/bin/env bash
set -euo pipefail

# dotfiles-doctor.sh — repo-level complement to `chezmoi doctor`.
#
# chezmoi's doctor can't see this repo's own failure classes; every check
# below maps to an outage we have actually hit live:
#
#   config-utf8      WinMerge/Notepad-ANSI edits save the config as
#                    Windows-1252; one 0x97 em dash made `chezmoi init
#                    --apply` die mid-install ("invalid UTF-8 byte") on a
#                    real Windows machine. --fix converts pure-cp1252 files
#                    (no valid UTF-8 multibyte anywhere) and refuses mixed
#                    encodings — those need a human eye.
#   config-parse     the config must load (`chezmoi data`).
#   prompted-keys    every key the config template prompts for must exist in
#                    the live config — a missing one fails later applies with
#                    "map has no entry for key" (the install_guardrail outage
#                    class; tests/check_workflow_config_keys.sh guards CI
#                    seeds only, nothing guarded real machines until now).
#   source-dir       chezmoi's source clone present (warn-only: an
#                    interrupted first install lands here).
#   chezmoi-version  installed chezmoi vs the repo's .chezmoi-version pin
#                    (machines drift: WSL sat 3 releases behind until
#                    noticed). Run `chezmoi upgrade` to converge.
#   guardrail-pin    installed guardrail binary vs .chezmoidata.yaml's
#                    guardrail.version (opt-in package, so warn-only).
#
# Exit 0 = no errors (warnings allowed); exit 1 = at least one error.
# Run via: bash "$(chezmoi source-path)/scripts/dotfiles-doctor.sh" [--fix]

FIX=false
[ "${1:-}" = "--fix" ] && FIX=true

# In-apply mode: invoked by run_after_dotfiles-doctor.sh during a chezmoi
# apply, which HOLDS chezmoi's persistent-state lock - sub-chezmoi calls
# (data/source-path/execute-template) deadlock on it, and those checks are
# tautological mid-apply anyway (chezmoi already parsed the config and is
# running from the source dir). File-level checks only in this mode.
IN_APPLY="${DOTFILES_DOCTOR_IN_APPLY:-}"

config_dir="${CHEZMOI_CONFIG_DIR:-$HOME/.config/chezmoi}"
config="$config_dir/chezmoi.toml"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0
result() { # $1=ok|warn|error|skip  $2=check  $3=message
    printf '%-7s  %-16s %s\n' "$1" "$2" "$3"
    if [ "$1" = error ]; then errors=$((errors + 1)); fi
}

# vX.Y.Z[-suffix] -> zero-padded comparable integer (same helper the
# guardrail installer uses; BSD sort has no -V).
ver_num() {
    local v="${1#v}"; v="${v%%-*}"
    local IFS=.
    # shellcheck disable=SC2086  # intentional word-splitting: fields of $v on IFS=.
    set -- $v
    printf '%d%04d%04d' "${1:-0}" "${2:-0}" "${3:-0}"
}

#-------------------------------------------------------------------------------
# 1. Config file is valid UTF-8
#-------------------------------------------------------------------------------
if [ ! -f "$config" ]; then
    result error config-utf8 "config not found: $config (run the installer, or chezmoi init)"
elif iconv -f UTF-8 -t UTF-8 "$config" >/dev/null 2>&1; then
    result ok config-utf8 "$config is valid UTF-8"
else
    # Decode failure. Distinguish pure-cp1252 (every line containing non-ASCII
    # bytes fails line-local UTF-8 validation) from mixed encodings (some
    # non-ASCII lines are valid multibyte UTF-8, some are not). Only the
    # former is safe to auto-transcode; the latter must be fixed by hand
    # because a blind 1252->UTF-8 pass would mangle the valid sequences.
    mixed=false
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *[![:ascii:]]*)
            if printf '%s\n' "$line" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
                mixed=true
                break
            fi
            ;;
        esac
    done < "$config"

    if $FIX && [ "$mixed" = false ]; then
        tmp="$(mktemp)"
        if iconv -f WINDOWS-1252 -t UTF-8 "$config" > "$tmp"; then
            cat "$tmp" > "$config"   # preserve inode/perms like select-packages.sh
            rm -f "$tmp"
            if iconv -f UTF-8 -t UTF-8 "$config" >/dev/null 2>&1; then
                result ok config-utf8 "converted Windows-1252 -> UTF-8 (backup not kept; git is your safety net)"
            else
                result error config-utf8 "transcode produced invalid UTF-8 - restore by hand"
            fi
        else
            rm -f "$tmp"
            result error config-utf8 "Windows-1252 decode failed - fix $config by hand"
        fi
    elif [ "$mixed" = true ]; then
        result error config-utf8 "MIXED encodings: some non-ASCII is valid UTF-8, some is not - fix by hand (open in an editor, save as UTF-8)"
    else
        result error config-utf8 "invalid UTF-8 (saved as Windows-1252/ANSI?) - re-run with --fix to convert"
    fi
fi

#-------------------------------------------------------------------------------
# 2. Config parses
#-------------------------------------------------------------------------------
if [ -n "$IN_APPLY" ]; then
    result skip config-parse "in-apply mode - chezmoi already parsed the config to get this far"
elif [ -f "$config" ]; then
    if chezmoi data >/dev/null 2>&1; then
        result ok config-parse "chezmoi loads the config"
    else
        result error config-parse "chezmoi cannot parse the config (encoding above? run: chezmoi execute-template '{{ .chezmoi.sourceDir }}' to see raw errors)"
    fi
fi

#-------------------------------------------------------------------------------
# 3. Every prompted key exists in the live config
#-------------------------------------------------------------------------------
if [ -f "$config" ]; then
    missing=""
    for key in core modern_cli fonts agent_toolkit opencode_cli opencode_desktop \
        claude_cli claude_desktop chatgpt_cli chatgpt_desktop antigravity_cli \
        antigravity_desktop dev_desktop remote_access remote_access_server guardrail; do
        awk -v k="$key" '
            /^[[:space:]]*\[data\.packages\][[:space:]]*$/ { insec = 1; next }
            insec && /^[[:space:]]*\[/ { insec = 0 }
            insec && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { found = 1 }
            END { exit found ? 0 : 1 }
        ' "$config" || missing="$missing $key"
    done
    if [ -n "$missing" ]; then
        result error prompted-keys "missing [data.packages] keys (map-has-no-entry outage class):$missing"
    else
        result ok prompted-keys "all 16 [data.packages] keys present"
    fi

    # Git identity: either primary* prompt keys or at least one [[data.accounts]]
    if grep -Eq '^[[:space:]]*primaryName[[:space:]]*=' "$config" || \
       grep -Eq '^[[:space:]]*\[\[data\.accounts\]\]' "$config"; then
        result ok git-identity "primary* keys or [[data.accounts]] present"
    else
        result error git-identity "no git identity: neither primary* keys nor [[data.accounts]] - re-run chezmoi init"
    fi
fi

#-------------------------------------------------------------------------------
# 4. Source directory present
#-------------------------------------------------------------------------------
if [ -n "$IN_APPLY" ]; then
    result skip source-dir "in-apply mode - running from it right now"
else
src="$(chezmoi source-path 2>/dev/null || true)"
if [ -n "$src" ] && [ -d "$src" ]; then
    if git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
       ! git -C "$src" diff --quiet >/dev/null 2>&1 || \
       ! git -C "$src" diff --cached --quiet >/dev/null 2>&1; then
        result warn source-dir "$src has uncommitted changes"
    else
        result ok source-dir "$src (clean)"
    fi
else
    result warn source-dir "source dir missing - run the installer or: chezmoi init CtrlCarlitos/dotfiles"
fi
fi

#-------------------------------------------------------------------------------
# 5. Installed chezmoi vs the repo's .chezmoi-version pin
#-------------------------------------------------------------------------------
if [ -n "$IN_APPLY" ]; then
    result skip chezmoi-version "in-apply mode - run standalone for version/pin drift checks"
else
pin_version="$(cat "$repo_root/.chezmoi-version" 2>/dev/null || true)"
# "chezmoi version vX.Y.Z, commit ..." -> strip the trailing comma on $3.
installed_version="$(chezmoi --version 2>/dev/null | awk '{print $3}' | tr -d ',' || true)"
if [ -n "$pin_version" ] && [ -n "$installed_version" ]; then
    if [ "$(ver_num "$installed_version")" -lt "$(ver_num "$pin_version")" ]; then
        result warn chezmoi-version "installed $installed_version < pinned $pin_version - run: chezmoi upgrade"
    else
        result ok chezmoi-version "installed $installed_version (pin: $pin_version)"
    fi
else
    result skip chezmoi-version "cannot compare (installed: ${installed_version:-?}, pin: ${pin_version:-?})"
fi
fi

#-------------------------------------------------------------------------------
# 6. Installed guardrail binary vs .chezmoidata.yaml pin (opt-in package)
#-------------------------------------------------------------------------------
if [ -n "$IN_APPLY" ]; then
    result skip guardrail-pin "in-apply mode - run standalone for version/pin drift checks"
else
guardrail_pin="$(chezmoi execute-template --source "$repo_root" '{{ .guardrail.version }}' 2>/dev/null || true)"
if [ -z "$guardrail_pin" ]; then
    result skip guardrail-pin "source unreadable - run from a full checkout"
else
    # Resolve the binary the same way on both shapes: managed local path
    # first (what the installer owns), PATH second.
    gr_bin=""
    if [ -x "$HOME/.local/bin/guardrail" ]; then gr_bin="$HOME/.local/bin/guardrail"
    else gr_bin="$(command -v guardrail 2>/dev/null || true)"; fi
    if [ -z "$gr_bin" ]; then
        result skip guardrail-pin "guardrail not installed (opt-in via packages.guardrail)"
    else
        guardrail_have="$("$gr_bin" version 2>/dev/null | awk '{print $2}' || true)"
        if [ "$guardrail_have" = "$guardrail_pin" ]; then
            result ok guardrail-pin "guardrail $guardrail_pin"
        else
            result warn guardrail-pin "installed ${guardrail_have:-unknown} vs pin $guardrail_pin - run: chezmoi update"
        fi
    fi
fi
fi

if [ "$errors" -gt 0 ]; then
    printf '\n%d error(s). ' "$errors"
    if $FIX; then printf '(--fix applied where safe)\n'; else printf 're-run with --fix for auto-repairable items\n'; fi
    exit 1
fi
printf '\nno errors\n'
