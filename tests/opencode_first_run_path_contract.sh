#!/usr/bin/env bash
set -euo pipefail

# install_opencode_cli leaves the native OpenCode binary on the installer's own PATH -
# EXECUTED against the rendered installer.
#
# OpenCode's native installer writes ~/.opencode/bin/opencode and adds that directory to the
# shell rc files only. On a fresh Ubuntu 26.04 checkpoint (issue #431 Run 8) `command -v opencode`
# therefore stayed false for the rest of the run: no Superpowers for OpenCode, no MCP
# registrations, and the agent-guardrails setup reported "opencode: not detected" - all of it
# arrived only with the next `dot up` (Run 9). The contract:
#   1. fresh: after the native installer runs, `opencode` resolves in the same shell, to the
#      native binary, and the Superpowers step that follows sees it;
#   2. already installed in ~/.opencode/bin but not on PATH: no reinstall, and it resolves;
#   3. a leftover npm shim earlier on PATH: the native directory goes in front of it;
#   4. the installer fails and leaves nothing: no crash under set -e, nothing resolves.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

for d in /usr/bin /bin; do
    [ ! -e "$d/opencode" ] || skip "$d/opencode exists - the system PATH this test uses would resolve it"
done
command -v jq >/dev/null 2>&1 || skip 'jq not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_to "$tmp/installer.sh" sh '{"opencode_cli": true}'
for fn in opencode_path_add install_opencode_cli; do
    awk -v f="$fn" '$0 ~ "^" f "\\(\\) \\{" {on=1} on {print} on && /^\}$/ {exit}' "$tmp/installer.sh" >>"$tmp/fns.sh"
    grep -q "^$fn() {" "$tmp/fns.sh" || fail "$fn() not found in the rendered installer"
done

# The fake native binary, as OpenCode's installer would lay it down.
fake_opencode() { # $1 = path
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\necho %s\n' "${OC_FAKE_VER:-1.19.4}" >"$1"
    chmod +x "$1"
}
export -f fake_opencode

{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. "%s"\n' "$repo_root/scripts/lib/agent-skills.sh" # info/warn
    cat <<'STUBS'
ensure_jq() { :; }
npm() { :; }
# The native installer: lays the binary down unless told to fail.
net_timeout() {
    echo installer >>"$CALLS"
    [ "${INSTALL_FAILS:-0}" = 1 ] && return 1
    fake_opencode "$HOME/.opencode/bin/opencode"
}
STUBS
    cat "$tmp/fns.sh"
    printf '%s\n' 'install_opencode_cli' 'echo "resolved=$(command -v opencode || true)"'
} >"$tmp/harness.sh"

run() { # $1 = HOME, $2 = extra PATH prefix ("" = none); prints the harness output
    : >"$tmp/calls"
    HOME="$1" CALLS="$tmp/calls" PATH="${2:+$2:}/usr/bin:/bin" bash "$tmp/harness.sh" 2>&1
}

# 1. Fresh.
h1="$tmp/h1"; mkdir -p "$h1"
out="$(run "$h1" "")" || fail "fresh: the installer function failed (got: $out)"
case "$out" in *"resolved=$h1/.opencode/bin/opencode"*) pass ;; *) fail "fresh: opencode must resolve to the native binary in the same run (got: $out)" ;; esac
grep -q obra/superpowers "$h1/.config/opencode/opencode.json" 2>/dev/null && pass ||
    fail "fresh: Superpowers for OpenCode must be configured in the same run"
case "$out" in *"the 1.x line this machine chose"*) pass ;; *) fail "fresh: the installed 1.x must be reported once (got: $out)" ;; esac

# 2. Installed, not on PATH: no reinstall.
h2="$tmp/h2"; fake_opencode "$h2/.opencode/bin/opencode"
out="$(run "$h2" "")"
case "$out" in *"resolved=$h2/.opencode/bin/opencode"*) pass ;; *) fail "installed: opencode must resolve (got: $out)" ;; esac
[ ! -s "$tmp/calls" ] && pass || fail "installed: the native installer must not run again (calls: $(cat "$tmp/calls"))"

# 3. A shim earlier on PATH loses to the native binary.
h3="$tmp/h3"; fake_opencode "$h3/.opencode/bin/opencode"; fake_opencode "$tmp/shim/opencode"
out="$(run "$h3" "$tmp/shim")"
case "$out" in *"resolved=$h3/.opencode/bin/opencode"*) pass ;; *) fail "shim: the native binary must come first (got: $out)" ;; esac

# 4. The installer fails.
h4="$tmp/h4"; mkdir -p "$h4"
out="$(INSTALL_FAILS=1 run "$h4" "")" || fail "failed install: must not end the run (got: $out)"
case "$out" in *'resolved='$'\n'* | *'resolved=') pass ;; *) fail "failed install: nothing may resolve (got: $out)" ;; esac

# 5. A 2.x binary (upstream flipped): the Phase 0 tripwire warns loudly.
h5="$tmp/h5"; OC_FAKE_VER=2.3.0 fake_opencode "$h5/.opencode/bin/opencode"
out="$(run "$h5" "")"
case "$out" in *'dotfiles#395'*) pass ;; *) fail "2.x: the warning must reference dotfiles#395 (got: $out)" ;; esac
case "$out" in *'agent-guardrails#534'*) pass ;; *) fail "2.x: the warning must name the guardrail port (got: $out)" ;; esac

# 6. The PowerShell installer twin carries the same tripwire (rendered and
#    asserted; the behavioral sh cases above prove the logic).
if command -v chezmoi >/dev/null 2>&1; then
    render_to "$tmp/installer.ps1" ps1 '{"opencode_cli": true, "agent_toolkit": true}'
    # The ps1 tripwire interpolates the phrase at RUNTIME ($ocWantedMajor), so
    # the render literal is the assignment, not the sentence.
    for literal in 'dotfiles#395' 'agent-guardrails#534' "ocWantedMajor = '1'"; do
        grep -Fq -- "$literal" "$tmp/installer.ps1" || fail "windows twin: the tripwire must mention '$literal'"
    done
    pass
fi

# 7. A machine configured for major 2 renders the V2 route on both twins: the
#    v2 install URL (Unix) / winget Anomaly.OpenCode (Windows), the native
#    `plugins` key in the superpowers writer, and the V2 MCP
#    shape (mcp.servers with disabled) - never the V1 literals. Direct renders,
#    not render_to: it wraps its override under "packages", and opencodeMajor
#    is a top-level machine key.
if command -v chezmoi >/dev/null 2>&1; then
    cfg="$tmp/empty.toml"; : >"$cfg"
    chezmoi execute-template --config "$cfg" --source "$repo_root" \
        --override-data '{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"packages":{"opencode_cli":true},"opencodeMajor":"2"}' \
        < "$repo_root/run_onchange_install_packages.sh.tmpl" | tr -d '\r' >"$tmp/v2.sh"
    chezmoi execute-template --config "$cfg" --source "$repo_root" \
        --override-data '{"chezmoi":{"os":"windows"},"packages":{"opencode_cli":true,"agent_toolkit":true},"opencodeMajor":"2"}' \
        < "$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/v2.ps1"
    for literal in 'https://opencode.ai/v2/install' 'oc_plugin_key="plugins"' 'root_key = "servers"'; do
        grep -Fq -- "$literal" "$tmp/v2.sh" || fail "v2 sh render must carry '$literal'"
    done
    for literal in '$wingetPackages += "Anomaly.OpenCode|' "ocWantedMajor = '2'" 'disabled = $false'; do
        grep -Fq -- "$literal" "$tmp/v2.ps1" || fail "v2 ps1 render must carry '$literal'"
    done
    # One catalog pass per major (winget dropped the 1.x SST.opencode on
    # 2026-11-14; Anomaly.OpenCode is 2.x only): major 2 must NOT render the
    # choco 1.x pass, and never the npm route (its postinstall-stub binary).
    # Assert on the code lines, not the prose.
    if grep -Fq -- '$packages += "opencode"' "$tmp/v2.ps1"; then fail "v2 ps1 render must not install choco's 1.x opencode"; fi
    if grep -Fq -- 'npm install -g "@opencode/cli"' "$tmp/v2.ps1"; then fail "v2 ps1 render must not install OpenCode from npm"; fi
    if grep -Fq -- 'opencode.ai/install | bash' "$tmp/v2.sh"; then fail "v2 sh render must not carry the V1 installer URL"; fi
    # ... while major 1 renders only the choco pass.
    cfg2="$tmp/empty2.toml"; : >"$cfg2"
    chezmoi execute-template --config "$cfg2" --source "$repo_root" \
        --override-data '{"chezmoi":{"os":"windows"},"packages":{"opencode_cli":true,"agent_toolkit":true},"opencodeMajor":"1"}' \
        < "$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/v1.ps1"
    grep -Fq -- '$packages += "opencode"' "$tmp/v1.ps1" || fail "v1 ps1 render must carry choco's opencode (the 1.x route)"
    if grep -Fq -- '$wingetPackages += "Anomaly.OpenCode|' "$tmp/v1.ps1"; then fail "v1 ps1 render must not install winget's 2.x Anomaly.OpenCode"; fi
    if grep -Fq -- '$wingetPackages += "SST.opencode' "$tmp/v1.ps1"; then fail "v1 ps1 render must not install the dead SST.opencode id"; fi
    # 8. promptChoiceOnce persists its choice as a TOML INT (opencodeMajor = 2,
    #    the live VM-pilot failure of 2026-11-14: eq int64 vs string killed every
    #    apply). An int-typed override must render identically to the string one.
    chezmoi execute-template --config "$cfg2" --source "$repo_root" \
        --override-data '{"chezmoi":{"os":"windows"},"packages":{"opencode_cli":true,"agent_toolkit":true},"opencodeMajor":2}' \
        < "$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/int.ps1"
    grep -Fq -- "ocWantedMajor = '2'" "$tmp/int.ps1" || fail "int-typed opencodeMajor must render as major 2 (the VM-pilot regression)"
    grep -Fq -- '$wingetPackages += "Anomaly.OpenCode|' "$tmp/int.ps1" || fail "int-typed opencodeMajor must take the winget V2 route"
    pass

    # 9. The rendered route blocks EXECUTED. Major 2: once winget's binary is
    #    there, an npm @opencode/cli (the pilot's route, whose shim the profile
    #    puts first on PATH) is removed; with no working binary it says winget.
    #    Major 1: the legacy opencode-ai shim goes, and a failure names choco.
    if command -v pwsh >/dev/null 2>&1; then
        for major in 1 2; do
            src="$tmp/v$major.ps1"
            awk '/^# OpenCode: one package per major/ {on=1} /^# Major-aware tripwire/ {exit} on {print}' "$src" >"$tmp/route$major.ps1"
            grep -q 'ocWorks' "$tmp/route$major.ps1" || fail "v$major ps1: the OpenCode route block was not found in the render"
        done
        cat >"$tmp/route-harness.ps1" <<'POWERSHELL'
param([string]$Block, [string]$Mode, [string]$Local)
# Both winget roots point into the fixture: a real Anomaly.OpenCode on the host must not count.
$env:LOCALAPPDATA = $Local
$env:ProgramFiles = Join-Path $Local 'pf'
$script:npmArgs = @()
function Invoke-Quietly { param([string]$Description, [scriptblock]$Action) & $Action }
function npm { $script:npmArgs += "$args"; $global:LASTEXITCODE = 0 }
function opencode { if ($Mode -ne 'works') { throw 'not a valid application for this OS platform' }; 'opencode v2.2.7'; $global:LASTEXITCODE = 0 }
. ([scriptblock]::Create((Get-Content -Raw -LiteralPath $Block)))
"npm=$($script:npmArgs -join ';')"
POWERSHELL
        harness="$(ps_path pwsh "$tmp/route-harness.ps1")"
        run_route() { # $1 = major, $2 = works|dead, $3 = LOCALAPPDATA
            pwsh -NoProfile -File "$harness" "$(ps_path pwsh "$tmp/route$1.ps1")" "$2" "$(ps_path pwsh "$3")" 2>&1
        }
        # --scope machine (the catalog's winget_args): the package lands under Program Files.
        la="$tmp/la-winget"; mkdir -p "$la/pf/WinGet/Packages/Anomaly.OpenCode_Microsoft.Winget.Source_8wekyb3d8bbwe"
        : >"$la/pf/WinGet/Packages/Anomaly.OpenCode_Microsoft.Winget.Source_8wekyb3d8bbwe/opencode.exe"
        out="$(run_route 2 works "$la")" || fail "v2 route: the block failed (got: $out)"
        case "$out" in *'npm=rm -g @opencode/cli'*) pass ;; *) fail "v2 route: winget's binary present - the npm @opencode/cli must be removed (got: $out)" ;; esac
        case "$out" in *'is not working'*) fail "v2 route: no warning when opencode runs (got: $out)" ;; *) pass ;; esac
        la0="$tmp/la-empty"; mkdir -p "$la0"
        out="$(run_route 2 dead "$la0")" || fail "v2 route: a missing binary must not end the run (got: $out)"
        case "$out" in *'rm -g @opencode/cli'*) fail "v2 route: no winget binary - npm must be left alone (got: $out)" ;; *) pass ;; esac
        case "$out" in *'winget install --id Anomaly.OpenCode --exact'*) pass ;; *) fail "v2 route: a dead install must name the winget fix (got: $out)" ;; esac
        out="$(run_route 1 dead "$la0")" || fail "v1 route: a missing binary must not end the run (got: $out)"
        case "$out" in *'npm=rm -g opencode-ai'*) pass ;; *) fail "v1 route: the legacy npm opencode-ai shim must be removed (got: $out)" ;; esac
        case "$out" in *'choco install opencode -y'*) pass ;; *) fail "v1 route: a dead install must name the choco fix (got: $out)" ;; esac
    else
        skip_part 'pwsh not installed - the executed OpenCode route blocks (case 9)'
    fi
fi

finish
