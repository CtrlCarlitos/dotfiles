#!/usr/bin/env bash
set -euo pipefail

# The VS Code settings tiers used to exist twice: a PowerShell [ordered]@{} and
# a Python dict, ~75 duplicated values in two syntaxes. Every change was two
# edits in two languages, and they drifted.
#
# They now render from .chezmoidata.yaml `vscode.settings`. This test keeps it
# that way, and the guarantee is structural rather than a comparison: if neither
# twin contains a literal and both read the same keys, the values CANNOT differ.
#
# Why structural and not a rendered diff: each installer template renders only
# its own platform's branch (on Linux the .ps1 tiers emit nothing, and vice
# versa), so no single CI job can render both and compare them. The twin this
# platform DOES render is value-checked in part 5.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
sh_t="$repo_root/run_onchange_install_packages.sh.tmpl"
ps_t="$repo_root/run_onchange_install_packages.ps1.tmpl"
data="$repo_root/.chezmoidata.yaml"
failures=0
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# 1. The single source exists and holds every tier.
for key in forced defaults defaults_windows junk unset terminal_colors; do
    grep -Fq -- "    $key:" "$data" ||
        fail ".chezmoidata.yaml: missing vscode.settings tier '$key'"
done

# 2. Both twins read the shared tiers rather than carrying their own copy.
for tier in forced defaults junk unset terminal_colors; do
    grep -Fq -- ".vscode.settings.$tier" "$sh_t" ||
        fail "run_onchange_install_packages.sh.tmpl: no longer renders .vscode.settings.$tier"
    grep -Fq -- ".vscode.settings.$tier" "$ps_t" ||
        fail "run_onchange_install_packages.ps1.tmpl: no longer renders .vscode.settings.$tier"
done

# 3. defaults_windows is for the Windows twin ONLY. enableWin32InputMode is a
#    ConPTY workaround; on Linux it would write a setting that does nothing.
grep -Fq -- ".vscode.settings.defaults_windows" "$ps_t" ||
    fail "run_onchange_install_packages.ps1.tmpl: no longer renders the Windows-only tier"
if grep -Fq -- ".vscode.settings.defaults_windows" "$sh_t"; then
    fail "run_onchange_install_packages.sh.tmpl renders defaults_windows - that tier is Windows-only"
fi

# 4. No tier value may reappear as a literal in either twin. One sentinel per
#    tier, unmistakable if someone pastes a block back in.
check_no_literal() { # $1=file  $2=literal  $3=tier
    if grep -Fq -- "$2" "$1"; then
        fail "$(basename -- "$1"): '$2' is hardcoded again - $3 comes from .chezmoidata.yaml"
    fi
}
for f in "$sh_t" "$ps_t"; do
    check_no_literal "$f" '#1E1E2E' 'terminal_colors'
    check_no_literal "$f" 'afterDelay' 'defaults'
    check_no_literal "$f" '__pycache__' 'junk'
    check_no_literal "$f" 'remote.SSH.configFile' 'unset'
done

# The font is the one value also used outside the tiers (Windows Terminal's
# default face), so it must come from the same key or the two can drift.
check_no_literal "$ps_t" 'MesloLGS Nerd Font Mono' 'the shared font'
# shellcheck disable=SC2016  # literal $desiredFont in the message, not an expansion
grep -Fq -- 'index .vscode.settings.forced "editor.fontFamily"' "$ps_t" ||
    fail 'run_onchange_install_packages.ps1.tmpl: $desiredFont no longer derives from the shared font'

# 5. Value-check the twin this platform renders. Fixed-string matching (-F)
#    throughout: the rendered PowerShell contains [ ] and a backtick, neither of
#    which should be read as a regex.
#
#    Every grep reads a HERE-STRING, never `printf ... | grep -q`: under
#    `set -o pipefail` a successful -q match closes the pipe early, the upstream
#    printf dies of SIGPIPE, and the PIPELINE reports 141 - so a match reads as
#    a failure. That cost a debugging round here, and
#    tests/update_guardrail_versions.sh carries a note about the same trap.
if command -v chezmoi >/dev/null 2>&1; then
    sh_out="$(chezmoi execute-template --source "$repo_root" --file "$sh_t" 2>/dev/null || true)"
    ps_out="$(chezmoi execute-template --source "$repo_root" --file "$ps_t" 2>/dev/null || true)"
    checked=0

    # The JSON must carry files.eol as a two-character escape. If the YAML
    # scalar breaks, YAML folds the newline to a space and every file VS Code
    # writes silently gets the wrong line ending.
    eol_json='"files.eol":"\n"'
    # PowerShell spells the same newline with a backtick.
    eol_ps="'files.eol' = \"$(printf '\140')n\""

    if grep -qF 'DEFAULTS = json.loads' <<<"$sh_out"; then
        checked=1
        grep -qF "$eol_json" <<<"$sh_out" ||
            fail 'sh twin: files.eol is not an escaped newline (YAML scalar folded?)'
        # The quoted JSON key, not the bare word: the twin carries a comment
        # explaining why it excludes this tier, and that comment is not a bug.
        if grep -qF '"terminal.integrated.enableWin32InputMode"' <<<"$sh_out"; then
            fail 'sh twin: rendered the Windows-only tier'
        fi
        printf '  rendered .sh twin: tiers present, files.eol intact, no Windows-only keys\n'
    fi

    if grep -qF 'vsDefaults = [ordered]' <<<"$ps_out"; then
        checked=1
        grep -qF "$eol_ps" <<<"$ps_out" ||
            fail 'ps1 twin: files.eol did not render as PowerShell backtick-n'
        grep -qF "'terminal.integrated.enableWin32InputMode'" <<<"$ps_out" ||
            fail 'ps1 twin: missing the Windows-only tier'
        printf '  rendered .ps1 twin: tiers present, files.eol is backtick-n, Windows tier included\n'
    fi

    [ "$checked" -eq 1 ] ||
        fail 'neither twin rendered - the platform gate or the data reference is broken'
fi

if [ "$failures" -gt 0 ]; then
    printf '\nFAIL: VS Code settings single-source (%d problem(s))\n' "$failures" >&2
    exit 1
fi
printf 'PASS: VS Code settings render from one source, with no literals in either twin\n'
