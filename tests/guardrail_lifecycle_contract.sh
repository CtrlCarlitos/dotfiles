#!/usr/bin/env bash
set -euo pipefail

# Guardrail installer-caller contract (agent-guardrails install.sh/install.ps1,
# ADR-0029 there): installation lives in agent-guardrails. The dotfiles only
#   - fetch the pinned release's installer + SHA256SUMS from releases/download,
#   - verify the installer against SHA256SUMS,
#   - run it FROM A FILE (never piped) with the pin, the desired state
#     (packages.guardrail: enabled | disabled), output streaming.
# Everything else (binary download, self-update, plane wiring, doctor, Defender
# exclusions, PATH) is the installer's job, so it must not reappear here.
#
# Exit-code contract (v0.23.6-dev, verified against the released binary): the
# installer's run classifies the installer exit code ONLY - never its wording
# (the #168 message-grep tolerance is gone). 0 continue; 1 and 2 fail the
# apply (2 is unambiguous usage/unsupported as of v0.23.7-dev); 3 warns with
# the remedy and continues (the binary is installed and current, the existing
# wiring keeps enforcing). The installer streams its own output - including
# any next-steps block - and it is never parsed. The manual updaters are a
# different surface: they warn-and-continue on ANY non-zero.
# After ALL sections, both installer templates run the read-only
# `guardrail next` once and print its stdout+stderr verbatim when non-empty
# (tolerating exit 2 from binaries older than the command), ending the run
# with an ACTION NEEDED remedy.
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
# Exit codes classify (v0.23.7-dev): setup runs unattended, so --no-setup is
# gone, and exit 2 is unambiguous usage/unsupported - it must fail.
# #168's message-grep tolerance is gone: exit codes classify, never wording.
forbid "$sh_installer" 'approval request'
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
# Setup runs unattended (v0.23.7-dev): no -NoSetup flag anymore.
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

# --- Executed (v2, #135): both sh consumers run their guardrail path for real
#
# The section greps above pin the SHAPE of the caller (download URL, checksum,
# run-from-a-file, both states, forbids). What they cannot say is
# whether the wiring WORKS: the pin must flow from .chezmoidata.yaml into the
# installer's argv, a checksum mismatch
# must fail closed, and the exit-code contract must hold - 0 continue,
# 1 and 2 fail the reconciliation in the installer but only warn in
# the updater, 3 warn with the remedy in both, and the installer's streamed
# next-steps marker must stay visible. Both Unix consumers are executed below
# against a stubbed release (curl serves a marker install.sh plus a true
# SHA256SUMS; the marker logs its argv and can print a next-steps marker or
# exit per GUARDRAIL_INSTALLER_RC). The Windows twins keep their grep
# contracts only - they need a real powershell.exe to execute, which CI's
# Linux suite does not have.

command -v timeout >/dev/null 2>&1 || skip "coreutils timeout not installed"
command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed (the runtime pin needs it)"

gtmp="$(mktemp -d)"
trap 'rm -rf "$gtmp"' EXIT
gbin="$gtmp/bin"
ghome="$gtmp/home"
gscratch="$gtmp/repo"
mkdir -p "$gbin" "$ghome" "$gscratch"
cp "$repo_root/.chezmoidata.yaml" "$gscratch/"
cp -r "$repo_root/.chezmoidata" "$gscratch/"
# The pin exactly as rendered from the data (single source of truth).
gpin="$(awk '/^guardrail:/{on=1} on && /version:/{gsub(/"/, "", $2); print $2; exit}' "$repo_root/.chezmoidata.yaml")"
[ -n "$gpin" ] || { fail "could not read guardrail.version from .chezmoidata.yaml"; finish; }

# curl stub: serves the marker installer and a SHA256SUMS matching it (or a
# wrong sum when GUARDRAIL_BAD_SUM=1). The marker logs its argv, optionally
# prints a next-steps marker line (GUARDRAIL_INSTALLER_NEXT=1 - what the real
# installer prints when setup is skipped), and exits per GUARDRAIL_INSTALLER_RC.
cat >"$gbin/curl" <<'EOF'
#!/bin/sh
out='' want_out=0 url=''
for arg in "$@"; do
    if [ "$want_out" = 1 ]; then out="$arg"; want_out=0; continue; fi
    case "$arg" in
        -o|-fLo|-fo|-lo) want_out=1 ;;
        http*) url="$arg" ;;
    esac
done
[ -n "$out" ] && [ -n "$url" ] || exit 22
case "$url" in
    */install.sh)
        printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${GUARDRAIL_LOG:?}"\nif [ "${GUARDRAIL_INSTALLER_NEXT:-0}" = 1 ]; then\n    echo "next: run guardrail setup"\nfi\nexit ${GUARDRAIL_INSTALLER_RC:-0}\n' >"$out"
        ;;
    */SHA256SUMS)
        sum="$(sha256sum "$(dirname "$out")/install.sh" | cut -d' ' -f1)"
        [ "${GUARDRAIL_BAD_SUM:-0}" = 1 ] && sum="0000000000000000000000000000000000000000000000000000000000000000"
        printf '%s  install.sh\n' "$sum" >"$out"
        ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$gbin/curl"

# chezmoi stub: real binary against the scratch data; GUARDRAIL_NO_PIN=1
# simulates the 403/absent-data class by answering empty.
real_chezmoi="$(command -v chezmoi)"
cat >"$gbin/chezmoi" <<EOF
#!/bin/sh
[ "\${GUARDRAIL_NO_PIN:-0}" = 1 ] && exit 1
[ "\${1:-}" = execute-template ] && shift
exec "$real_chezmoi" execute-template --source "$gscratch" "\$@"
EOF
chmod +x "$gbin/chezmoi"

g_run() { # $1 = script to run; $2 = output file (config baked into HOME)
    local script="$1" outfile="$2"
    # PATH is pinned to the stubs + system coreutils: with the host's real
    # npm/npx reachable, the updater's OTHER sections do real network work
    # (observed live: a playwright download inside a contract test).
    HOME="$ghome" PATH="$gbin:/usr/bin:/bin" GUARDRAIL_LOG="$gtmp/installer.log" \
        timeout 120 bash "$script" >"$outfile" 2>&1
}

g_assert_ran_with() { # $1 = expected state, $2 = log file
    local want="--version $gpin --state $1"
    if [ -n "${3:-}" ]; then want="$want $3"; fi
    if grep -Fqx -- "$want" "$2"; then
        pass
    else
        fail "guardrail installer must run from the downloaded file with '$want'; saw: $(cat "$2" 2>/dev/null || true)"
    fi
}

# --- Unix updater: all four states --------------------------------------------
updater="$repo_root/scripts/update_ai_tools.sh"
config_dir="$ghome/.config/chezmoi"
mkdir -p "$config_dir"

# enabled: downloads, verifies, runs with the pin and enabled.
: >"$gtmp/installer.log"
printf '[data.packages]\nguardrail = true\n' >"$config_dir/chezmoi.toml"
g_run "$updater" "$gtmp/updater-enabled.log"
g_assert_ran_with enabled "$gtmp/installer.log"

# non-zero installer exit is a WARNING in the updater - the run continues.
: >"$gtmp/installer.log"
GUARDRAIL_INSTALLER_RC=5 g_run "$updater" "$gtmp/updater-failed.log"
grep -Fq 'guardrail installer exited with code 5 - continuing' "$gtmp/updater-failed.log" ||
    fail "a failing guardrail installer must warn-and-continue in the updater"
g_assert_ran_with enabled "$gtmp/installer.log"

# checksum mismatch fails closed: the installer is never run.
: >"$gtmp/installer.log"
GUARDRAIL_BAD_SUM=1 g_run "$updater" "$gtmp/updater-badsum.log"
if [ -s "$gtmp/installer.log" ]; then
    fail "a checksum mismatch must never run the installer"
else
    pass
fi
grep -Fq 'CHECKSUM MISMATCH' "$gtmp/updater-badsum.log" ||
    fail "a checksum mismatch must be reported as such"

# disabled with a binary present: one download to disable, state disabled.
: >"$gtmp/installer.log"
printf '[data.packages]\nguardrail = false\n' >"$config_dir/chezmoi.toml"
mkdir -p "$ghome/.local/bin"
# A copy of a known-executable: `touch`+`chmod +x` is not reliable on the
# msys/NTFS layer, and the disabled state hinges on the binary being -x.
cp "$(command -v sh)" "$ghome/.local/bin/guardrail"
g_run "$updater" "$gtmp/updater-disabled.log"
g_assert_ran_with disabled "$gtmp/installer.log"

# disabled with no binary: nothing to do, no download at all.
rm -f "$ghome/.local/bin/guardrail"
: >"$gtmp/installer.log"
g_run "$updater" "$gtmp/updater-off.log"
if [ -s "$gtmp/installer.log" ]; then
    fail "a disabled guardrail with no binary must not download anything"
else
    pass
fi
grep -Fq 'guardrail disabled in config - nothing to do' "$gtmp/updater-off.log" ||
    fail "disabled-without-binary must say so"

# pin unavailable: skip loudly, never guess a version.
printf '[data.packages]\nguardrail = true\n' >"$config_dir/chezmoi.toml"
: >"$gtmp/installer.log"
GUARDRAIL_NO_PIN=1 g_run "$updater" "$gtmp/updater-nopin.log"
if [ -s "$gtmp/installer.log" ]; then
    fail "without the pin the installer must not run"
else
    pass
fi
grep -Fq 'pin unavailable from chezmoi data - skipping guardrail steps' "$gtmp/updater-nopin.log" ||
    fail "an unavailable pin must be reported, not guessed"

# --- Unix installer template: pin + state flow, run-from-a-file, exit contract -
sh_installer_tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"
gharness="$gtmp/harness.sh"
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. "%s"\n' "$repo_root/scripts/lib/agent-skills.sh"
    # install_agent_guardrails is template-free: extract verbatim from the
    # template source (identical bytes to what renders).
    awk '/^install_agent_guardrails\(\) \{/{on=1} on{print} on && /^\}$/{exit}' "$sh_installer_tmpl"
    printf '%s\n' 'install_agent_guardrails'
} >"$gharness"

gh_run() { # $1 = GUARDRAIL_ENABLED value; $2 = outfile; extra env pre-set by caller
    local enabled="$1" outfile="$2"
    HOME="$ghome" PATH="$gbin:/usr/bin:/bin" GUARDRAIL_LOG="$gtmp/installer.log" \
        GUARDRAIL_VERSION="$gpin" GUARDRAIL_REPO="CtrlCarlitos/agent-guardrails" \
        GUARDRAIL_ENABLED="$enabled" \
        timeout 120 bash "$gharness" >"$outfile" 2>&1
}

rm -f "$ghome/.local/bin/guardrail"
: >"$gtmp/installer.log"
gh_run true "$gtmp/inst-enabled.log"
g_assert_ran_with enabled "$gtmp/installer.log"

# Non-zero installer exit FAILS the installer's run (unlike the updater).
: >"$gtmp/installer.log"
gh_rc=0
GUARDRAIL_INSTALLER_RC=5 gh_run true "$gtmp/inst-failed.log" || gh_rc=$?
if [ "$gh_rc" -eq 5 ]; then pass; else fail "the installer contract must fail its run when the guardrail installer exits non-zero (got $gh_rc)"; fi
g_assert_ran_with enabled "$gtmp/installer.log"

# Exit 1 (download/checksum/install/verify failure or a genuine setup
# failure) fails the apply.
: >"$gtmp/installer.log"
gh_rc=0
GUARDRAIL_INSTALLER_RC=1 gh_run true "$gtmp/inst-rc1.log" || gh_rc=$?
if [ "$gh_rc" -eq 1 ]; then pass; else fail "installer exit 1 must fail the apply (got $gh_rc)"; fi
g_assert_ran_with enabled "$gtmp/installer.log"

# Exit 3 (operator action pending: not enrolled, NO INTERACTIVE TERMINAL,
# approval daemon not running, request denied/expired) warns with the remedy
# and CONTINUES - the binary is installed and current and the existing wiring
# keeps enforcing, so failing the whole apply buys nothing. Replaces #168's
# message-grep tolerance.
: >"$gtmp/installer.log"
gh_rc=0
GUARDRAIL_INSTALLER_RC=3 gh_run true "$gtmp/inst-rc3.log" || gh_rc=$?
if [ "$gh_rc" -eq 0 ]; then pass; else fail "installer exit 3 must warn-and-continue, not fail the apply (got $gh_rc)"; fi
grep -Fq 'operator action' "$gtmp/inst-rc3.log" ||
    fail "the exit-3 warning must name the pending operator action"
grep -Fq 'no interactive terminal' "$gtmp/inst-rc3.log" ||
    fail "the exit-3 warning must cover the no-terminal class"
grep -Fq 'guardrail setup' "$gtmp/inst-rc3.log" ||
    fail "the exit-3 remedy must name 'guardrail setup'"
grep -Fq 'denied/expired' "$gtmp/inst-rc3.log" ||
    fail "the exit-3 warning must cover the denied/expired request class"
g_assert_ran_with enabled "$gtmp/installer.log"

# Exit 3 from the daemon-pending class behaves identically (same warn +
# continue) - asserted as its own scenario so the two causes stay covered.
: >"$gtmp/installer.log"
gh_rc=0
GUARDRAIL_INSTALLER_RC=3 gh_run true "$gtmp/inst-rc3-daemon.log" || gh_rc=$?
if [ "$gh_rc" -eq 0 ]; then pass; else fail "installer exit 3 (daemon-pending) must warn-and-continue (got $gh_rc)"; fi
g_assert_ran_with enabled "$gtmp/installer.log"

# Exit 2 is unambiguous usage/unsupported platform as of v0.23.7-dev - it
# must FAIL the apply (it used to be an ambiguous no-terminal refusal).
: >"$gtmp/installer.log"
gh_rc=0
GUARDRAIL_INSTALLER_RC=2 gh_run true "$gtmp/inst-rc2.log" || gh_rc=$?
if [ "$gh_rc" -eq 2 ]; then pass; else fail "installer exit 2 must fail the apply (got $gh_rc)"; fi
g_assert_ran_with enabled "$gtmp/installer.log"

# Exit 0 while the installer prints its own next-steps block (what it does
# when setup is skipped): the block streams through, visible in the output,
# never parsed - the run succeeds.
: >"$gtmp/installer.log"
gh_rc=0
GUARDRAIL_INSTALLER_NEXT=1 gh_run true "$gtmp/inst-next.log" || gh_rc=$?
if [ "$gh_rc" -eq 0 ]; then pass; else fail "installer exit 0 must continue regardless of its printed next-steps (got $gh_rc)"; fi
grep -Fq 'next: run guardrail setup' "$gtmp/inst-next.log" ||
    fail "the installer's streamed next-steps marker must appear in the run output"
g_assert_ran_with enabled "$gtmp/installer.log"

# checksum mismatch: warn, skip, and never run.
: >"$gtmp/installer.log"
GUARDRAIL_BAD_SUM=1 gh_run true "$gtmp/inst-badsum.log"
if [ -s "$gtmp/installer.log" ]; then
    fail "installer template: a checksum mismatch must never run the installer"
else
    pass
fi

# disabled without binary: nothing to do.
: >"$gtmp/installer.log"
gh_run false "$gtmp/inst-off.log"
if [ -s "$gtmp/installer.log" ]; then
    fail "installer template: disabled without a binary must not download"
else
    pass
fi
grep -Fq 'guardrail disabled in config - nothing to do' "$gtmp/inst-off.log" ||
    fail "installer template: disabled-without-binary must say so"

# --- End-of-apply `guardrail next` block (v0.23.6-dev) ------------------------
# After ALL sections the installer runs the read-only `guardrail next` once
# and prints its stdout verbatim when non-empty, ending the run with an
# ACTION NEEDED remedy. Old binaries have no `next` and exit 2 - tolerated
# like a no-op. Harness: the function extracted verbatim from the template
# (identical bytes to what renders) plus a stub `guardrail` on PATH.
cat >"$gbin/guardrail" <<'EOF'
#!/bin/sh
if [ "${GUARDRAIL_NEXT_OLD:-0}" = 1 ]; then
    exit 2
fi
if [ "${GUARDRAIL_NEXT_BLOCK:-0}" = 1 ]; then
    printf 'next: run guardrail setup\nthen: re-run chezmoi apply\n'
fi
exit 0
EOF
chmod +x "$gbin/guardrail"

nharness="$gtmp/next.sh"
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. "%s"\n' "$repo_root/scripts/lib/agent-skills.sh"
    awk '/^guardrail_next_steps\(\) \{/{on=1} on{print} on && /^\}$/{exit}' "$sh_installer_tmpl"
    printf '%s\n' 'guardrail_next_steps'
} >"$nharness"
grep -Fq 'guardrail_next_steps()' "$nharness" ||
    fail "guardrail_next_steps() not found in the sh installer template - the end-of-apply block is missing"

n_run() { # $1 = outfile; the stub mode is chosen via GUARDRAIL_NEXT_* by the caller
    if ! HOME="$ghome" PATH="$gbin:/usr/bin:/bin" timeout 120 bash "$nharness" >"$1" 2>&1; then
        fail "the end-of-apply guardrail next harness must not crash the run: $(cat "$1" 2>/dev/null || true)"
    fi
}

# New binary with pending steps: the block verbatim, then ACTION NEEDED LAST.
GUARDRAIL_NEXT_BLOCK=1 n_run "$gtmp/next-block.log"
grep -Fq 'next: run guardrail setup' "$gtmp/next-block.log" ||
    fail "the guardrail next block must be printed verbatim"
grep -Fq 'then: re-run chezmoi apply' "$gtmp/next-block.log" ||
    fail "the whole guardrail next block must be printed (multi-line)"
n_last="$(tail -n 1 "$gtmp/next-block.log")"
case "$n_last" in
    *"ACTION NEEDED: run 'guardrail setup'"*) pass ;;
    *) fail "the run must END with the ACTION NEEDED remedy; last line: $n_last" ;;
esac

# New binary, nothing pending (an empty block): silent, no ACTION NEEDED.
n_run "$gtmp/next-none.log"
if grep -Fq 'ACTION NEEDED' "$gtmp/next-none.log"; then
    fail "nothing pending must not print ACTION NEEDED; saw: $(cat "$gtmp/next-none.log")"
else
    pass
fi

# Old binary (no `next` subcommand): exits 2 with no output - tolerated like
# a no-op, no crash, no ACTION NEEDED.
GUARDRAIL_NEXT_OLD=1 n_run "$gtmp/next-old.log"
if [ -s "$gtmp/next-old.log" ]; then
    fail "an old binary (guardrail next exits 2) must be a silent no-op; saw: $(cat "$gtmp/next-old.log")"
else
    pass
fi

# The call must sit AFTER every section in BOTH rendered templates, so the
# ACTION NEEDED remedy is the last thing a run prints (invariant #10: both
# twins). Rendering needs chezmoi - guaranteed present past the skip guard.
render_to "$gtmp/next-rendered.sh" sh '{"guardrail": true}' ||
    fail "rendering the sh installer for the end-of-apply placement check failed"
n_line="$(grep -nF 'guardrail_next_steps' "$gtmp/next-rendered.sh" | tail -1 | cut -d: -f1)"
d_line="$(grep -nF 'Package installation complete' "$gtmp/next-rendered.sh" | tail -1 | cut -d: -f1)"
if [ -n "$n_line" ] && [ -n "$d_line" ] && [ "$n_line" -gt "$d_line" ]; then
    pass
else
    fail "the end-of-apply guardrail_next_steps call must come after ALL sections in the rendered sh installer (call at ${n_line:-?}, complete at ${d_line:-?})"
fi
render_to "$gtmp/next-rendered.ps1" ps1 '{"guardrail": true}' ||
    fail "rendering the ps1 installer for the end-of-apply placement check failed"
n_line="$(grep -nF 'Invoke-GuardrailNextStep' "$gtmp/next-rendered.ps1" | tail -1 | cut -d: -f1)"
d_line="$(grep -nF 'Package installation complete' "$gtmp/next-rendered.ps1" | tail -1 | cut -d: -f1)"
if [ -n "$n_line" ] && [ -n "$d_line" ] && [ "$n_line" -gt "$d_line" ]; then
    pass
else
    fail "the end-of-apply Invoke-GuardrailNextStep call must come after ALL sections in the rendered ps1 installer (call at ${n_line:-?}, complete at ${d_line:-?})"
fi

finish
