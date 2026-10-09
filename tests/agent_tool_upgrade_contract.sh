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
# stubbed binaries (npm/npx/git/curl/claude/opencode/agy/uv/serena and
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

# Every network step is under net_timeout (the 2026-08-30 hang class, header of
# update_ai_tools.sh). The Playwright download and the agent-browser browser
# setup were the two left bare.
require "$ai_sh" 'net_timeout 600 npx --yes playwright install chromium'
require "$ai_sh" 'net_timeout 600 "$AGENT_BROWSER_BIN" install'

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
# Graft was dropped: dot upgrade retires it (Invoke-GraftRetirement, executed by
# tests/graft_retirement_contract.sh) and never upgrades it.
grep -Fq 'Invoke-GraftRetirement' "$ai_ps1" || fail "$ai_ps1: must retire Graft"
forbid "$ai_ps1" '@nanonets/graft@latest'

[ -f "$ai_sh" ] || { fail "$ai_sh missing"; finish; }
command -v timeout >/dev/null 2>&1 || skip "coreutils timeout not installed"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
home="$tmp/home"
prefix="$tmp/prefix" # what the npm stub answers `prefix -g` with
mkdir -p "$bin" "$home" "$prefix/bin"

# --- Stubs -------------------------------------------------------------------
# codex starts (exit 0): "current" requires a codex that runs (tests/codex_platform_binary_contract.sh)
for c in npx git uv serena opencode agy codex; do
    printf '#!/bin/sh\nexit 0\n' >"$bin/$c"
    chmod +x "$bin/$c"
done

# npm: logs every argv; `prefix -g` answers $NPM_FAKE_PREFIX; installs fail
# only when NPM_FAIL=1. A successful `install` prints npm's own summary line,
# the one the real npm prints even at --loglevel=error.
cat >"$bin/npm" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${NPM_LOG:?}"
if [ "${1:-}" = install ] && [ "${NPM_FAIL:-0}" != 1 ]; then printf '\nchanged 2 packages in 20s\n'; fi
if [ "${1:-}" = prefix ] && [ "${2:-}" = -g ]; then
    printf '%s\n' "${NPM_FAKE_PREFIX:?}"
    exit 0
fi
# `npm ls -g <pkg> --depth=0 --json` / `npm view <pkg> version`: the installed and the
# registry version the updater compares before reinstalling (NPM_LS_VERSION /
# NPM_VIEW_VERSION; unset = unknown, which must mean "install").
if [ "${1:-}" = ls ] && [ -n "${NPM_LS_VERSION:-}" ]; then
    printf '{"dependencies":{"%s":{"version":"%s"}}}\n' "${3:-}" "$NPM_LS_VERSION"
    exit 0
fi
if [ "${1:-}" = view ] && [ -n "${NPM_VIEW_VERSION:-}" ]; then
    printf '%s\n' "$NPM_VIEW_VERSION"
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
[ -n "${CURL_LOG:-}" ] && printf '%s\n' "$*" >> "$CURL_LOG"
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
# `--version` prints $CLAUDE_VERSION when set (unset = unknown, which must mean "run the installer").
cat >"$bin/claude" <<'EOF'
#!/bin/sh
[ "${1:-}" = update ] && exit 1
[ "${1:-}" = --version ] && [ -n "${CLAUDE_VERSION:-}" ] && printf '%s (Claude Code)\n' "$CLAUDE_VERSION"
exit 0
EOF
chmod +x "$bin/claude"

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
    HOME="$home" PATH="$bin:$PATH" NPM_LOG="$tmp/npm.log" \
        STUB_LOG="$tmp/agent-browser.log" NPM_FAKE_PREFIX="$prefix" \
        timeout 120 bash "$ai_sh" >"$out_file" 2>&1
}

# --- 1. Baseline: upgrades happen, catalog-driven, and the run completes -----
: >"$tmp/npm.log"
rm -f "$prefix/bin/agent-browser"; make_agent_browser
: >"$tmp/agent-browser.log"
out="$tmp/run1.log"
if run_updater "$out"; then pass; else fail "update_ai_tools.sh must run to completion with all tools present: $(tail -3 "$out")"; fi
grep -Fq 'install -g @openai/codex@latest' "$tmp/npm.log" ||
    fail "codex must upgrade via npm -g <catalog package>@latest; npm saw: $(grep codex "$tmp/npm.log" || true)"
grep -Fq 'install -g --allow-scripts=agent-browser agent-browser' "$tmp/npm.log" ||
    fail "agent-browser must be refreshed via npm -g with its allow-scripts list"
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
: >"$tmp/npm.log"
DOTUPGRADE_DEFER=codex,opencode,serena run_updater "$tmp/run2.log" || true
if grep -Fq 'codex deferred' "$tmp/run2.log"; then pass; else fail "deferred codex must be reported, not upgraded"; fi
if grep -Fq '@openai/codex@latest' "$tmp/npm.log"; then fail "DOTUPGRADE_DEFER=codex must suppress the npm @latest upgrade"; else pass; fi
# the catalog's npm tools (markdownlint-cli2) are not agent tools: a codex defer does not hold them
if grep -Fq 'install -g markdownlint-cli2@latest' "$tmp/npm.log"; then pass; else fail "catalog npm tools must still upgrade when codex is deferred; npm saw: $(tr '\n' ' ' <"$tmp/npm.log")"; fi
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

# --- 5b. npm tools that are already current are not reinstalled ---------------
# The codex `npm install -g` cost ~9 s on every run. For npm packages the installed
# (`npm ls -g`) and registry (`npm view`) versions are compared. Anything unknown -
# offline, no answer - still installs.
make_agent_browser
: >"$tmp/npm.log"
NPM_LS_VERSION=9.9.9 NPM_VIEW_VERSION=9.9.9 run_updater "$tmp/run5b.log" || true
grep -Fq 'codex is current (9.9.9)' "$tmp/run5b.log" || fail "current codex must be reported, not reinstalled"
if grep -Fq 'install -g @openai/codex@latest' "$tmp/npm.log"; then fail "codex 9.9.9 == latest must not reinstall"; else pass; fi
grep -Fq 'agent-browser is current (9.9.9)' "$tmp/run5b.log" || fail "a current agent-browser must be reported, not reinstalled"
if grep -Fq 'install -g --allow-scripts=agent-browser agent-browser' "$tmp/npm.log"; then fail "agent-browser 9.9.9 == latest must not reinstall"; else pass; fi
grep -Fq 'install' "$tmp/agent-browser.log" || fail "a current agent-browser still gets its browser setup"
grep -Fq 'doctor --json' "$tmp/agent-browser.log" || fail "a current agent-browser is still verified"

# Claude Code: the native installer (~20 s) re-runs only when `claude --version` differs from
# the latest release (read from its npm package, same version numbers); unknown re-runs it.
: >"$tmp/curl.log"
CURL_LOG="$tmp/curl.log" CLAUDE_VERSION=9.9.9 NPM_LS_VERSION=9.9.9 NPM_VIEW_VERSION=9.9.9 run_updater "$tmp/run5b-claude.log" || true
grep -Fq 'Claude Code is current (9.9.9)' "$tmp/run5b-claude.log" || fail "a current Claude Code must be reported, not reinstalled: $(grep -i 'claude code' "$tmp/run5b-claude.log" | head -3)"
if grep -Fq 'claude.ai/install.sh' "$tmp/curl.log"; then fail "a current Claude Code must not download its installer"; else pass; fi
: >"$tmp/curl.log"
CURL_LOG="$tmp/curl.log" CLAUDE_VERSION=9.9.8 NPM_VIEW_VERSION=9.9.9 run_updater "$tmp/run5c-claude.log" || true
grep -Fq 'claude.ai/install.sh' "$tmp/curl.log" || fail "a Claude Code behind the latest must re-run its installer"

: >"$tmp/npm.log"
NPM_LS_VERSION=9.9.8 NPM_VIEW_VERSION=9.9.9 run_updater "$tmp/run5c.log" || true
grep -Fq 'install -g @openai/codex@latest' "$tmp/npm.log" || fail "a stale codex must be reinstalled"
# The news is the version, not npm's "changed 2 packages in 20s" (seen on a real dot upgrade,
# 2026-10-09, with nothing saying what was changed).
grep -Fq 'codex upgraded to 9.9.9' "$tmp/run5c.log" || fail "a codex upgrade must report the version it installed: $(grep -i codex "$tmp/run5c.log" | head -3)"
if grep -Fq 'changed 2 packages' "$tmp/run5c.log"; then fail "npm's install summary must not reach the console on a successful codex upgrade"; else pass; fi
grep -Fq 'install -g --allow-scripts=agent-browser agent-browser' "$tmp/npm.log" || fail "a stale agent-browser must be reinstalled"

: >"$tmp/npm.log"
run_updater "$tmp/run5d.log" || true
grep -Fq 'install -g @openai/codex@latest' "$tmp/npm.log" || fail "unknown codex versions must not skip the reinstall"

# --- 6. dot upgrade retires Graft, in the prefix it lives in -------------------
# Graft was dropped from the dotfiles; the updater removes it (graft_retire, whose
# own behaviour is pinned by tests/graft_retirement_contract.sh). A graft under a
# non-default prefix (a stale ~/.local install on WSL) is uninstalled from THAT
# prefix, not npm's default one.
gprefix="$tmp/gprefix"
mkdir -p "$gprefix/bin" "$gprefix/lib/node_modules/@nanonets/graft/dist"
printf '#!/bin/sh\nexit 0\n' >"$gprefix/lib/node_modules/@nanonets/graft/dist/cli.js"
chmod +x "$gprefix/lib/node_modules/@nanonets/graft/dist/cli.js"
if ln -s ../lib/node_modules/@nanonets/graft/dist/cli.js "$gprefix/bin/graft" 2>/dev/null &&
    [ -L "$gprefix/bin/graft" ]; then
    ln -s "$gprefix/bin/graft" "$bin/graft"
    : >"$tmp/npm.log"
    run_updater "$tmp/run6.log" || true
    grep -Fq "uninstall -g --prefix $gprefix @nanonets/graft" "$tmp/npm.log" ||
        fail "graft under $gprefix must be uninstalled from that prefix; npm saw: $(tr '\n' ' ' <"$tmp/npm.log")"
    grep -Fq 'AI Tools Update Complete' "$tmp/run6.log" ||
        fail "a graft that would not uninstall (the stub leaves it) must not abort the updater"
    rm -f "$bin/graft"
else
    skip "symlinks unavailable"
fi

finish
