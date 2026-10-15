# shellcheck shell=bash
# scripts/lib/logging.sh - [data.logging] for the Unix/WSL installers (docs/logging.md).
#
# Twin of the logging half of scripts/lib/ps-installer-output.ps1. Inlined with
# `{{ include }}` into run_onchange_install_packages.sh.tmpl (bash); install.sh (POSIX sh) carries
# its own copy.
#
#   log     = true (default): this run's whole output is tee'd, as it happens, to
#             ~/.local/state/dotfiles/logs/<name>-<yyyymmdd-hhmmss>.log (newest 20 kept), so a
#             run can be followed from another terminal (tail -f) or read afterwards.
#   verbose = true: the console stops hiding things - apt output (DOT_APT_VERBOSE), guardrail
#             status lines (DOT_GUARDRAIL_VERBOSE) and the skills CLI (DOT_SKILLS_VERBOSE).
#
# DOT_LOG / DOT_VERBOSE in the environment override the config for one run. Read at run time,
# never rendered into the template: a rendered value would change the run_onchange script's hash,
# and turning verbose on would re-run the whole install. Bash 3.2 safe (stock macOS).

# dot_log_flag ENV_NAME KEY DEFAULT - prints true or false.
dot_log_flag() {
    local env_value cfg value
    env_value="$(printf '%s' "${!1:-}" | tr '[:upper:]' '[:lower:]')"
    case "$env_value" in
        1 | true | yes | on) echo true; return 0 ;;
        0 | false | no | off) echo false; return 0 ;;
    esac
    cfg="$HOME/.config/chezmoi/chezmoi.toml"
    if [ -f "$cfg" ]; then
        value="$(awk -v key="$2" '
            /^[[:space:]]*\[data\.logging\][[:space:]]*$/ { on = 1; next }
            on && /^[[:space:]]*\[/ { exit }
            on {
                line = $0
                sub(/[[:space:]]*#.*$/, "", line)
                if (line ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*$") {
                    sub(/^[^=]*=[[:space:]]*/, "", line); sub(/[[:space:]]*$/, "", line)
                    print line; exit
                }
            }' "$cfg" 2>/dev/null || true)"
        if [ -n "$value" ]; then echo "$value"; return 0; fi
    fi
    echo "$3"
}

# dot_log_open NAME - from here on, stdout and stderr also go to this run's log. A run never fails
# over its log: any problem leaves the output as it was.
dot_log_open() {
    [ "$(dot_log_flag DOT_LOG log true)" = true ] || return 0
    local dir="$HOME/.local/state/dotfiles/logs" file old
    mkdir -p "$dir" 2>/dev/null || return 0
    file="$dir/$1-$(date +%Y%m%d-%H%M%S).log"
    : >>"$file" 2>/dev/null || return 0
    exec > >(tee -a "$file") 2>&1
    # Newest 20 kept. ls -t is the portable mtime sort (no GNU find -printf on macOS); the names
    # are ours and carry no newlines.
    # shellcheck disable=SC2012
    ls -1t "$dir"/*.log 2>/dev/null | tail -n +21 | while IFS= read -r old; do rm -f "$old"; done
    echo "  Live log: $file"
}

# dot_log_verbose - verbose = true: export the switches that stop the console hiding output.
dot_log_verbose() {
    [ "$(dot_log_flag DOT_VERBOSE verbose false)" = true ] || return 0
    export DOT_APT_VERBOSE=1 DOT_GUARDRAIL_VERBOSE=1 DOT_SKILLS_VERBOSE=1
    echo "  Verbose output on ([data.logging] verbose or DOT_VERBOSE)"
}
