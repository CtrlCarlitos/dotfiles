#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # stub bodies are literal; harness variables are read by sourced code
set -euo pipefail

# Superpowers stays current in every harness, and `dot up` stops re-fetching it (2026-10-10 WSL
# logs, obra/superpowers at v7.0.0 the same day):
#
#   1. OpenCode loaded 6.3.0 for two months. It installs the opencode.json `plugin` entry into
#      ITS OWN cache (~/.cache/opencode/packages/superpowers@<spec>/, lockfile-pinned, reused for
#      as long as it exists); `dot upgrade` ran `npm install --prefix ~/.config/opencode`, a tree
#      OpenCode never reads, and that copy was at 7.0.0. The updater now re-resolves the git
#      dependency inside the directory OpenCode loads (opencode_superpowers_refresh).
#   2. `dot up` re-fetched the Codex plugin (`codex plugin add`, ~15 s), re-cloned the Antigravity
#      plugin (`agy plugin install`) and re-ran Playwright's install-deps + install (~20 s, its
#      own apt-get update) on every apply - upgrades, which `dot up` never does. Each step now
#      asks its tool first and skips with a line that says so.
#   3. Every updater step "succeeded" while Codex sat at 6.4.2 behind a lagging marketplace
#      catalog and three project-scope Claude installs sat at 6.2.0. `dot upgrade` ends with one
#      version line per harness against upstream's newest release tag.
#   4. `dot upgrade` said nothing about the VS Code extension update on success, and named the
#      outside-package-managers tools without saying whether any lagged.
#
# Executed in both languages where a twin exists: the shell helpers against stub codex/agy/git/
# npm/claude, the rendered installer functions against the same stubs, update_ai_tools.sh end to
# end, the dotupgrade.sh functions in isolation, and the PowerShell helpers under pwsh.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

lib="$repo_root/scripts/lib/agent-skills.sh"
ps_lib="$repo_root/scripts/lib/ps-skills.ps1"
ai_sh="$repo_root/scripts/update_ai_tools.sh"
ai_ps1="$repo_root/scripts/update_ai_tools.ps1"
up_sh="$repo_root/scripts/dotupgrade.sh"
up_ps1="$repo_root/scripts/dotupgrade.ps1"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"

# --- Wiring: the tree OpenCode never reads is gone from both updaters ------------------------
forbid "$ai_sh" '--prefix "$HOME/.config/opencode"'
require "$ai_sh" 'opencode_superpowers_refresh'
# The Windows installer points opencode.json at a PATH install under ~\.config\opencode (its git-spec
# workaround), so the ps1 updater keeps that refresh AND refreshes OpenCode's own cache.
require "$ai_ps1" 'Get-OpenCodeSuperpowersPathInstall'
require "$ai_ps1" 'Invoke-OpenCodeSuperpowersRefresh'
require "$ai_sh" 'superpowers_report'
require "$ai_ps1" 'Write-SuperpowersReport'
# claude_superpowers_installs's `claude plugin list --json` must run under net_timeout_tty, not
# plain net_timeout: a WSL `dot upgrade` (2026-10-11) sat with it stopped in state T (SIGTTIN) for
# 17+ minutes - plain net_timeout's `timeout` runs the command in a NEW process group, so a
# tty-touching claude outside the terminal's foreground group gets stopped by the kernel, and the
# stopped `timeout` process can't even act on its own alarm to kill it. Same bug class as #355's
# `claude mcp add`, fixed there with --foreground; this call site was missed.
require "$lib" 'net_timeout_tty 60 claude plugin list --json'
forbid "$lib" 'net_timeout 60 claude plugin list --json'
# dot up asks before it fetches
for pair in "$sh_installer:codex_superpowers_installed_version" "$sh_installer:agy_superpowers_installed" \
    "$sh_installer:install_playwright_chromium" "$ps1_installer:Get-CodexSuperpowersInstalledVersion" \
    "$ps1_installer:Test-AgySuperpowersInstalled" "$ps1_installer:Test-PlaywrightChromiumInstalled"; do
    require "${pair%%:*}" "${pair#*:}"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
home="$tmp/home"
mkdir -p "$bin" "$home"
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# --- Stubs ------------------------------------------------------------------------------------
# codex: `plugin list` prints the header and $CODEX_ROWS (one row per line); everything else logs.
cat >"$bin/codex" <<'STUB'
#!/bin/sh
[ -n "${STUB_LOG:-}" ] && printf 'codex %s\n' "$*" >>"$STUB_LOG"
if [ "${1:-}" = plugin ] && [ "${2:-}" = list ]; then
    printf '%s\n' 'Marketplace `test-marketplace`' '' 'PLUGIN  STATUS  VERSION  SOURCE'
    [ -n "${CODEX_ROWS:-}" ] && printf '%s\n' "$CODEX_ROWS"
    exit 0
fi
# `mcp get <server>`: nothing registered in the fixture home (mcp_registered falls back to this
# probe when ~/.codex/config.toml is absent), so `serena setup codex` still runs
if [ "${1:-}" = mcp ] && [ "${2:-}" = get ]; then exit 1; fi
# `plugin add`: what the real one prints (the version is the root's last path element)
if [ "${1:-}" = plugin ] && [ "${2:-}" = add ]; then
    printf 'Added plugin `superpowers` from marketplace `test-marketplace`.\nInstalled plugin root: /h/.codex/plugins/cache/test-marketplace/superpowers/6.4.2\n'
    exit 0
fi
[ "${1:-}" = --version ] && printf 'codex-cli 1.0.0\n'
exit 0
STUB
# agy: `plugin list` prints an imports document naming $AGY_IMPORTS; everything else logs.
cat >"$bin/agy" <<'STUB'
#!/bin/sh
[ -n "${STUB_LOG:-}" ] && printf 'agy %s\n' "$*" >>"$STUB_LOG"
if [ "${1:-}" = plugin ] && [ "${2:-}" = list ]; then
    printf '{\n  "imports": [\n'
    for n in ${AGY_IMPORTS:-}; do printf '    { "name": "%s", "source": "gemini-cli" },\n' "$n"; done
    printf '    { "name": "other", "source": "gemini-cli" }\n  ]\n}\n'
fi
exit 0
STUB
# git: `ls-remote --tags` answers from $GIT_TAGS_DIR/<owner>_<repo> (a refs listing) when present.
cat >"$bin/git" <<'STUB'
#!/bin/sh
if [ "${1:-}" = ls-remote ]; then
    url=""
    for a in "$@"; do case "$a" in https://github.com/*) url="$a" ;; esac; done
    repo="${url#https://github.com/}"; repo="${repo%.git}"
    f="${GIT_TAGS_DIR:-/nonexistent}/$(printf '%s' "$repo" | tr / _)"
    [ -f "$f" ] && cat "$f"
    exit 0
fi
exit 0
STUB
# npm: logs argv; `prefix -g` answers $NPM_FAKE_PREFIX; `ls`/`view` report 9.9.9 (everything
# current, so the real reinstalls stay out of the way); an `install --prefix <dir> superpowers@...`
# bumps the fake package's version to $NPM_SP_VERSION, the way a refresh would.
cat >"$bin/npm" <<'STUB'
#!/bin/sh
[ -n "${NPM_LOG:-}" ] && printf '%s\n' "$*" >>"$NPM_LOG"
if [ "${1:-}" = prefix ] && [ "${2:-}" = -g ]; then printf '%s\n' "${NPM_FAKE_PREFIX:?}"; exit 0; fi
if [ "${1:-}" = ls ]; then printf '{"dependencies":{"%s":{"version":"9.9.9"}}}\n' "${3:-}"; exit 0; fi
if [ "${1:-}" = view ]; then printf '9.9.9\n'; exit 0; fi
if [ "${1:-}" = install ] && [ "${2:-}" = --prefix ]; then
    f="$3/node_modules/superpowers/package.json"
    [ -f "$f" ] && printf '{\n  "name": "superpowers",\n  "version": "%s"\n}\n' "${NPM_SP_VERSION:-7.0.0}" >"$f"
    [ "${NPM_FAIL:-0}" = 1 ] && { echo 'npm ERR! boom'; exit 1; }
fi
exit 0
STUB
# npx: logs argv (Playwright's two steps, the skills CLI); `playwright install` prints $NPX_PLAYWRIGHT_SAYS.
cat >"$bin/npx" <<'STUB'
#!/bin/sh
[ -n "${STUB_LOG:-}" ] && printf 'npx %s\n' "$*" >>"$STUB_LOG"
case "$*" in *"playwright install chromium"*) [ -n "${NPX_PLAYWRIGHT_SAYS:-}" ] && printf '%s\n' "$NPX_PLAYWRIGHT_SAYS" ;; esac
exit 0
STUB
# claude: `plugin list --json` prints $CLAUDE_PLUGINS_JSON; `--version` says 9.9.9 (current).
# CLAUDE_PLUGIN_LIST_HANG sleeps first: on Linux pwsh resolves the bare `claude` command to
# THIS executable bit file ahead of the claude.ps1 sibling below (unlike Windows pwsh, which
# has no bare-executable match for an extensionless file and falls through to the .ps1) - the
# hang simulation has to live in both stubs or section E's PowerShell timeout test only
# exercises it on Windows.
cat >"$bin/claude" <<'STUB'
#!/bin/sh
[ -n "${STUB_LOG:-}" ] && printf 'claude %s\n' "$*" >>"$STUB_LOG"
if [ "${1:-}" = plugin ] && [ "${2:-}" = list ]; then
    [ "${CLAUDE_PLUGIN_LIST_HANG:-0}" = 1 ] && sleep 30
    [ "${CLAUDE_PLUGIN_LIST_FAIL:-0}" = 1 ] && exit 1
    printf '%s\n' "${CLAUDE_PLUGINS_JSON:-[]}"
    exit 0
fi
[ "${1:-}" = --version ] && printf '9.9.9 (Claude Code)\n'
exit 0
STUB
for c in uv opencode curl; do printf '#!/bin/sh\nexit 0\n' >"$bin/$c"; done
printf '#!/bin/sh\n[ -n "${STUB_LOG:-}" ] && printf "serena %%s\\n" "$*" >>"$STUB_LOG"\nexit 0\n' >"$bin/serena"
# curl fails the installer downloads (the updater must warn-and-continue past them, #114)
printf '#!/bin/sh\nexit 7\n' >"$bin/curl"
chmod +x "$bin"/*

# --- A. Shell helpers, executed ----------------------------------------------------------------
helper() { # <env assignments...> -- <function> [args]: run one library helper with the stubs on PATH
    local envs=()
    while [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    env "${envs[@]}" HOME="$home" PATH="$bin:$PATH" bash -c '. "$1"; shift; "$@"' _ "$lib" "$@"
}
row_installed='superpowers@test-marketplace    installed, enabled  6.4.2    plugins~Plugin_abc'
row_absent='superpowers@test-marketplace      not installed       6.4.2    plugins~Plugin_abc'

got="$(helper CODEX_ROWS="$row_installed" -- codex_superpowers_installed_version)"
[ "$got" = 6.4.2 ] || fail "codex_superpowers_installed_version: expected 6.4.2 for an installed row, got '$got'"
if helper CODEX_ROWS="$row_absent" -- codex_superpowers_installed_version >/dev/null; then
    fail "codex_superpowers_installed_version: a 'not installed' row must fail (exit 1)"
fi
got="$(helper CODEX_ROWS="$row_absent" -- codex_superpowers_catalog_version)"
[ "$got" = 6.4.2 ] || fail "codex_superpowers_catalog_version: the catalog version is listed whether installed or not, got '$got'"
got="$(helper CODEX_ROWS="" -- codex_superpowers_catalog_version)"
[ -z "$got" ] || fail "codex_superpowers_catalog_version: no row must yield nothing, got '$got'"
pass

if ! helper AGY_IMPORTS="superpowers" -- agy_superpowers_installed; then fail "agy_superpowers_installed: an imported superpowers must be found"; fi
if helper AGY_IMPORTS="something-else" -- agy_superpowers_installed; then fail "agy_superpowers_installed: no superpowers import must fail"; fi
pass

tags="$tmp/tags"
mkdir -p "$tags"
printf '%s\n' 'aaa refs/tags/v6.4.2' 'bbb refs/tags/v7.0.0' 'ccc refs/tags/v10.1.0' 'ddd refs/tags/windows-strip-binary' >"$tags/obra_superpowers"
printf '%s\n' 'aaa refs/tags/lychee-v0.24.2' 'bbb refs/tags/v0.15.1' 'ccc refs/tags/lychee-v0.9.0' >"$tags/lycheeverse_lychee"
got="$(helper GIT_TAGS_DIR="$tags" -- superpowers_latest_version)"
[ "$got" = 10.1.0 ] || fail "superpowers_latest_version: numeric order (10.1.0 > 7.0.0), v stripped, non-release tags ignored; got '$got'"
got="$(helper GIT_TAGS_DIR="$tags" -- github_latest_tag lycheeverse/lychee)"
[ "$got" = 0.24.2 ] || fail "github_latest_tag: a '<name>-v' prefix must be stripped before comparing, got '$got'"
got="$(helper GIT_TAGS_DIR="$tags" -- github_latest_tag nobody/nothing)"
[ -z "$got" ] || fail "github_latest_tag: an unreachable repo must yield nothing, got '$got'"
pass

oc_dir="$home/.cache/opencode/packages/superpowers@git+https:/github.com/obra/superpowers.git"
seed_opencode_cache() { # $1 = version
    mkdir -p "$oc_dir/node_modules/superpowers"
    printf '{\n  "dependencies": {\n    "superpowers": "github:obra/superpowers"\n  }\n}\n' >"$oc_dir/package.json"
    printf '{\n  "name": "superpowers",\n  "version": "%s"\n}\n' "$1" >"$oc_dir/node_modules/superpowers/package.json"
}
seed_opencode_cache 6.3.0
got="$(helper -- opencode_superpowers_cache_dirs)"
[ "$got" = "$oc_dir" ] || fail "opencode_superpowers_cache_dirs: expected OpenCode's own cache directory, got '$got'"
got="$(helper -- opencode_superpowers_version)"
[ "$got" = 6.3.0 ] || fail "opencode_superpowers_version: expected 6.3.0 from the cached package, got '$got'"
: >"$tmp/npm.log"
helper NPM_LOG="$tmp/npm.log" NPM_SP_VERSION=7.0.0 -- opencode_superpowers_refresh "$bin/npm" || fail "opencode_superpowers_refresh must succeed when npm does"
grep -Fq "install --prefix $oc_dir superpowers@github:obra/superpowers" "$tmp/npm.log" ||
    fail "opencode_superpowers_refresh must re-resolve the git dependency inside OpenCode's cache directory; npm saw: $(cat "$tmp/npm.log")"
got="$(helper -- opencode_superpowers_version)"
[ "$got" = 7.0.0 ] || fail "after the refresh the cached package must carry the new version, got '$got'"
if helper NPM_LOG="$tmp/npm.log" NPM_FAIL=1 -- opencode_superpowers_refresh "$bin/npm" 2>/dev/null; then
    fail "opencode_superpowers_refresh must fail when npm does"
fi
rm -rf "$home/.cache/opencode"
got="$(helper -- opencode_superpowers_cache_dirs)"
[ -z "$got" ] || fail "opencode_superpowers_cache_dirs: nothing when OpenCode has not installed the plugin, got '$got'"
pass

mkdir -p "$home/.gemini/config/plugins/superpowers/.claude-plugin"
printf '{\n  "name": "superpowers",\n  "version": "7.0.0"\n}\n' >"$home/.gemini/config/plugins/superpowers/.claude-plugin/plugin.json"
got="$(helper -- antigravity_superpowers_version)"
[ "$got" = 7.0.0 ] || fail "antigravity_superpowers_version: expected 7.0.0 from agy's plugin store, got '$got'"
pass

if helper -- playwright_chromium_installed; then fail "playwright_chromium_installed: no browser cache must fail"; fi
mkdir -p "$home/.cache/ms-playwright/chromium-1248"
if helper -- playwright_chromium_installed; then fail "playwright_chromium_installed: a chromium-* directory without INSTALLATION_COMPLETE is an interrupted download, not an install"; fi
: >"$home/.cache/ms-playwright/chromium-1248/INSTALLATION_COMPLETE"
helper -- playwright_chromium_installed || fail "playwright_chromium_installed: a complete chromium-* build in ~/.cache/ms-playwright must be found"
helper PLAYWRIGHT_BROWSERS_PATH=0 -- playwright_chromium_installed || fail "playwright_chromium_installed: PLAYWRIGHT_BROWSERS_PATH=0 means the default cache"
rm -rf "$home/.cache/ms-playwright"
mkdir -p "$tmp/pw-elsewhere/chromium-9"
: >"$tmp/pw-elsewhere/chromium-9/INSTALLATION_COMPLETE"
helper PLAYWRIGHT_BROWSERS_PATH="$tmp/pw-elsewhere" -- playwright_chromium_installed || fail "playwright_chromium_installed must honour PLAYWRIGHT_BROWSERS_PATH"
pass

got="$(helper -- superpowers_version_line Codex 6.4.2 7.0.0 'the catalog offers 6.4.2')"
[ "$got" = '   Codex: 6.4.2 - behind upstream v7.0.0 (the catalog offers 6.4.2)' ] || fail "superpowers_version_line (behind): got '$got'"
got="$(helper -- superpowers_version_line OpenCode 7.0.0 7.0.0 'note')"
[ "$got" = '   OpenCode: 7.0.0 (current)' ] || fail "superpowers_version_line (current): got '$got'"
got="$(helper -- superpowers_version_line Antigravity '' 7.0.0)"
[ "$got" = '   Antigravity: not installed' ] || fail "superpowers_version_line (missing): got '$got'"
got="$(helper -- superpowers_version_line Codex 6.4.2 '')"
[ "$got" = '   Codex: 6.4.2 (upstream unreachable)' ] || fail "superpowers_version_line (offline): got '$got'"
pass

# --- B. The rendered installer functions, executed against the same stubs ----------------------
rendered="$tmp/installer.sh"
render_to "$rendered" sh '{"agent_toolkit": true, "chatgpt_cli": true, "antigravity_cli": true}'
extract() { awk -v name="$1" '$0 == name "() {" {f=1} f {print} f && /^\}$/ {exit}' "$rendered"; }
for fn in install_chatgpt_cli install_antigravity_cli install_playwright_chromium; do
    [ -n "$(extract "$fn")" ] || fail "rendered installer: $fn not found"
done
harness="$tmp/installer-harness.sh"
{
    # timing.sh too: install_chatgpt_cli carries "Codex: ..." sub-marks (2026-10-11), and the
    # installer always has the timing helpers inlined next to the lib.
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' ". \"$lib\"" ". \"$repo_root/scripts/lib/timing.sh\"" \
        'PKG_MANAGER=apt; npm_sudo=""; NPM_BIN="$(command -v npm)"; NPX_BIN="$(command -v npx)"' \
        'install_node() { :; }' 'sudo_net_timeout_tty() { shift 2; "$@"; }' 'ensure_jq() { :; }'
    extract install_chatgpt_cli; extract install_antigravity_cli; extract install_playwright_chromium
    printf '%s\n' '"$@"'
} >"$harness"
run_fn() { # <function>; stubs log to $tmp/stub.log, output to $tmp/fn.log
    : >"$tmp/stub.log"
    HOME="$home" PATH="$bin:$PATH" STUB_LOG="$tmp/stub.log" NPM_FAKE_PREFIX="$tmp/prefix" timeout 60 bash "$harness" "$1" >"$tmp/fn.log" 2>&1 || fail "$1 exited non-zero: $(tail -3 "$tmp/fn.log")"
}

CODEX_ROWS="$row_installed" run_fn install_chatgpt_cli
grep -Fq 'Superpowers for Codex is installed (6.4.2) - skipping the plugin add (dot upgrade updates it).' "$tmp/fn.log" ||
    fail "dot up: an installed Codex plugin must be skipped with a line that says so (got: $(cat "$tmp/fn.log"))"
if grep -Fq 'codex plugin add' "$tmp/stub.log"; then fail "dot up must not re-add (re-fetch) an installed Codex plugin"; else pass; fi
grep -Fq 'serena setup codex' "$tmp/stub.log" || fail "the Serena registration for Codex must still run when the plugin is skipped"
CODEX_ROWS="$row_absent" run_fn install_chatgpt_cli
grep -Fq 'codex plugin add superpowers@test-marketplace' "$tmp/stub.log" ||
    fail "dot up must add a Codex plugin that is not installed (codex saw: $(grep codex "$tmp/stub.log" | tr '\n' ' '))"
pass

AGY_IMPORTS=superpowers run_fn install_antigravity_cli
grep -Fq 'Superpowers for Antigravity is installed - skipping the plugin install (dot upgrade updates it).' "$tmp/fn.log" ||
    fail "dot up: an imported Antigravity plugin must be skipped with a line that says so (got: $(cat "$tmp/fn.log"))"
if grep -Fq 'agy plugin install' "$tmp/stub.log"; then fail "dot up must not re-clone an installed Antigravity plugin"; else pass; fi
AGY_IMPORTS=other run_fn install_antigravity_cli
grep -Fq 'agy plugin install https://github.com/obra/superpowers' "$tmp/stub.log" || fail "dot up must install a missing Antigravity plugin"
pass

mkdir -p "$home/.cache/ms-playwright/chromium-1248"
: >"$home/.cache/ms-playwright/chromium-1248/INSTALLATION_COMPLETE"
run_fn install_playwright_chromium
grep -Fq 'Playwright Chromium is installed - skipping the download (dot upgrade updates it).' "$tmp/fn.log" ||
    fail "dot up: a cached Chromium build must be skipped with a line that says so (got: $(cat "$tmp/fn.log"))"
if grep -Fq 'playwright' "$tmp/stub.log"; then fail "dot up must run neither install-deps nor install when the build is cached (npx saw: $(cat "$tmp/stub.log"))"; else pass; fi
rm -rf "$home/.cache/ms-playwright"
run_fn install_playwright_chromium
grep -Fq 'npx --yes playwright install-deps chromium' "$tmp/stub.log" || fail "a missing build must still get its system deps (npx saw: $(cat "$tmp/stub.log"))"
grep -Fq 'npx --yes playwright install chromium' "$tmp/stub.log" || fail "a missing build must still be downloaded"
pass

# --- C. update_ai_tools.sh end to end: the OpenCode refresh and the version report --------------
# chezmoi: the real binary against a scratch source carrying the repo's data, so the catalog
# reads resolve as in production (same as tests/agent_tool_upgrade_contract.sh).
scratch="$tmp/repo"
mkdir -p "$scratch" "$tmp/prefix/bin"
cp "$repo_root/.chezmoidata.yaml" "$scratch/"
cp -r "$repo_root/.chezmoidata" "$scratch/"
real_chezmoi="$(command -v chezmoi)" || skip "chezmoi not installed"
cat >"$bin/chezmoi" <<STUB
#!/bin/sh
[ "\${1:-}" = execute-template ] && shift
exec "$real_chezmoi" execute-template --source "$scratch" "\$@"
STUB
chmod +x "$bin/chezmoi"
# Two non-user installs: a project-scope one whose directory exists (behind), and a local-scope one
# whose directory is gone - a deleted worktree (2026-10-11: two such entries lingered at 6.2.0 and
# 6.3.0, and "run claude plugin update inside each" could not be followed).
mkdir -p "$home/projects/takumi"
claude_json='[{"id":"superpowers@superpowers-marketplace","version":"7.0.0","scope":"user","enabled":true},{"id":"superpowers@superpowers-marketplace","version":"6.2.0","scope":"project","enabled":true,"projectPath":"'"$home"'/projects/takumi"},{"id":"superpowers@superpowers-marketplace","version":"6.3.0","scope":"local","enabled":true,"projectPath":"'"$home"'/projects/gone/.worktrees/old"},{"id":"other@m","version":"1.0.0","scope":"user"}]'
run_updater() { # $1 = output file; extra env from the caller
    : >"$tmp/npm.log"; : >"$tmp/stub.log"
    HOME="$home" PATH="$bin:$PATH" NPM_LOG="$tmp/npm.log" STUB_LOG="$tmp/stub.log" NPM_FAKE_PREFIX="$tmp/prefix" \
        GIT_TAGS_DIR="${GIT_TAGS_DIR:-$tags}" CODEX_ROWS="$row_installed" AGY_IMPORTS=superpowers CLAUDE_PLUGINS_JSON="$claude_json" \
        timeout 120 bash "$ai_sh" >"$1" 2>&1 || fail "update_ai_tools.sh must run to completion: $(tail -3 "$1")"
}
command -v timeout >/dev/null 2>&1 || skip "coreutils timeout not installed"
seed_opencode_cache 6.3.0
out="$tmp/updater-1.log"
NPM_SP_VERSION=7.0.0 run_updater "$out"
grep -Fq "install --prefix $oc_dir superpowers@github:obra/superpowers" "$tmp/npm.log" ||
    fail "dot upgrade must refresh Superpowers inside OpenCode's cache directory; npm saw: $(grep -F superpowers "$tmp/npm.log" | tr '\n' ' ')"
if grep -Fq '.config/opencode' "$tmp/npm.log"; then fail "dot upgrade must not touch ~/.config/opencode for Superpowers any more"; else pass; fi
grep -Fq 'Superpowers (OpenCode) upgraded to 7.0.0' "$out" || fail "an OpenCode refresh that moved the version must report it (got: $(grep -F OpenCode "$out" | tr '\n' ' '))"
grep -Fq 'AI Tools Update Complete' "$out" || fail "the updater must reach its end (#114)"
# the report (upstream from the git stub's tags: 10.1.0 is the newest release-looking tag there)
printf '%s\n' 'aaa refs/tags/v6.4.2' 'bbb refs/tags/v7.0.0' >"$tags/obra_superpowers"
out="$tmp/updater-2.log"
run_updater "$out"
grep -Fq 'Superpowers (OpenCode) is current (7.0.0)' "$out" || fail "a second refresh with nothing new must say current (got: $(grep -F OpenCode "$out" | tr '\n' ' '))"
expect() { grep -Fq -- "$1" "$out" || fail "report: expected '$1' (got: $(grep -F -A8 'Superpowers versions' "$out" | tr '\n' '|'))"; }
expect 'Superpowers versions (upstream: v7.0.0):'
expect '   Claude Code: 7.0.0 (current)'
if command -v jq >/dev/null 2>&1; then
    # the scope is named as Claude reports it; a behind install can be updated or removed in place,
    # and one whose directory is gone can only be removed - each line says how
    expect "project/local-scope installs behind: 6.2.0 (project) in ~/projects/takumi - inside each: 'claude plugin update superpowers@superpowers-marketplace', or 'claude plugin uninstall superpowers@superpowers-marketplace --scope <scope>' so the user-scope install applies"
    expect "stale installs (directory gone): 6.3.0 (local) in ~/projects/gone/.worktrees/old - recreate the directory, run 'claude plugin uninstall superpowers@superpowers-marketplace --scope <scope>' inside it, then delete it"
    if grep -Fq 'installs behind: 6.2.0 (project) in ~/projects/takumi, 6.3.0' "$out"; then fail "report: a gone directory must not be listed as merely behind"; else pass; fi
else
    printf 'note: jq not installed - the project-scope line is not checked\n'
fi
expect '   OpenCode: 7.0.0 (current)'
expect '   Antigravity: 7.0.0 (current)'
expect '   Codex: 6.4.2 (marketplace latest - upstream v7.0.0 is not published there yet)'
pass
# the three headers that printed nothing under them (2026-10-12) each get an outcome line
expect '   Superpowers (Antigravity) is current (7.0.0)'
expect '   Superpowers (Codex) is 6.4.2 - the marketplace has not published v7.0.0 yet'
expect '   Playwright Chromium is up to date'
out="$tmp/updater-2b.log"
NPX_PLAYWRIGHT_SAYS='Downloading Chromium 1248 (playwright build v1248) from https://cdn.playwright.dev/...' run_updater "$out"
expect '   Playwright Chromium: new build downloaded'
pass
# no cache yet (a fresh machine before OpenCode's first start), and a deferred opencode
rm -rf "$home/.cache/opencode"
out="$tmp/updater-3.log"
run_updater "$out"
grep -Fq 'OpenCode has not installed its Superpowers plugin yet (it does on its next start) - skipping' "$out" ||
    fail "no cache directory must be reported, not refreshed (got: $(grep -F OpenCode "$out" | tr '\n' ' '))"
if grep -Fq 'superpowers@github' "$tmp/npm.log"; then fail "nothing to refresh must mean no npm call"; else pass; fi
seed_opencode_cache 6.3.0
out="$tmp/updater-4.log"
DOTUPGRADE_DEFER=opencode run_updater "$out"
grep -Fq 'opencode deferred - Superpowers (OpenCode) update skipped with it.' "$out" || fail "a live opencode session must defer the refresh of the directory it loads from"
if grep -Fq 'superpowers@github' "$tmp/npm.log"; then fail "a deferred opencode must not have its plugin directory rewritten"; else pass; fi
# offline: the report still prints, and judges nothing
out="$tmp/updater-5.log"
GIT_TAGS_DIR=/nonexistent run_updater "$out"
grep -Fq 'Superpowers versions (upstream: unreachable):' "$out" || fail "offline, the report must say upstream is unreachable"
grep -Fq '   Codex: 6.4.2 (upstream unreachable)' "$out" || fail "offline, no harness is judged behind (got: $(grep -F 'Codex:' "$out"))"
pass
# a `claude plugin list --json` that fails or hangs (2026-10-11: killed by net_timeout after 60 s on
# a WSL box with a user-scope 7.0.0 install) is a failed lookup, never "not installed"
out="$tmp/updater-6.log"
CLAUDE_PLUGIN_LIST_FAIL=1 run_updater "$out"
grep -Fq '   Claude Code: lookup failed (claude plugin list --json errored or timed out - re-run dot upgrade)' "$out" \
    || fail "a failed plugin lookup must be reported as such (got: $(grep -F 'Claude Code:' "$out" | tr '\n' '|'))"
if grep -Fq '   Claude Code: not installed' "$out"; then fail "a failed lookup must not read as 'not installed'"; else pass; fi
# `claude plugin update` ran on every run (14 s on WSL, 2026-10-12, to say "already at the latest
# version") and the report asked `claude plugin list --json`: with installed_plugins.json on disk
# both read the file, and a user-scope install at upstream's release skips the update.
mkdir -p "$home/.claude/plugins"
sp_file="$home/.claude/plugins/installed_plugins.json"
sp_fixture() { # <user version>
    printf '{"version": 2, "plugins": {"superpowers@superpowers-marketplace": [{"scope": "user", "version": "%s"}, {"scope": "project", "version": "6.2.0", "projectPath": "%s"}, {"scope": "local", "version": "6.3.0", "projectPath": "%s"}]}}\n' \
        "$1" "$home/projects/takumi" "$home/projects/gone/.worktrees/old" >"$sp_file"
}
if command -v jq >/dev/null 2>&1; then
    sp_fixture 7.0.0
    out="$tmp/updater-7.log"
    CLAUDE_PLUGIN_LIST_FAIL=1 run_updater "$out"
    grep -Fq '   Superpowers (Claude Code) is current (7.0.0)' "$out" || fail "file at upstream's release: the plugin update must be skipped and say current (got: $(grep -F 'Superpowers (Claude Code)' "$out" | tr '\n' '|'))"
    if grep -Fq 'claude plugin update' "$tmp/stub.log"; then fail "file at upstream's release: no 'claude plugin update' call (log: $(grep claude "$tmp/stub.log" | tr '\n' '|'))"; else pass; fi
    if grep -Fq 'claude plugin list' "$tmp/stub.log"; then fail "the report must read installed_plugins.json, not call 'claude plugin list' (log: $(grep claude "$tmp/stub.log" | tr '\n' '|'))"; else pass; fi
    expect '   Claude Code: 7.0.0 (current)'
    expect "project/local-scope installs behind: 6.2.0 (project) in ~/projects/takumi - inside each:"
    expect "stale installs (directory gone): 6.3.0 (local) in ~/projects/gone/.worktrees/old - recreate the directory,"
    # behind the release: the update runs; the file still says 6.4.2 afterwards (the stub changes
    # nothing), which is the marketplace-lag outcome
    sp_fixture 6.4.2
    out="$tmp/updater-8.log"
    run_updater "$out"
    grep -Fq 'claude plugin update superpowers@superpowers-marketplace -y' "$tmp/stub.log" || fail "file behind upstream's release: the plugin update must run (log: $(grep claude "$tmp/stub.log" | tr '\n' '|'))"
    grep -Fq '   Superpowers (Claude Code) is 6.4.2 - the marketplace has not published v7.0.0 yet' "$out" || fail "an update that moved nothing must say what the marketplace has (got: $(grep -F 'Superpowers (Claude Code)' "$out" | tr '\n' '|'))"
    expect '   Claude Code: 6.4.2 - behind upstream v7.0.0 (re-run dot upgrade)'
    pass
fi
rm -f "$sp_file"
require "$ai_sh" "dot_timing_mark 'Superpowers (Codex)'"
require "$ai_sh" "dot_timing_mark 'Superpowers (Claude Code)'"
require "$ai_ps1" "Add-DotTimingMark -Name 'Superpowers (Codex)'"
require "$ai_ps1" "Add-DotTimingMark -Name 'Superpowers (Claude Code)'"

# --- D. dotupgrade.sh: the VS Code extension line and the release-lag note, executed -------------
up_harness="$tmp/dotupgrade-fns.sh"
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail' ". \"$lib\""
    awk '/^vscode_extensions_report\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$up_sh"
    awk '/^unmanaged_present\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$up_sh"
    printf '%s\n' '"$@"'
} >"$up_harness"
grep -q 'unmanaged_present() {' "$up_harness" || fail "dotupgrade.sh: the unmanaged helpers were not extracted"
printf 'No extension to update\n' >"$tmp/code.out"
got="$(bash "$up_harness" vscode_extensions_report "$tmp/code.out" 0)"
[ "$got" = '  VS Code extensions: up to date' ] || fail "vscode_extensions_report (nothing to do): got '$got'"
printf '%s\n' "(node:1) [DEP0169] DeprecationWarning: url.parse()" "Extension 'ms-python.python' v2026.1.0 was successfully updated." "Extension 'golang.go' v0.50.0 was successfully updated." >"$tmp/code.out"
got="$(bash "$up_harness" vscode_extensions_report "$tmp/code.out" 0)"
[ "$got" = '  VS Code extensions: 2 updated - ms-python.python v2026.1.0, golang.go v0.50.0' ] || fail "vscode_extensions_report (updates): got '$got'"
printf 'Error: could not reach the marketplace\n' >"$tmp/code.out"
got="$(bash "$up_harness" vscode_extensions_report "$tmp/code.out" 1)"
printf '%s' "$got" | grep -Fq 'VS Code extension update did not finish cleanly (exit 1) - continuing.' || fail "vscode_extensions_report (failure): got '$got'"
printf '%s' "$got" | grep -Fq 'could not reach the marketplace' || fail "a failed extension update must show its output"
pass

# A PATH of stubs plus the coreutils the function needs, so the host's own tools cannot leak in.
# delta and dust are upgraded by `dot upgrade` itself since 2026-10-11 (github_tool_sync), so
# the note no longer names them, lagging or not.
sys="$tmp/sys"
mkdir -p "$sys"
for c in bash sh grep sed sort head tail cat tr wc paste mktemp rm mkdir uname awk cut timeout env printf dirname basename readlink; do
    if p="$(command -v "$c" 2>/dev/null)"; then ln -s "$p" "$sys/$c" 2>/dev/null || true; fi
done
printf '#!/bin/sh\nprintf "delta 0.19.2\\n"\n' >"$sys/delta"
printf '#!/bin/sh\nprintf "Dust 1.2.6\\n"\n' >"$sys/dust"
printf '#!/bin/sh\nexit 1\n' >"$sys/dpkg"
chmod +x "$sys/delta" "$sys/dust" "$sys/dpkg"
got="$(HOME="$home" PATH="$sys" bash "$up_harness" unmanaged_present)"
[ -z "$got" ] || fail "unmanaged_present: tools dot upgrade keeps current must not be named; got '$got'"
pass

# --- E. PowerShell twins, executed under pwsh -----------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    # Native pwsh resolves bare commands through its own extension list; mirror the stubs as .ps1
    # siblings so they shadow any real codex/agy on PATH (tests/codex_marketplace_contract.sh).
    cat >"$bin/codex.ps1" <<'PSSTUB'
if ($args[0] -eq 'plugin' -and $args[1] -eq 'list') {
    'PLUGIN  STATUS  VERSION  SOURCE'
    if ($env:CODEX_ROWS) { $env:CODEX_ROWS -split "`n" }
}
PSSTUB
    cat >"$bin/agy.ps1" <<'PSSTUB'
if ($args[0] -eq 'plugin' -and $args[1] -eq 'list') {
    $names = @(); if ($env:AGY_IMPORTS) { $names = $env:AGY_IMPORTS -split ' ' }
    $items = @($names | ForEach-Object { "    { `"name`": `"$_`", `"source`": `"gemini-cli`" }" }) + @('    { "name": "other", "source": "gemini-cli" }')
    "{`n  `"imports`": [`n" + ($items -join ",`n") + "`n  ]`n}"
}
PSSTUB
    cat >"$bin/git.ps1" <<'PSSTUB'
if ($args[0] -eq 'ls-remote') {
    $url = @($args | Where-Object { "$_" -like 'https://github.com/*' })[0]
    $repo = ($url -replace '^https://github.com/', '') -replace '\.git$', ''
    $f = Join-Path $env:GIT_TAGS_DIR ($repo -replace '/', '_')
    if (Test-Path $f) { Get-Content $f }
}
PSSTUB
    cat >"$bin/npm.ps1" <<'PSSTUB'
if ($env:NPM_LOG) { Add-Content -LiteralPath $env:NPM_LOG -Value ($args -join ' ') }
if ($args[0] -eq 'install' -and $args[1] -eq '--prefix') {
    $f = Join-Path $args[2] 'node_modules/superpowers/package.json'
    if (Test-Path $f) { Set-Content -LiteralPath $f -Value "{`n  `"name`": `"superpowers`",`n  `"version`": `"7.0.0`"`n}" }
}
PSSTUB
    cat >"$bin/claude.ps1" <<'PSSTUB'
if ($args[0] -eq 'plugin' -and $args[1] -eq 'list') {
    if ($env:CLAUDE_PLUGIN_LIST_HANG -eq '1') { Start-Sleep -Seconds 30 }
    if ($env:CLAUDE_PLUGIN_LIST_FAIL -eq '1') { exit 1 }
    if ($env:CLAUDE_PLUGINS_JSON) { $env:CLAUDE_PLUGINS_JSON } else { '[]' }
    exit 0
}
PSSTUB
    seed_opencode_cache 6.3.0
    mkdir -p "$home/.cache/ms-playwright/chromium-1248"
    : >"$home/.cache/ms-playwright/chromium-1248/INSTALLATION_COMPLETE"
    cat >"$tmp/ps-harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$UserDir, [string]$CacheDir, [string]$NpmLog)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $UserDir
$env:HOME = $UserDir
. $Lib
$env:CODEX_ROWS = 'superpowers@test-marketplace    installed, enabled  6.4.2    plugins~Plugin_abc'
Write-Output ('codex-installed=' + (Get-CodexSuperpowersInstalledVersion))
Write-Output ('codex-catalog=' + (Get-CodexSuperpowersCatalogVersion))
$env:CODEX_ROWS = 'superpowers@test-marketplace      not installed       6.4.2    plugins~Plugin_abc'
Write-Output ('codex-absent-empty=' + ([string]::IsNullOrEmpty((Get-CodexSuperpowersInstalledVersion))))
Write-Output ('codex-absent-catalog=' + (Get-CodexSuperpowersCatalogVersion))
$env:AGY_IMPORTS = 'superpowers'
Write-Output ('agy-installed=' + (Test-AgySuperpowersInstalled))
$env:AGY_IMPORTS = 'other'
Write-Output ('agy-absent=' + (Test-AgySuperpowersInstalled))
Write-Output ('antigravity-version=' + (Get-AntigravitySuperpowersVersion))
Write-Output ('latest=' + (Get-SuperpowersLatestVersion))
Write-Output ('latest-lychee=' + (Get-GitHubLatestTag -Repo 'lycheeverse/lychee'))
Write-Output ('latest-none=' + (Get-GitHubLatestTag -Repo 'nobody/nothing'))
$dirs = @(Get-OpenCodeSuperpowersCacheDir)
Write-Output ('opencode-dir=' + ($dirs -join ';'))
Write-Output ('opencode-version=' + (Get-OpenCodeSuperpowersVersion))
$env:NPM_LOG = $NpmLog
Write-Output ('opencode-refresh=' + (Invoke-OpenCodeSuperpowersRefresh))
Write-Output ('opencode-version-after=' + (Get-OpenCodeSuperpowersVersion))
Write-Output ('playwright=' + (Test-PlaywrightChromiumInstalled))
Remove-Item -Recurse -Force (Join-Path $UserDir '.cache/ms-playwright')
Write-Output ('playwright-absent=' + (Test-PlaywrightChromiumInstalled))
$env:CLAUDE_PLUGINS_JSON = '[{"id":"superpowers@superpowers-marketplace","version":"7.0.0","scope":"user"},{"id":"superpowers@superpowers-marketplace","version":"6.2.0","scope":"project","projectPath":"/p/takumi"}]'
$installs = @(Get-ClaudeSuperpowersInstall -UserHome $UserDir)
Write-Output ('claude-installs=' + (($installs | ForEach-Object { "$($_.Version):$($_.Scope):$($_.ProjectPath)" }) -join ';'))
# with installed_plugins.json present the file answers (the CLI stub still says 7.0.0/6.2.0)
$spDir = Join-Path (Join-Path $UserDir '.claude') 'plugins'
New-Item -ItemType Directory -Force -Path $spDir | Out-Null
Set-Content -LiteralPath (Join-Path $spDir 'installed_plugins.json') -Value '{"version": 2, "plugins": {"superpowers@superpowers-marketplace": [{"scope": "user", "version": "6.4.2"}]}}'
$installs = @(Get-ClaudeSuperpowersInstall -UserHome $UserDir)
Write-Output ('claude-installs-file=' + (($installs | ForEach-Object { "$($_.Version):$($_.Scope):$($_.ProjectPath)" }) -join ';'))
Write-Output ('claude-user-file=' + (Get-ClaudeSuperpowersUserVersion -UserHome $UserDir))
Remove-Item -Recurse -Force (Join-Path $UserDir '.claude')
# A lookup that fails (claude missing, a non-zero exit, bad JSON) must come back as $null, not as
# an empty-but-successful array - the caller reads $null as "re-run dot upgrade", not "not
# installed" (2026-10-11: this Windows twin of claude_superpowers_installs did not yet).
$env:CLAUDE_PLUGIN_LIST_FAIL = '1'
$failedLookup = Get-ClaudeSuperpowersInstall -UserHome $UserDir
Write-Output ('claude-lookup-failed=' + ($null -eq $failedLookup))
Remove-Item Env:\CLAUDE_PLUGIN_LIST_FAIL
# A `claude plugin list --json` that hangs (2026-10-11 Bash incident the Windows twin shares:
# claude_superpowers_installs in agent-skills.sh carries a 60 s net_timeout_tty for exactly
# this) must not block `dot upgrade` forever - -TimeoutSeconds lets the test prove the bound
# fires without actually waiting out the real 60 s default.
$env:CLAUDE_PLUGIN_LIST_HANG = '1'
$hangStart = Get-Date
$hungLookup = Get-ClaudeSuperpowersInstall -TimeoutSeconds 2 -UserHome $UserDir
$hangElapsed = ((Get-Date) - $hangStart).TotalSeconds
Remove-Item Env:\CLAUDE_PLUGIN_LIST_HANG
Write-Output ('claude-lookup-hung=' + ($null -eq $hungLookup))
Write-Output ('claude-lookup-hung-fast=' + ($hangElapsed -lt 10))
Write-Output ('line-behind=' + (Format-SuperpowersVersionLine -Harness 'Codex' -Version '6.4.2' -Upstream '7.0.0' -Note 'the catalog offers 6.4.2'))
Write-Output ('line-current=' + (Format-SuperpowersVersionLine -Harness 'OpenCode' -Version '7.0.0' -Upstream '7.0.0' -Note 'n'))
Write-Output ('line-missing=' + (Format-SuperpowersVersionLine -Harness 'Antigravity' -Version '' -Upstream '7.0.0'))
Write-Output ('line-offline=' + (Format-SuperpowersVersionLine -Harness 'Codex' -Version '6.4.2' -Upstream ''))
Write-Output ('refresh-current=' + (Format-SuperpowersRefreshLine -Harness 'Antigravity' -Version '7.0.0' -Upstream '7.0.0' -Behind 'x'))
Write-Output ('refresh-behind=' + (Format-SuperpowersRefreshLine -Harness 'Codex' -Version '6.4.2' -Upstream '7.0.0' -Behind 'the marketplace has not published v7.0.0 yet'))
Write-Output ('refresh-offline=' + (Format-SuperpowersRefreshLine -Harness 'Codex' -Version '6.4.2' -Upstream ''))
Write-Output ('refresh-unknown-empty=' + ([string]::IsNullOrEmpty((Format-SuperpowersRefreshLine -Harness 'Codex' -Version '' -Upstream '7.0.0' -Behind 'x'))))
PSEOF
    : >"$tmp/npm-ps.log"
    ps_out="$(PATH="$bin:$PATH" GIT_TAGS_DIR="$(winpath "$tags")" pwsh -NoProfile -File "$(winpath "$tmp/ps-harness.ps1")" -Lib "$(winpath "$ps_lib")" -UserDir "$(winpath "$home")" -CacheDir "$(winpath "$oc_dir")" -NpmLog "$(winpath "$tmp/npm-ps.log")" 2>&1 | tr -d '\r' || true)"
    pexpect() { printf '%s\n' "$ps_out" | grep -Fxq -- "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$ps_out" | tr '\n' '|' | cut -c1-900))"; }
    pexpect 'codex-installed=6.4.2'
    pexpect 'codex-catalog=6.4.2'
    pexpect 'codex-absent-empty=True'
    pexpect 'codex-absent-catalog=6.4.2'
    pexpect 'agy-installed=True'
    pexpect 'agy-absent=False'
    pexpect 'antigravity-version=7.0.0'
    pexpect 'latest=7.0.0'
    pexpect 'latest-lychee=0.24.2'
    pexpect 'latest-none='
    pexpect "opencode-dir=$(winpath "$oc_dir")"
    pexpect 'opencode-version=6.3.0'
    pexpect 'opencode-refresh=True'
    pexpect 'opencode-version-after=7.0.0'
    grep -Fq "install --prefix $(winpath "$oc_dir") superpowers@github:obra/superpowers" "$tmp/npm-ps.log" ||
        fail "PowerShell: Invoke-OpenCodeSuperpowersRefresh must refresh inside OpenCode's cache directory; npm saw: $(cat "$tmp/npm-ps.log")"
    pexpect 'playwright=True'
    pexpect 'playwright-absent=False'
    pexpect 'claude-installs=7.0.0:user:;6.2.0:project:/p/takumi'
    pexpect 'claude-installs-file=6.4.2:user:'
    pexpect 'claude-user-file=6.4.2'
    pexpect 'claude-lookup-failed=True'
    pexpect 'claude-lookup-hung=True'
    pexpect 'claude-lookup-hung-fast=True'
    pexpect 'line-behind=   Codex: 6.4.2 - behind upstream v7.0.0 (the catalog offers 6.4.2)'
    pexpect 'line-current=   OpenCode: 7.0.0 (current)'
    pexpect 'line-missing=   Antigravity: not installed'
    pexpect 'line-offline=   Codex: 6.4.2 (upstream unreachable)'
    pexpect 'refresh-current=  Superpowers (Antigravity) is current (7.0.0)'
    pexpect 'refresh-behind=  Superpowers (Codex) is 6.4.2 - the marketplace has not published v7.0.0 yet'
    pexpect 'refresh-offline=  Superpowers (Codex) is 6.4.2 (upstream unreachable)'
    pexpect 'refresh-unknown-empty=True'
    pass
else
    printf 'SKIP (PowerShell twins): pwsh not installed\n'
fi

finish
