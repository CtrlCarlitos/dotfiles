#!/usr/bin/env bash
set -euo pipefail

# Guardrail installer-caller contract (agent-guardrails install.sh/install.ps1,
# ADR-0029 there): installation lives in agent-guardrails. The dotfiles only
#   - fetch the pinned release's installer + SHA256SUMS from releases/download,
#   - verify the installer against SHA256SUMS,
#   - run it FROM A FILE (never piped) with the pin and the desired state
#     (packages.guardrail: enabled | disabled), output streaming.
# Everything else (binary download, self-update, plane wiring, doctor, Defender
# exclusions, PATH) is the installer's job, so it must not reappear here.
#
# Each consumer marks its guardrail code with two literal lines:
#     # guardrail-section: begin
#     # guardrail-section: end
# The meaningful requires (download URL, SHA256SUMS, both states, the
# run-from-a-file shape, Tls12) are section-scoped, and the section must hold
# real code, not just comments - otherwise code moved out of the markers would
# still pass. The install-era literals only guardrail ever used are forbidden
# in the WHOLE file, so they cannot come back just outside the markers. Only
# literals other tools' installers in the same files legitimately use
# (`| sh`, `iex`, Invoke-Expression, PATH edits) are forbidden section-only.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"
sh_updater="$repo_root/scripts/update_ai_tools.sh"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
ps1_updater="$repo_root/scripts/update_ai_tools.ps1"

. "$repo_root/tests/lib.sh"

begin_marker='# guardrail-section: begin'
end_marker='# guardrail-section: end'

# section <file> - print the lines strictly between the two marker lines.
# Markers may be indented (templated .ps1 block) and may carry a trailing CR.
section() {
    awk -v b="$begin_marker" -v e="$end_marker" '
        { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line) }
        line == b { on = 1; next }
        line == e { on = 0; next }
        on
    ' "$1"
}

# The section is captured into a variable before grepping (not piped into
# grep -q): a -q early exit can SIGPIPE awk and, under pipefail, flip the result.
# A section of only comments and blank lines counts as empty.
require_section() { # $1 = file
    local sec
    if ! grep -Fq -- "$begin_marker" "$1" || ! grep -Fq -- "$end_marker" "$1"; then
        fail "$1: guardrail section is empty or markers missing"
    fi
    sec="$(section "$1")"
    grep -Eq '^[[:space:]]*[^[:space:]#]' <<<"$sec" ||
        fail "$1: guardrail section is empty or markers missing"
}

require_in_section() { # $1 = file, $2 = literal
    local sec
    sec="$(section "$1")"
    grep -Fq -- "$2" <<<"$sec" || fail "$1: guardrail section is missing $2"
}

forbid_in_section() { # $1 = file, $2 = literal
    local sec
    sec="$(section "$1")"
    ! grep -Fq -- "$2" <<<"$sec" || fail "$1: guardrail section must not contain $2"
}

# --- Shared by all four consumers --------------------------------------------

common_checks() { # $1 = file
    require_section "$1"
    require_in_section "$1" 'releases/download'
    require_in_section "$1" 'SHA256SUMS'
    # The dotfiles never wire planes, self-update, or fetch a binary asset
    # any more - all of that is the installer's job. Whole-file: none of these
    # has a legitimate use anywhere in the four consumers.
    local literal
    for literal in \
        'gen-config' \
        'plane enable' \
        'plane disable' \
        'guardrail update' \
        'GUARDRAIL_UPDATE_FLOOR' \
        'guardrail_ver_num' \
        'doctor --coverage' \
        'Add-MpPreference' \
        'Get-MpPreference' \
        'Unblock-File' \
        'guardrail_linux_' \
        'guardrail_darwin_' \
        'guardrail_windows_'; do
        forbid "$1" "$literal"
    done
}

# --- Unix twins: install.sh, pin + state passed, run from a file -------------

unix_checks() { # $1 = file
    require "$1" 'install.sh'
    require "$1" '--version "'
    require_in_section "$1" '--state enabled'
    require_in_section "$1" '--state disabled'
    local sec
    sec="$(section "$1")"
    grep -Eq 'sh +"?\$[A-Za-z_]+/install\.sh"? +--version' <<<"$sec" ||
        fail "$1: guardrail section does not run install.sh from a file (sh \"\$dir/install.sh\" --version ...)"
    forbid_in_section "$1" '| sh'
    forbid_in_section "$1" '|sh'
}

# --- Windows twins: install.ps1, pin + state passed, run with -File ----------

windows_checks() { # $1 = file
    require "$1" 'install.ps1'
    require "$1" '-Version'
    require "$1" '-File'
    require_in_section "$1" '-State enabled'
    require_in_section "$1" '-State disabled'
    require_in_section "$1" 'Tls12'
    local sec
    sec="$(section "$1")"
    grep -Eq -- '-File +"?\$[A-Za-z_]+\\install\.ps1"? +-Version' <<<"$sec" ||
        fail "$1: guardrail section does not run install.ps1 with -File (-File \"\$dir\\install.ps1\" -Version ...)"
    forbid_in_section "$1" 'Invoke-Expression'
    forbid_in_section "$1" 'SetEnvironmentVariable("Path"'
    # Whole word, so msiexec does not match.
    ! grep -Eq '(^|[^[:alnum:]_])iex([^[:alnum:]_]|$)' <<<"$sec" ||
        fail "$1: guardrail section must not contain iex"
}

# --- Unix installer template -------------------------------------------------

common_checks "$sh_installer"
unix_checks "$sh_installer"
# The flag still gates the block (rendered into the script).
# shellcheck disable=SC2016  # template text matched literally, never expanded.
require "$sh_installer" 'GUARDRAIL_ENABLED="{{ $guardrail }}"'

# --- Unix manual updater -----------------------------------------------------

common_checks "$sh_updater"
unix_checks "$sh_updater"
# Flag read at runtime from the chezmoi config.
require "$sh_updater" 'chezmoi/chezmoi.toml'
require "$sh_updater" '[data.packages]'

# --- Windows installer template ----------------------------------------------

common_checks "$ps1_installer"
windows_checks "$ps1_installer"
# The flag still gates the block (templated out when false).
# shellcheck disable=SC2016  # template text matched literally, never expanded.
require "$ps1_installer" '{{- if $guardrail }}'

# --- Windows manual updater --------------------------------------------------

common_checks "$ps1_updater"
windows_checks "$ps1_updater"
# Flag read at runtime from the chezmoi config. The Windows path is built
# with backslashes (chezmoi\chezmoi.toml), so the file name alone is asserted.
require "$ps1_updater" 'chezmoi.toml'
require "$ps1_updater" '[data.packages]'

finish
