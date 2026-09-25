#!/usr/bin/env bash
# scripts/lib/chezmoi-config.sh - the [data.packages] section scanner and the
# 16-group taxonomy, shared by every shell consumer (issue #123).
#
# The awk scanner used to be copy-pasted five times (select-packages.sh x3,
# dotfiles-doctor.sh, update_ai_tools.sh's guardrail flag) and the 16-group
# list three times. This file is the one copy. tests/select_packages.sh and
# tests/dotfiles_doctor.sh keep their own fixtures' copies deliberately: they
# test the scripts' behavior, not the helper, and must not couple to it.
#
# Consumers (source relative to themselves):
#   scripts/select-packages.sh, scripts/dotfiles-doctor.sh,
#   scripts/update_ai_tools.sh
# All bash-3.2-safe (stock macOS /bin/bash): no associative arrays, no
# mapfile.

# The 16 package groups, taxonomy order (docs/research/package-groups-spec.md
# §2). This is the single vocabulary shared with the config template,
# installers, and CI.
PKG_GROUPS=(core modern_cli fonts agent_toolkit opencode_cli opencode_desktop \
    claude_cli claude_desktop chatgpt_cli chatgpt_desktop antigravity_cli \
    antigravity_desktop dev_desktop remote_access remote_access_server guardrail)

# Print the raw lines inside the file's [data.packages] section (the section
# ends at the next [table] header or EOF). $1 = config file.
pkg_config_lines() {
    awk '
        /^[[:space:]]*\[data\.packages\][[:space:]]*$/ { insec = 1; next }
        insec && /^[[:space:]]*\[/ { insec = 0 }
        insec { print }
    ' "$1"
}

# Print the keys whose value is exactly `true` inside [data.packages].
# $1 = config file.
pkg_config_true_keys() {
    awk '
        /^[[:space:]]*\[data\.packages\][[:space:]]*$/ { insec = 1; next }
        insec && /^[[:space:]]*\[/ { insec = 0 }
        insec && $0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*true[[:space:]]*$/ { print $1 }
    ' "$1"
}

# Exit 0 when [data.packages] carries a `key =` line (any value).
# $1 = config file, $2 = key.
pkg_config_has() {
    awk -v k="$2" '
        /^[[:space:]]*\[data\.packages\][[:space:]]*$/ { insec = 1; next }
        insec && /^[[:space:]]*\[/ { insec = 0 }
        insec && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$1"
}

# Print "true" when [data.packages] carries `key = true`, nothing otherwise.
# $1 = config file, $2 = key.
pkg_config_flag_true() {
    awk -v k="$2" '
        /^[[:space:]]*\[data\.packages\][[:space:]]*$/ { insec = 1; next }
        insec && /^[[:space:]]*\[/ { insec = 0 }
        insec && $0 ~ "^[[:space:]]*" k "[[:space:]]*=[[:space:]]*true[[:space:]]*$" { print "true"; exit }
    ' "$1"
}

# Print the file's content minus the whole [data.packages] section, with
# trailing blank lines trimmed - the section-replace read side (the menu owns
# the section; everything else is byte-preserved). $1 = config file.
pkg_config_without_packages_section() {
    awk '
        /^[[:space:]]*\[data\.packages\][[:space:]]*$/ { insec = 1; next }
        insec && /^[[:space:]]*\[/ { insec = 0 }
        !insec { lines[++n] = $0 }
        END {
            while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
            for (i = 1; i <= n; i++) print lines[i]
        }
    ' "$1"
}
