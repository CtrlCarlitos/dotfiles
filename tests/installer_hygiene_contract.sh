#!/usr/bin/env bash
set -euo pipefail

# Installer hygiene contracts, each born from a 2026-09-20 live incident:
#   1. Single-flight: two concurrent dotups multiplied every choco/npm lock
#      into a night-long incident (double runs at 22:57+23:12). A second
#      instance must exit 1 BEFORE any work - chezmoi then records nothing
#      and the next dotup re-fires fully (the 1.0.3 contract).
#   2. lib-bkp\opencode cleanup: every choco upgrade while an opencode
#      session holds the binary abandons the old copy there (seen twice).
#   3. GoogleChrome handover advisory: choco-managed GoogleChrome fails
#      `choco upgrade all` on checksum lag while the installer's direct-MSI
#      Chrome block self-updates - advise the one-time uninstall.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"

. "$repo_root/tests/lib.sh"

# 1. Single-flight guard: named mutex, zero-wait, exit 1 when held.
grep -Fq 'dotfiles-install' "$ps1_installer" ||
    fail "$ps1_installer: no single-flight mutex (concurrent dotups caused the 2026-09-20 incident)"
grep -Fq 'Global\dotfiles-install' "$ps1_installer" ||
    fail "$ps1_installer: mutex must be Global (machine-wide, across elevation levels)"
grep -Pzq 'WaitOne\(0\)[\s\S]{0,400}exit 1' "$ps1_installer" ||
    fail "$ps1_installer: single-flight guard must exit 1 without doing work (re-fire contract)"

# 2. lib-bkp opencode cleanup, gated on nothing running.
grep -Fq 'lib-bkp' "$ps1_installer" ||
    fail "$ps1_installer: no lib-bkp opencode cleanup"

# 3. GoogleChrome handover advisory keyed on the batched inventory.
grep -Fq 'choco still manages GoogleChrome' "$ps1_installer" ||
    fail "$ps1_installer: no GoogleChrome handover advisory"

# 4. The installer NEVER upgrades: upgrades moved to `dot upgrade`
#    (tests/dot_cli_contract.sh pins the split). Assert the upgrade
#    literals are ABSENT here.
! grep -Fq '@openai/codex@latest' "$ps1_installer" ||
    fail "$ps1_installer: must not upgrade codex (dot upgrade owns it)"
! grep -Fq 'uv tool upgrade' "$ps1_installer" ||
    fail "$ps1_installer: must not upgrade serena (dot upgrade owns it)"
! grep -Fq 'Upgrading graft' "$ps1_installer" ||
    fail "$ps1_installer: must not upgrade graft (dot upgrade owns it)"

# 5. Guardrail installation (binary, Defender exclusion #132/#146, PATH,
#    plane wiring) lives in the agent-guardrails installer: this file only
#    runs the pinned install.ps1 and never touches Defender. The bare literal
#    'install.ps1' also matches the Chocolatey bootstrap URL
#    (community.chocolatey.org/install.ps1), so assert the function name
#    instead - a real signal that the guardrail caller is wired up.
forbid "$ps1_installer" 'Add-MpPreference'
require "$ps1_installer" 'Invoke-GuardrailInstaller'

# 6. Unix installer temp-file hygiene (#126): one WORK dir with an EXIT trap,
#    and no literal /tmp/ paths anywhere - fixed shared names are a symlink
#    surface, and set -e leaks whatever predates a failure. Checked on the
#    template source: template actions never manufacture a /tmp path, so the
#    rendered script contains one iff the source does.
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"
identities="$repo_root/run_onchange_generate_identities.sh.tmpl"
install_sh="$repo_root/install.sh"
[ -f "$sh_installer" ] || fail "$sh_installer missing"
[ -f "$identities" ] || fail "$identities missing"
require "$sh_installer" 'WORK="$(mktemp -d)"'
grep -Eq "^trap .*rm -rf ..WORK.* EXIT$" "$sh_installer" ||
    fail "$sh_installer: WORK has no EXIT trap (#126)"
require "$identities" 'WORK="$(mktemp -d)"'
grep -Eq "^trap .*rm -rf ..WORK.* EXIT$" "$identities" ||
    fail "$identities: WORK has no EXIT trap (#126)"
! grep -Fq '/tmp/' "$sh_installer" ||
    fail "$sh_installer: literal /tmp/ path found - route downloads under WORK (#126)"
! grep -Fq '/tmp/' "$install_sh" ||
    fail "$install_sh: literal /tmp/ path found - use a mktemp dir (#126)"

# 7. Rate-limit-proof version lookups (#114): the six GitHub-API tag lookups
#    neutralize grep's no-match exit INSIDE the substitution, so a 403 (60
#    req/h unauthenticated) cannot abort the run under set -e at the Meslo
#    font - the very first install step - or anywhere else.
while IFS= read -r line; do
    fail "tag lookup without an in-substitution guard (#114): $line"
done < <(grep -n 'grep -Po' "$sh_installer" | grep -v '|| true')

# 8. Third-party apt repos go through one &&-chained add_apt_repo helper with
#    a single warn at the call site (#114): a failed key download must never
#    install an empty keyring plus a repo line that wedges every later
#    `apt update`.
require "$sh_installer" 'add_apt_repo()'
for repo in githubcli nodesource vscode cloudflared charm gierens; do
    grep -Eq "^ +add_apt_repo $repo " "$sh_installer" ||
        fail "$sh_installer: $repo must install via add_apt_repo (#114)"
done

# 9. The dot-upgrade path keeps the same warn-and-continue promise (#114):
#    both installer fetches are guarded (fetch-then-run, never piped - a
#    piped curl|bash exits 0 on a failed fetch), the Claude installer uses
#    the same URL as the installer template (the old linux-only download URL
#    is gone), and the npm sudo decision follows the /usr-prefix rule.
ai_sh="$repo_root/scripts/update_ai_tools.sh"
require "$ai_sh" 'curl -fsSL -o "$cl_inst" https://claude.ai/install.sh'
require "$ai_sh" 'curl -fsSL -o "$oc_inst" https://opencode.ai/install'
require "$ai_sh" 'Claude Code installer failed - continuing'
require "$ai_sh" 'OpenCode installer failed - continuing'
require "$ai_sh" 'Claude Code installer download failed - continuing'
require "$ai_sh" 'OpenCode installer download failed - continuing'
! grep -Fq 'claude.ai/download/cli/linux' "$ai_sh" ||
    fail "$ai_sh: stale Claude installer URL - the installer template uses claude.ai/install.sh (#114)"
require "$ai_sh" '!= /usr*'

# --- EXECUTED (v2, #135): the single-flight guard and the apt-repo chain -----
#
# 1. Single-flight: the rendered mutex block, run twice - free it must enter,
#    held it must exit 1 without work. (Needs pwsh: the guard is a .NET mutex.)
if command -v pwsh >/dev/null 2>&1 && command -v chezmoi >/dev/null 2>&1; then
    htmp="$(mktemp -d)"
    hbin="$htmp/bin"
    mkdir -p "$hbin"
    rendered="$htmp/installer.ps1"
    render_to "$rendered" ps1 '{}'
    if [ -s "$rendered" ]; then
        mx_start="$(grep -nF '$__dotupMutex = New-Object' "$rendered" | head -1 | cut -d: -f1)"
        mx_end="$(awk -v s="$mx_start" 'NR > s && $0 == "}"{print NR; exit}' "$rendered")"
        if [ -n "$mx_start" ] && [ -n "$mx_end" ]; then
            fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"
            cat >"$fixture" <<'PSEOF'
$ErrorActionPreference = 'Stop'
$rendered, $start, $end = $args
$lines = [IO.File]::ReadAllLines($rendered)
function Slice([object[]]$All, [int]$From, [int]$To) { ($All[($From - 1)..($To - 1)] -join "`n") + "`n" }
Invoke-Expression (Slice $lines $start $end)
Write-Host "MUTEX-ACQUIRED"
PSEOF
            holder="$htmp/holder.ps1"
            cat >"$holder" <<'PSEOF'
$m = New-Object System.Threading.Mutex($false, 'Global\dotfiles-install')
if (-not $m.WaitOne(0)) { exit 2 }
New-Item -ItemType File -Force -Path $env:HOLDER_READY | Out-Null
$deadline = (Get-Date).AddSeconds(60)
while (-not (Test-Path $env:HOLDER_RELEASE) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
$m.ReleaseMutex()
PSEOF
            # Free: the guard must enter.
            rm -f "$htmp/ready" "$htmp/release"
            free_log="$htmp/free.log"
            if pwsh -NoProfile -File "$fixture" "$rendered" "$mx_start" "$mx_end" >"$free_log" 2>&1; then
                if grep -Fq 'MUTEX-ACQUIRED' "$free_log"; then pass; else fail "single-flight: a free mutex must let the installer run: $(cat "$free_log")"; fi
            else
                fail "single-flight: a free mutex must not block: $(cat "$free_log")"
            fi
            # Held: the guard must exit 1 without work.
            held_log="$htmp/held.log"
            HOLDER_READY="$htmp/ready" HOLDER_RELEASE="$htmp/release" \
                pwsh -NoProfile -File "$holder" >/dev/null 2>&1 &
            holder_pid=$!
            n=0
            while [ ! -f "$htmp/ready" ] && [ "$n" -lt 100 ]; do
                sleep 0.1
                n=$((n + 1))
            done
            held_rc=0
            pwsh -NoProfile -File "$fixture" "$rendered" "$mx_start" "$mx_end" >"$held_log" 2>&1 || held_rc=$?
            touch "$htmp/release"
            wait $holder_pid 2>/dev/null || true
            if [ "$held_rc" -eq 1 ] && grep -Fq 'Another dotfiles installer instance is running' "$held_log"; then
                pass
            else
                fail "single-flight: a held mutex must exit 1 with the re-run note (rc=$held_rc): $(cat "$held_log")"
            fi
            rm -f "$fixture"
        else
            fail "rendered installer: single-flight mutex block not found"
        fi
    fi
fi

# 2. add_apt_repo: a failed key download must abort the WHOLE chain - no
#    keyring, no repo line, no package install (the GitHub-CLI incident).
#    Executed on the failure path only: the happy path writes /etc/apt, which
#    an unprivileged runner must never touch; the per-repo call-site greps
#    above still pin that every repo goes through the helper.
apt_tmp="$(mktemp -d)"
trap '[ -n "${htmp:-}" ] && rm -rf "$htmp"; rm -rf "$apt_tmp"' EXIT
apt_bin="$apt_tmp/bin"
mkdir -p "$apt_bin"
# curl fails the key download outright.
printf '#!/bin/sh\nexit 7\n' >"$apt_bin/curl"
chmod +x "$apt_bin/curl"
# Everything downstream must never run.
for c in apt-get gpg tee; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${APT_LOG:?}"\nexit 0\n' >"$apt_bin/$c"
    chmod +x "$apt_bin/$c"
done
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. "%s"\n' "$repo_root/scripts/lib/agent-skills.sh" # net_timeout/info/warn
    awk '/^add_apt_repo\(\) \{/{on=1} on{print} on && /^\}$/{exit}' "$repo_root/run_onchange_install_packages.sh.tmpl"
    printf '%s\n' 'WORK="'"$apt_tmp"'" SUDO="" net_timeout 30 add_apt_repo githubcli "https://example.invalid/key.gpg" "deb https://example.invalid repo main" gh || warn "GitHub CLI install failed - continuing"'
} >"$apt_tmp/harness.sh"
: >"$apt_tmp/apt.log"
apt_out="$apt_tmp/out.log"
if HOME="$apt_tmp/home" PATH="$apt_bin:/usr/bin:/bin" APT_LOG="$apt_tmp/apt.log" \
    bash "$apt_tmp/harness.sh" >"$apt_out" 2>&1; then
    : # the warn makes the harness exit 0; the assertions below decide
fi
grep -Fq 'GitHub CLI install failed - continuing' "$apt_out" ||
    fail "add_apt_repo: a failed key download must surface the caller's warn; got: $(cat "$apt_out")"
if [ -s "$apt_tmp/apt.log" ]; then
    fail "add_apt_repo: a failed key download must not run apt-get/gpg/tee; saw: $(cat "$apt_tmp/apt.log")"
else
    pass
fi

finish
