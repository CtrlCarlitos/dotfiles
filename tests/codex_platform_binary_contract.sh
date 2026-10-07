#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2317  # PowerShell text is literal; fakes are used by eval-ed functions
set -euo pipefail

# Codex ships its native binary as an optional dependency per platform
# (@openai/codex-linux-x64 -> npm:@openai/codex@<version>-linux-x64), published minutes AFTER
# the main package. npm skips a missing optional dependency silently: a `dot upgrade` in that
# gap (2026-10-07: 0.161.0 at 16:04, its Linux binary at 16:16) removed the old binary,
# installed none, and every codex command died with "Missing optional dependency" - while
# the version check said "codex is current". Both twins' upgrade function is EXECUTED
# against a fake npm and a fake codex:
#   a. runs and current             -> "current", no install
#   b. cannot start, binary out     -> installed (repaired), no warning once it starts
#   c. newer release, binary not out, the installed one runs -> kept, said so, no install
#   d. cannot start, binary not out -> no install, says to re-run later
#   e. installed but still cannot start -> says so
# And `dot up`'s installers reinstall a codex that exists but cannot start.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# --- installers (static: the reinstall condition) ----------------------------------------------
grep -Fq '{ command -v codex &>/dev/null && codex --version &>/dev/null; } || $npm_sudo "$NPM_BIN" install -g' "$repo_root/run_onchange_install_packages.sh.tmpl" ||
    fail "sh installer: a codex that cannot start must be reinstalled, not only a missing one"
grep -Fq 'try { codex --version *> $null; $codexRuns = ($LASTEXITCODE -eq 0) }' "$repo_root/run_onchange_install_packages.ps1.tmpl" ||
    fail "ps1 installer: a codex that cannot start must be reinstalled, not only a missing one"
grep -Fq 'upgrade_codex_npm "$CODEX_PKG"' "$repo_root/scripts/update_ai_tools.sh" || fail "update_ai_tools.sh must upgrade codex through upgrade_codex_npm"
grep -Fq 'Update-CodexNpm -Package $codexPkg' "$repo_root/scripts/update_ai_tools.ps1" || fail "update_ai_tools.ps1 must upgrade codex through Update-CodexNpm"
pass

# --- bash twin, executed ------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    extract_fn() { awk -v n="$1" 'index($0, n "() {") == 1 {f=1; print; next} f{print} f && /^\}$/{exit}' "$repo_root/scripts/update_ai_tools.sh"; }
    for fn in npm_global_current npm_platform_tag npm_platform_published codex_works upgrade_codex_npm; do extract_fn "$fn"; done >"$tmp/fns.sh"
    grep -q '^upgrade_codex_npm() {' "$tmp/fns.sh" || fail "upgrade_codex_npm() not found in update_ai_tools.sh"
    mkdir -p "$tmp/bin"
    # state: $tmp/have (installed version), $tmp/want (latest), $tmp/published (1/0), $tmp/works (1/0)
    cat >"$tmp/bin/npm" <<EOF
#!/usr/bin/env bash
s="$tmp"
case "\$*" in
    "ls -g @openai/codex --depth=0 --json") printf '{"dependencies":{"@openai/codex":{"version":"%s"}}}' "\$(cat "\$s/have")" ;;
    "view @openai/codex version") cat "\$s/want" ;;
    "view @openai/codex@"*" optionalDependencies --json") v="\$(cat "\$s/want")"; printf '{"@openai/codex-linux-x64":"npm:@openai/codex@%s-linux-x64"}' "\$v" ;;
    "view @openai/codex@"*"-linux-x64 version") [ "\$(cat "\$s/published")" = 1 ] && echo "\${2#@openai/codex@}" ;;
    "install -g @openai/codex@latest "*) echo install >>"\$s/calls"; cat "\$s/want" >"\$s/have"; [ "\$(cat "\$s/published")" = 1 ] && [ "\$(cat "\$s/fixes")" = 1 ] && echo 1 >"\$s/works" ;;
esac
exit 0
EOF
    cat >"$tmp/bin/codex" <<EOF
#!/usr/bin/env bash
[ "\$(cat "$tmp/works")" = 1 ]
EOF
    chmod +x "$tmp/bin/npm" "$tmp/bin/codex"
    sh_case() { # have want published works [fixes: the install makes it start, default 1] -> "output|calls"
        printf '%s' "$1" >"$tmp/have"; printf '%s' "$2" >"$tmp/want"; printf '%s' "$3" >"$tmp/published"; printf '%s' "$4" >"$tmp/works"
        printf '%s' "${5:-1}" >"$tmp/fixes"; : >"$tmp/calls"
        local out
        out="$(PATH="$tmp/bin:$PATH" bash -c '. "$1"; npm_platform_tag() { echo linux-x64; }; npm_sudo=""; upgrade_codex_npm @openai/codex' _ "$tmp/fns.sh" 2>&1)"
        printf '%s|%s' "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/^ *//; s/ *$//')" "$(tr '\n' ',' <"$tmp/calls")"
    }
    r="$(sh_case 0.161.0 0.161.0 1 1)"; [ "$r" = "codex is current (0.161.0)|" ] || fail "sh a: runs and current must be left alone (got: $r)"
    r="$(sh_case 0.161.0 0.161.0 1 0)"; [ "$r" = "|install," ] || fail "sh b: a codex that cannot start must be reinstalled (got: $r)"
    r="$(sh_case 0.160.0 0.161.0 0 1)"
    case "$r" in *"0.161.0 is out, but its linux-x64 binary is not published yet - keeping the installed one"*"|") ;; *) fail "sh c: a release without its binary must not replace a working codex (got: $r)" ;; esac
    r="$(sh_case 0.161.0 0.161.0 0 0)"
    case "$r" in *"cannot start"*"re-run dot upgrade in a few minutes"*"|") ;; *) fail "sh d: a broken codex with no binary out must say to re-run later, without installing (got: $r)" ;; esac
    # e: the registry says the binary is out, but the install still leaves codex unable to start
    r="$(sh_case 0.160.0 0.161.0 1 0 0)"
    case "$r" in *"installed but cannot start"*"|install,") ;; *) fail "sh e: an install that leaves codex unable to start must say so (got: $r)" ;; esac
    pass
else
    printf 'note: jq not installed - bash twin skipped\n'
fi

# --- PowerShell twin, executed ------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
. $Lib
$script:st = @{ have = ''; want = ''; published = $true; works = $true; fixes = $true; calls = @() }
function Get-NpmPlatformTag { 'win32-x64' }
function npm {
    $line = $args -join ' '
    $global:LASTEXITCODE = 0
    switch -Wildcard ($line) {
        'ls -g @openai/codex --depth=0 --json' { '{"dependencies":{"@openai/codex":{"version":"' + $script:st.have + '"}}}' }
        'view @openai/codex version' { $script:st.want }
        'view @openai/codex@* optionalDependencies --json' { '{"@openai/codex-win32-x64":"npm:@openai/codex@' + $script:st.want + '-win32-x64"}' }
        'view @openai/codex@*-win32-x64 version' { if ($script:st.published) { $args[1] } }
        'install -g @openai/codex@latest*' { $script:st.calls += 'install'; $script:st.have = $script:st.want; if ($script:st.published -and $script:st.fixes) { $script:st.works = $true } }
    }
}
function codex { $global:LASTEXITCODE = $(if ($script:st.works) { 0 } else { 1 }) }
function Case($label, $have, $want, $published, $works, $fixes = $true) {
    $script:st = @{ have = $have; want = $want; published = $published; works = $works; fixes = $fixes; calls = @() }
    $out = ((Update-CodexNpm -Package '@openai/codex' 6>&1) | Out-String) -replace '\s+', ' '
    Write-Output ("$label=" + $out.Trim() + '|' + ($script:st.calls -join ','))
}
Case 'a' '0.161.0' '0.161.0' $true $true
Case 'b' '0.161.0' '0.161.0' $true $false
Case 'c' '0.160.0' '0.161.0' $false $true
Case 'd' '0.161.0' '0.161.0' $false $false
Case 'e' '0.160.0' '0.161.0' $true $false $false
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '\r')"
    line() { printf '%s\n' "$out" | grep "^$1=" || true; }
    [ "$(line a)" = "a=codex is current (0.161.0)|" ] || fail "ps1 a: runs and current must be left alone (got: $(line a))"
    [ "$(line b)" = "b=|install" ] || fail "ps1 b: a codex that cannot start must be reinstalled (got: $(line b))"
    case "$(line c)" in *"0.161.0 is out, but its win32-x64 binary is not published yet - keeping the installed one"*"|") ;; *) fail "ps1 c: got $(line c)" ;; esac
    case "$(line d)" in *"cannot start"*"re-run dot upgrade in a few minutes"*"|") ;; *) fail "ps1 d: got $(line d)" ;; esac
    case "$(line e)" in *"installed but cannot start"*"|install") ;; *) fail "ps1 e: got $(line e)" ;; esac
    pass
else
    printf 'note: pwsh not installed - PowerShell twin skipped\n'
fi

finish
