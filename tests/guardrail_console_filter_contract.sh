#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# Every `dot up` and `dot upgrade` printed the agent-guardrails installer's ~45-line doctor dump
# (policy, recipes, audit log, four planes registered, four probe summaries, MCP coverage...):
# identical on a healthy machine, four times across the two runs, burying the lines that matter.
# The full output still goes to the apply log (tee upstream of the filter); the console loses only
# lines whose shape is on a fixed list. Everything else stays - a warning, a problem, the verdict,
# the hook latency, and ANY line the list has never seen, above all an approval prompt or URL, since
# the installer blocks on it. DOT_GUARDRAIL_VERBOSE=1 shows everything.
#
# Both twins are EXECUTED on the same real output (WSL and Windows, 2026-10-05) and must keep
# exactly the same lines.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/fixture.txt" <<'EOF'
install: guardrail v0.23.36-dev already installed at /home/carlitos/.local/bin/guardrail
setup: registering /home/carlitos/.local/bin/guardrail
claude: already enabled
opencode: already enabled
antigravity: already enabled
codex: already enabled
guardrail v0.23.36-dev
cwd: /home/carlitos
GUARDRAIL_CONFIG: (unset)
overlay: none
web-research enforcement: on (strict)
policy warnings: none
waivers: none
recipes per-edit: go, python, js-ts, rust, elixir
recipes odoo: disabled (opt in with [recipes.odoo])
recipes session-completion claude: go, python, js-ts, rust, elixir (Stop/SubagentStop)
recipes session-completion opencode: unsupported
audit log: /home/carlitos/.local/state/guardrail/audit.jsonl
approval mode: prompt (operator actions are approved in the agent host's ask or at a terminal [y/N]; set approval = "passkey" in the operator config for WebAuthn)
operator authenticators: 1 authenticator: 1 synced (backup-eligible, held by a passkey provider), 0 device-bound
claude settings: guardrail hook registered but NEVER OBSERVED FIRING - no audit record from a real session since this binary was built.
claude allow list: 0 of 43 baseline rules present (guardrail allow-baseline --check)
opencode settings: guardrail integration registered
codex settings: guardrail hooks registered; verify trust in /hooks; hosted tools and write_stdin bypass pre-hooks (ADR-0014)
codex settings: guardrail hooks registered; on Windows allowed commands run behind a PowerShell working-directory check
claude settings: guardrail hook registered
antigravity settings: guardrail integration registered
claude ownership: manifest matches settings
codex ownership: no manifest (entries written before this release, or state cleared); `plane disable codex` will fall back
engine health: reachable (self-spawn ok)
spawn latency: p95 7.912519ms over 5 samples (ok)
hook latency (in-process, latest real calls): antigravity p50 1.88 p95 12.28 ms (n=68); claude p50 4.79 p95 10.92 ms (n=136)
credential posture:
  WARNING: the gh login carries admin:public_key, workflow. An agent running under it can change what those scopes control.
  WARNING: 2 gh accounts are logged in. Which one an agent acts as depends on the active account.
antigravity coverage: Antigravity (/home/carlitos/.gemini/config/mcp_config.json)
  configured MCP servers: serena
  declared MCP tools: 29 (29 in registry, 0 uncontracted)
  uncontracted (absent from registry): none
verdict: 2 problems (see above)
claude: probes pass (7)
opencode: probes pass (3)
note: codex probes invoke the hook directly; live runtime mediation is evidenced by audit records
selftest: all probes passed
setup: plane status
claude: guardrail hook registered
codex: guardrail hooks registered; verify trust in /hooks; hosted tools and write_stdin bypass pre-hooks (ADR-0014)
approve this request at https://127.0.0.1:41823/approve/9f2c - waiting for your passkey...
doctor: a line this filter has never seen
EOF

# What must survive, in order: the install line, every real finding, and the two unknown lines.
cat >"$tmp/expected.txt" <<'EOF'
install: guardrail v0.23.36-dev already installed at /home/carlitos/.local/bin/guardrail
claude settings: guardrail hook registered but NEVER OBSERVED FIRING - no audit record from a real session since this binary was built.
claude allow list: 0 of 43 baseline rules present (guardrail allow-baseline --check)
hook latency (in-process, latest real calls): antigravity p50 1.88 p95 12.28 ms (n=68); claude p50 4.79 p95 10.92 ms (n=136)
credential posture:
  WARNING: the gh login carries admin:public_key, workflow. An agent running under it can change what those scopes control.
  WARNING: 2 gh accounts are logged in. Which one an agent acts as depends on the active account.
verdict: 2 problems (see above)
selftest: all probes passed
approve this request at https://127.0.0.1:41823/approve/9f2c - waiting for your passkey...
doctor: a line this filter has never seen
EOF
total="$(wc -l <"$tmp/fixture.txt" | tr -d ' ')"
kept="$(wc -l <"$tmp/expected.txt" | tr -d ' ')"
hidden=$((total - kept))

# --- shell twin ---------------------------------------------------------------------------------
sh_filter() { # stdin = fixture; env as given
    bash -c '. "$1/scripts/lib/agent-skills.sh"; guardrail_console_filter' _ "$repo_root"
}
sh_out="$(sh_filter <"$tmp/fixture.txt")"
printf '%s\n' "$sh_out" | grep -v '^  (.* routine guardrail status line' >"$tmp/sh-shown.txt" || true
if ! diff -u "$tmp/expected.txt" "$tmp/sh-shown.txt" >"$tmp/sh.diff"; then fail "shell filter kept the wrong lines: $(head -20 "$tmp/sh.diff")"; fi
printf '%s\n' "$sh_out" | grep -Fq "  ($hidden routine guardrail status line(s) hidden; full output in the apply log, or DOT_GUARDRAIL_VERBOSE=1)" ||
    fail "shell filter must say how many lines it hid ($hidden); got: $(printf '%s\n' "$sh_out" | tail -1)"
sh_verbose="$(DOT_GUARDRAIL_VERBOSE=1 sh_filter <"$tmp/fixture.txt")"
[ "$sh_verbose" = "$(cat "$tmp/fixture.txt")" ] || fail "DOT_GUARDRAIL_VERBOSE=1 must show every line unchanged (shell)"
[ "$(printf '' | sh_filter)" = "" ] || fail "an empty input must print nothing (shell: no 'hidden' note without hidden lines)"
pass

# --- shell twin: an unterminated prompt must appear WHILE the writer is still blocked ------------
# The installer stops on "Approve ...? [y/N] " with NO trailing newline and waits for a keystroke.
# The record-oriented awk this filter used to be could not emit an incomplete record, so it held
# those bytes until EOF and the console stayed BLANK for as long as the installer waited: the
# operator typed blind, the keystrokes did land (the apply ran to completion) with nothing echoed,
# and the session ended in a terminal restart. Reproduced by a writer that prompts and then blocks;
# the assertion is that the prompt is readable BEFORE the writer finishes, which is exactly what a
# record-oriented filter cannot do.
prompt_out="$tmp/prompt.txt"; : >"$prompt_out"
{
    printf 'guardrail v0.23.36-dev\n'
    printf 'setup: registering /usr/local/bin/guardrail\n'
    printf 'Approve register guardrail on planes: claude,codex? [y/N] '
    sleep 3                       # the installer is blocked on a keystroke here
    printf 'y\n'
    printf 'claude enabled\n'
} | sh_filter >"$prompt_out" 2>&1 &
prompt_writer=$!
prompt_seen=false
waited=0
while [ "$waited" -lt 25 ]; do    # up to 2.5s; the filter releases after ~0.2s of silence
    if grep -Fq 'Approve register guardrail on planes: claude,codex? [y/N] ' "$prompt_out"; then
        prompt_seen=true
        break
    fi
    sleep 0.1
    waited=$((waited + 1))
done
wait "$prompt_writer" 2>/dev/null || true
$prompt_seen ||
    fail "an unterminated prompt must reach the console while the writer is still blocked on it (a record-oriented filter holds it until EOF)"
# The released prefix must not be duplicated when its newline finally arrives, and must not be
# re-tested against the hide list - those bytes are already on the operator's screen.
occurrences="$(grep -Fc 'Approve register guardrail on planes' "$prompt_out" || true)"
[ "$occurrences" = 1 ] ||
    fail "the released prompt prefix must appear exactly once, got $occurrences: $(cat "$prompt_out")"
grep -Fq 'Approve register guardrail on planes: claude,codex? [y/N] y' "$prompt_out" ||
    fail "the completed prompt line must carry the answer: $(cat "$prompt_out")"
grep -Fq '  (2 routine guardrail status line(s) hidden' "$prompt_out" ||
    fail "the routine lines around a prompt must still be hidden: $(cat "$prompt_out")"
pass

# --- PowerShell twin ------------------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Fixture)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib
$lines = [IO.File]::ReadAllLines($Fixture)
function Capture([scriptblock]$Run) { (& $Run *>&1 | Out-String) -split "`r?`n" | Where-Object { $_ -ne '' } }
$out = @(Capture { $lines | Select-GuardrailConsoleLine })
$shown = @($out | Where-Object { $_ -notmatch '^  \(\d+ routine guardrail status line' })
$note = @($out | Where-Object { $_ -match '^  \(\d+ routine guardrail status line' })
Write-Output ('ps-shown-count=' + $shown.Count)
$shown | ForEach-Object { Write-Output ('SHOWN|' + $_) }
Write-Output ('ps-note=' + ($note -join '') )
$env:DOT_GUARDRAIL_VERBOSE = '1'
$verbose = @(Capture { $lines | Select-GuardrailConsoleLine })
Write-Output ('ps-verbose-all=' + ($verbose.Count -eq $lines.Count))
Write-Output ('ps-verbose-no-note=' + (-not ($verbose -match 'routine guardrail status')))
Remove-Item Env:DOT_GUARDRAIL_VERBOSE
Write-Output ('ps-empty-silent=' + (@(Capture { @() | Select-GuardrailConsoleLine }).Count -eq 0))
# a second run must start counting from zero again
$again = @(Capture { $lines | Select-GuardrailConsoleLine })
Write-Output ('ps-counter-resets=' + ($again -match ('\(' + ($lines.Count - $shown.Count) + ' routine')).Count)
PSEOF
    ps_out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" -Fixture "$(winpath "$tmp/fixture.txt")" 2>&1 | tr -d '\r' || true)"
    printf '%s\n' "$ps_out" | sed -n 's/^SHOWN|//p' >"$tmp/ps-shown.txt"
    if ! diff -u "$tmp/expected.txt" "$tmp/ps-shown.txt" >"$tmp/ps.diff"; then fail "PowerShell filter kept the wrong lines: $(head -20 "$tmp/ps.diff") ... $(printf '%s' "$ps_out" | tail -5)"; fi
    printf '%s\n' "$ps_out" | grep -Fxq "ps-shown-count=$kept" || fail "PowerShell: expected $kept shown lines"
    printf '%s\n' "$ps_out" | grep -Fq "($hidden routine guardrail status line(s) hidden; full output in the apply log, or DOT_GUARDRAIL_VERBOSE=1)" ||
        fail "PowerShell filter must say how many lines it hid ($hidden)"
    printf '%s\n' "$ps_out" | grep -Fxq 'ps-verbose-all=True' || fail "DOT_GUARDRAIL_VERBOSE=1 must show every line (PowerShell)"
    printf '%s\n' "$ps_out" | grep -Fxq 'ps-verbose-no-note=True' || fail "verbose mode must not print the hidden-lines note (PowerShell)"
    printf '%s\n' "$ps_out" | grep -Fxq 'ps-empty-silent=True' || fail "an empty input must print nothing (PowerShell)"
    printf '%s\n' "$ps_out" | grep -Fxq 'ps-counter-resets=1' || fail "the hidden counter must restart each run (PowerShell)"
    pass
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

# --- PowerShell twin: Invoke-GuardrailInstallerProcess, the REAL call path (a process, not a bare
# array of already-split lines fed to Select-GuardrailConsoleLine as above) --------------------------
# `& powershell -File install.ps1 2>&1 | Tee-Object | Select-GuardrailConsoleLine` looked like the
# shell twin's byte-streaming pipe but was not: PowerShell's own native-command CAPTURE - the step
# that turns a piped process's stdout into pipeline objects, upstream of Tee-Object and the filter -
# is RECORD-oriented, exactly like the awk the shell twin replaced. No filter running after that
# capture can fix it, because the capture never emits an unterminated line for the filter to see.
# Invoke-GuardrailInstallerProcess (scripts/lib/ps-skills.ps1) bypasses that capture: it starts the
# process itself and reads its output at the byte level. First: it must still apply the same hide
# list and log the full output, now exercised through a real child process.
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/fixture-writer.ps1" <<'PSEOF'
param([string]$Fixture)
foreach ($l in [IO.File]::ReadAllLines($Fixture)) { Write-Host $l }
PSEOF
    cat >"$tmp/process-harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Writer, [string]$Fixture, [string]$Log)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib
function Capture([scriptblock]$Run) { (& $Run *>&1 | Out-String) -split "`r?`n" | Where-Object { $_ -ne '' } }
$out = @(Capture { Invoke-GuardrailInstallerProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $Writer, '-Fixture', $Fixture) -LogPath $Log | Out-Null })
$shown = @($out | Where-Object { $_ -notmatch '^  \(\d+ routine guardrail status line' })
$note = @($out | Where-Object { $_ -match '^  \(\d+ routine guardrail status line' })
Write-Output ('proc-shown-count=' + $shown.Count)
$shown | ForEach-Object { Write-Output ('SHOWN|' + $_) }
Write-Output ('proc-note=' + ($note -join ''))
Write-Output ('proc-log-lines=' + ([IO.File]::ReadAllLines($Log)).Count)
$env:DOT_GUARDRAIL_VERBOSE = '1'
Remove-Item $Log -ErrorAction SilentlyContinue
$verbose = @(Capture { Invoke-GuardrailInstallerProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $Writer, '-Fixture', $Fixture) -LogPath $Log | Out-Null })
Write-Output ('proc-verbose-all=' + ($verbose.Count -eq ([IO.File]::ReadAllLines($Fixture)).Count))
PSEOF
    proc_out="$tmp/ps-proc.txt"
    proc_log="$tmp/ps-proc.log"
    pwsh -NoProfile -File "$(winpath "$tmp/process-harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" \
        -Writer "$(winpath "$tmp/fixture-writer.ps1")" -Fixture "$(winpath "$tmp/fixture.txt")" -Log "$(winpath "$proc_log")" \
        2>&1 | tr -d '\r' >"$proc_out" || true
    sed -n 's/^SHOWN|//p' "$proc_out" >"$tmp/proc-shown.txt"
    if ! diff -u "$tmp/expected.txt" "$tmp/proc-shown.txt" >"$tmp/proc.diff"; then
        fail "Invoke-GuardrailInstallerProcess kept the wrong lines: $(head -20 "$tmp/proc.diff") ... $(tail -5 "$proc_out")"
    fi
    grep -Fxq "proc-shown-count=$kept" "$proc_out" || fail "Invoke-GuardrailInstallerProcess: expected $kept shown lines"
    grep -Fq "($hidden routine guardrail status line(s) hidden" "$proc_out" ||
        fail "Invoke-GuardrailInstallerProcess must say how many lines it hid ($hidden)"
    grep -Fxq "proc-log-lines=$total" "$proc_out" ||
        fail "Invoke-GuardrailInstallerProcess must log the FULL output ($total lines), not just what it showed"
    grep -Fxq 'proc-verbose-all=True' "$proc_out" || fail "DOT_GUARDRAIL_VERBOSE=1 must show every line (Invoke-GuardrailInstallerProcess)"
    pass
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

# --- PowerShell twin: an unterminated prompt must appear WHILE the writer is still blocked ----------
# Same regression as the shell twin's test above, reproduced through the real call path: a writer
# that prompts with NO trailing newline and then blocks. A record-oriented capture upstream of the
# filter cannot represent that - it is exactly what PowerShell's own native-command capture used
# to leave on screen: nothing, for as long as the writer waited.
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/prompt-writer.ps1" <<'PSEOF'
Write-Host 'guardrail v0.23.36-dev'
Write-Host 'setup: registering /usr/local/bin/guardrail'
Write-Host -NoNewline 'Approve register guardrail on planes: claude,codex? [y/N] '
Start-Sleep -Seconds 3
# The block is over: the test must have seen the prompt BEFORE this file exists.
New-Item -ItemType File -Path $env:PROMPT_RELEASED -Force | Out-Null
Write-Host 'y'
Write-Host 'claude enabled'
PSEOF
    cat >"$tmp/prompt-harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Writer, [string]$Log)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib
Invoke-GuardrailInstallerProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $Writer) -LogPath $Log | Out-Null
PSEOF
    ps_prompt_out="$tmp/ps-prompt.txt"; : >"$ps_prompt_out"
    ps_prompt_log="$tmp/ps-prompt.log"
    # Event-based, not clock-based: the writer creates $PROMPT_RELEASED when its block ends, so
    # "seen while blocked" is "seen before that file exists". A fixed 2.5 s budget failed on a WSL
    # where a cold pwsh start alone takes ~8 s (two nested starts here), with the filter correct.
    ps_prompt_released="$tmp/prompt-released"
    PROMPT_RELEASED="$(winpath "$ps_prompt_released")" \
    pwsh -NoProfile -File "$(winpath "$tmp/prompt-harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" \
        -Writer "$(winpath "$tmp/prompt-writer.ps1")" -Log "$(winpath "$ps_prompt_log")" >"$ps_prompt_out" 2>&1 &
    ps_prompt_writer=$!
    ps_prompt_seen=false
    waited=0
    while [ "$waited" -lt 900 ]; do   # up to 90 s for the two pwsh starts; the block itself is 3 s
        if tr -d '\r' <"$ps_prompt_out" 2>/dev/null | grep -Fq 'Approve register guardrail on planes: claude,codex? [y/N]'; then
            [ -e "$ps_prompt_released" ] || ps_prompt_seen=true
            break
        fi
        [ -e "$ps_prompt_released" ] && break   # the writer moved on and the prompt never showed
        kill -0 "$ps_prompt_writer" 2>/dev/null || break
        sleep 0.1
        waited=$((waited + 1))
    done
    wait "$ps_prompt_writer" 2>/dev/null || true
    $ps_prompt_seen ||
        fail "PowerShell: an unterminated prompt must reach the console while the writer is still blocked on it (released marker: $([ -e "$ps_prompt_released" ] && echo present || echo absent); output: $(tr -d '\r' <"$ps_prompt_out" | head -3 | tr '\n' '|'))"
    occurrences="$(tr -d '\r' <"$ps_prompt_out" | grep -Fc 'Approve register guardrail on planes' || true)"
    [ "$occurrences" = 1 ] ||
        fail "PowerShell: the released prompt prefix must appear exactly once, got $occurrences: $(cat "$ps_prompt_out")"
    tr -d '\r' <"$ps_prompt_out" | grep -Fq 'Approve register guardrail on planes: claude,codex? [y/N] y' ||
        fail "PowerShell: the completed prompt line must carry the answer: $(cat "$ps_prompt_out")"
    tr -d '\r' <"$ps_prompt_out" | grep -Fq '  (2 routine guardrail status line(s) hidden' ||
        fail "PowerShell: the routine lines around a prompt must still be hidden: $(cat "$ps_prompt_out")"
    pass
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

# --- wiring: all four places that run the installer put the filter after the full-output tee ------
grep -Fq 'tee -a "$log" | guardrail_console_filter' "$repo_root/run_onchange_install_packages.sh.tmpl" ||
    fail "the shell installer must filter the console copy after tee"
grep -Fq 'Invoke-GuardrailInstallerProcess' "$repo_root/run_onchange_install_packages.ps1.tmpl" ||
    fail "the PowerShell installer must run the installer through Invoke-GuardrailInstallerProcess, not a native-command pipe"
grep -Fq 'tee -a "$glog" | guardrail_console_filter' "$repo_root/scripts/update_ai_tools.sh" ||
    fail "the shell updater must keep the full output in the apply log and filter the console copy"
grep -Fq 'Invoke-GuardrailInstallerProcess' "$repo_root/scripts/update_ai_tools.ps1" ||
    fail "the PowerShell updater must run the installer through Invoke-GuardrailInstallerProcess, not a native-command pipe"
pass

finish
