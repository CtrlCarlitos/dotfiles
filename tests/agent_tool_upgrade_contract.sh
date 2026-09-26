#!/usr/bin/env bash
set -euo pipefail

# Agent-tool upgrade contract, v2 (dot CLI era): `dot upgrade` is the ONLY
# upgrader. The AI section (scripts/update_ai_tools.*) carries defer hooks
# around every dir-recreating upgrade (npm -g / uv tool / choco opencode)
# so live agent sessions are never raced - the flaw that made the original
# in-installer upgrades (2026-09-20) record-a-hash-and-never-retry. The
# guardrail.exe Defender exclusion (agent-guardrails #132/#146) belongs to
# the agent-guardrails installer, never the dotfiles. CLI structure lives in
# tests/dot_cli_contract.sh; this file pins the upgrade semantics.
#
# Executed (v2, #135): scripts/update_ai_tools.sh runs END TO END under
# stubbed binaries (npm/npx/git/curl/claude/opencode/agy/uv/serena/graft and
# a delegating chezmoi that reads the real agent catalog), and the semantics
# are asserted from what the stubs were actually called with - the codex
# package really comes from .chezmoidata/agents.yaml at @latest, the defer
# list really suppresses the recreating upgrades, and a failed installer
# download really warns-and-continues under `set -e` (#114). The PowerShell
# twin keeps its structural greps below: same invariants, pinned in form
# (the sh twin carries the behavioral coverage for both).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ai_ps1="$repo_root/scripts/update_ai_tools.ps1"
ai_sh="$repo_root/scripts/update_ai_tools.sh"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
ps1_updater="$ai_ps1"

. "$repo_root/tests/lib.sh"

# The agent-guardrails installer owns the Defender exclusion (#132/#146);
# the dotfiles never touch Defender.
forbid "$ps1_installer" 'Add-MpPreference'
forbid "$ps1_updater" 'Add-MpPreference'

# PowerShell twin's structural pins (the sh twin's counterparts are executed
# below, so they no longer need grep shadows here).
grep -Fq "DOTUPGRADE_DEFER" "$ai_ps1" || fail "$ai_ps1: no defer hooks"
grep -Fq '.agents.npm.codex' "$ai_ps1" ||
    fail "$ai_ps1: codex package name must be read from the agent catalog"
grep -Fq '@latest"' "$ai_ps1" ||
    fail "$ai_ps1: codex must upgrade via @latest"
grep -Fq 'graft upgrade' "$ai_ps1" ||
    fail "$ai_ps1: graft must use its own self-updater"

[ -f "$ai_sh" ] || { fail "$ai_sh missing"; finish; }
command -v timeout >/dev/null 2>&1 || skip "coreutils timeout not installed"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
home="$tmp/home"
prefix="$tmp/prefix" # what the npm stub answers `prefix -g` with
mkdir -p "$bin" "$home" "$prefix/bin"

# --- Stubs -------------------------------------------------------------------
for c in npx git uv serena opencode agy; do
    printf '#!/bin/sh\nexit 0\n' >"$bin/$c"
    chmod +x "$bin/$c"
done

# npm: logs every argv; `prefix -g` answers $NPM_FAKE_PREFIX; installs fail
# only when NPM_FAIL=1.
cat >"$bin/npm" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${NPM_LOG:?}"
if [ "${1:-}" = prefix ] && [ "${2:-}" = -g ]; then
    printf '%s\n' "${NPM_FAKE_PREFIX:?}"
    exit 0
fi
[ "${NPM_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
chmod +x "$bin/npm"

# agent-browser binary where the prefix-lookup must find it (scenario-dependent).
make_agent_browser() {
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${STUB_LOG:?}"\nexit 0\n' >"$prefix/bin/agent-browser"
    chmod +x "$prefix/bin/agent-browser"
}

# curl: -o TARGET URL writes a deliberately failing installer (exit 3) unless
# CURL_MODE=fail, which fails the download itself (exit 7).
cat >"$bin/curl" <<'EOF'
#!/bin/sh
[ "${CURL_MODE:-ok}" = fail ] && exit 7
out=''
prev=''
for arg in "$@"; do
    [ "$prev" = -o ] && out="$arg"
    prev="$arg"
done
[ -n "$out" ] || exit 22
printf '#!/bin/sh\nexit 3\n' >"$out"
exit 0
EOF
chmod +x "$bin/curl"

# claude: `update` fails (forces the installer path), everything else succeeds.
cat >"$bin/claude" <<'EOF'
#!/bin/sh
[ "${1:-}" = update ] && exit 1
exit 0
EOF
chmod +x "$bin/claude"

# graft: logs `upgrade` so the call (or its absence) is assertable.
cat >"$bin/graft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${GRAFT_LOG:?}"
exit 0
EOF
chmod +x "$bin/graft"

# chezmoi: delegate to the REAL binary against a scratch source carrying the
# repo's data (the agent catalog), so `{{ .agents.npm.codex }}` and the skills
# agent list resolve from .chezmoidata exactly as in production (#83).
scratch="$tmp/repo"
mkdir -p "$scratch"
cp "$repo_root/.chezmoidata.yaml" "$scratch/"
cp -r "$repo_root/.chezmoidata" "$scratch/"
real_chezmoi="$(command -v chezmoi)" || skip "chezmoi not installed"
cat >"$bin/chezmoi" <<EOF
#!/bin/sh
[ "\${1:-}" = execute-template ] && shift
exec "$real_chezmoi" execute-template --source "$scratch" "\$@"
EOF
chmod +x "$bin/chezmoi"

run_updater() { # $1 = output file; extra env via caller's exported vars
    local out_file="$1"
    HOME="$home" PATH="$bin:$PATH" NPM_LOG="$tmp/npm.log" GRAFT_LOG="$tmp/graft.log" \
        STUB_LOG="$tmp/agent-browser.log" NPM_FAKE_PREFIX="$prefix" \
        timeout 120 bash "$ai_sh" >"$out_file" 2>&1
}

# --- 1. Baseline: upgrades happen, catalog-driven, and the run completes -----
: >"$tmp/npm.log"; : >"$tmp/graft.log"
rm -f "$prefix/bin/agent-browser"; make_agent_browser
: >"$tmp/agent-browser.log"
out="$tmp/run1.log"
if run_updater "$out"; then pass; else fail "update_ai_tools.sh must run to completion with all tools present: $(tail -3 "$out")"; fi
grep -Fq 'install -g @openai/codex@latest' "$tmp/npm.log" ||
    fail "codex must upgrade via npm -g <catalog package>@latest; npm saw: $(grep codex "$tmp/npm.log" || true)"
grep -Fq 'install -g --allow-scripts=agent-browser agent-browser' "$tmp/npm.log" ||
    fail "agent-browser must be refreshed via npm -g with its allow-scripts list"
grep -Fq 'upgrade' "$tmp/graft.log" ||
    fail "graft must use its own self-updater (graft upgrade)"
grep -Fq 'install' "$tmp/agent-browser.log" || fail "agent-browser browser setup (install) did not run"
grep -Fq 'doctor --json' "$tmp/agent-browser.log" ||
    fail "agent-browser verification (doctor --json) did not run"
grep -Fq 'Claude Code installer failed - continuing' "$out" ||
    fail "a failing Claude installer must warn-and-continue under set -e (#114)"
grep -Fq 'OpenCode installer failed - continuing' "$out" ||
    fail "a failing OpenCode installer must warn-and-continue under set -e (#114)"
grep -Fq 'AI Tools Update Complete' "$out" ||
    fail "the updater must survive every failure above and reach the end (#114)"

# --- 2. DOTUPGRADE_DEFER suppresses the dir-recreating upgrades ---------------
: >"$tmp/npm.log"; : >"$tmp/graft.log"
DOTUPGRADE_DEFER=codex,graft,opencode,serena run_updater "$tmp/run2.log" || true
if grep -Fq 'codex deferred' "$tmp/run2.log"; then pass; else fail "deferred codex must be reported, not upgraded"; fi
if grep -Fq 'graft deferred' "$tmp/run2.log"; then pass; else fail "deferred graft must be reported, not upgraded"; fi
if grep -Fq '@latest' "$tmp/npm.log"; then fail "DOTUPGRADE_DEFER=codex must suppress the npm @latest upgrade"; else pass; fi
if [ -s "$tmp/graft.log" ]; then fail "DOTUPGRADE_DEFER=graft must suppress graft upgrade"; else pass; fi
grep -Fq 'install -g --allow-scripts=agent-browser agent-browser' "$tmp/npm.log" ||
    fail "agent-browser is not defer-listed and must still refresh"

# --- 3. npm failures warn-and-continue ----------------------------------------
: >"$tmp/npm.log"
NPM_FAIL=1 run_updater "$tmp/run3.log" || true
grep -Fq 'Codex upgrade failed - continuing' "$tmp/run3.log" ||
    fail "a failed codex upgrade must warn-and-continue"
grep -Fq 'agent-browser install failed - skipping' "$tmp/run3.log" ||
    fail "a failed agent-browser install must warn-and-skip"
grep -Fq 'AI Tools Update Complete' "$tmp/run3.log" ||
    fail "npm failures must not abort the remaining tools (#114)"

# --- 4. Installer download failures warn-and-continue (#114) ------------------
: >"$tmp/npm.log"
CURL_MODE=fail run_updater "$tmp/run4.log" || true
grep -Fq 'Claude Code installer download failed - continuing' "$tmp/run4.log" ||
    fail "a failed Claude installer download must warn-and-continue"
grep -Fq 'OpenCode installer download failed - continuing' "$tmp/run4.log" ||
    fail "a failed OpenCode installer download must warn-and-continue"
grep -Fq 'AI Tools Update Complete' "$tmp/run4.log" ||
    fail "curl failures must not abort the remaining tools (#114)"

# --- 5. agent-browser binary missing at the prefix: setup skipped quietly -----
rm -f "$prefix/bin/agent-browser"
: >"$tmp/npm.log"; : >"$tmp/agent-browser.log"
run_updater "$tmp/run5.log" || true
if [ -s "$tmp/agent-browser.log" ]; then
    fail "a missing agent-browser binary must skip browser setup"
else
    pass
fi

finish
