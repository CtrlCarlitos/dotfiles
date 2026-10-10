#!/bin/bash
# update_ai_tools.sh - refresh the AI coding tools and curated skills, no
# package-manager sweep. Upgrades the AI CLIs (Claude Code, Codex, OpenCode,
# agy, Serena, act) and re-runs the curated-skill install, honoring
# DOTUPGRADE_DEFER. Entry points: `dot upgrade` (which exports the defer
# list) or direct: bash scripts/update_ai_tools.sh
set -e

# Shared helpers + the curated-skills lifecycle (issue #123): logging,
# net_timeout (the updater previously had none - the 2026-08-30 hang class),
# sha256_cmd, fetch_and_verify, skills_add_all, verify_curated_skill_targets.
. "${BASH_SOURCE[0]%/*}/lib/agent-skills.sh"
# The [data.packages] scanner + the 16-group taxonomy (issue #123).
. "${BASH_SOURCE[0]%/*}/lib/chezmoi-config.sh"
# Where the time goes: marks at each section, a summary at the end.
. "${BASH_SOURCE[0]%/*}/lib/timing.sh"

echo "🤖 Updating AI Coding Tools..."

# Defer protocol: scripts/dotupgrade.sh (the ONLY entry point - `dot
# upgrade`) exports DOTUPGRADE_DEFER with the tools whose package dirs
# cannot be recreated while live agent sessions resolve from them.
deferred() { case ",${DOTUPGRADE_DEFER:-}," in *,"$1",*) return 0 ;; *) return 1 ;; esac; }

# npm_global_current <pkg>: 0 when the globally installed <pkg> is already the registry's
# latest, so the reinstall (9 s for codex on WSL) can be skipped. Unknown - no jq, not
# installed, registry unreachable - returns 1 and the caller installs as before.
CURRENT_NPM_VERSION=""
LATEST_NPM_VERSION=""
npm_global_current() {
    local pkg="$1" have want
    command -v jq &>/dev/null || return 1
    have="$(npm ls -g "$pkg" --depth=0 --json 2>/dev/null | jq -b -r --arg p "$pkg" '.dependencies[$p].version // empty' 2>/dev/null)" || have=""
    want="$(npm view "$pkg" version 2>/dev/null | tr -d '[:space:]')" || want=""
    LATEST_NPM_VERSION="$want"
    [ -n "$have" ] && [ "$have" = "$want" ] && CURRENT_NPM_VERSION="$have"
}

# npm_global_upgrade <name> <version|""> <npm install -g args...> - the upgrade, quiet on
# success. npm's own summary ("changed 2 packages in 20s", printed even at --loglevel=error)
# says nothing useful; the version is the news. npm's output is shown only on failure.
npm_global_upgrade() {
    local name="$1" ver="$2" out; shift 2
    out="$($npm_sudo npm install -g "$@" --loglevel=error --no-progress 2>&1)" \
        || { printf '%s\n' "$out" >&2; return 1; }
    echo "   $name upgraded to ${ver:-latest}"
}

# Codex ships its native binary as an optional dependency per platform
# (<pkg>-linux-x64 -> npm:<pkg>@<version>-linux-x64), published minutes AFTER
# the main package. npm skips a missing optional dependency silently: a `dot upgrade` in that
# gap removed the old binary, installed none, and every codex command died with "Missing
# optional dependency <pkg>-linux-x64" (2026-10-07: 0.161.0 at 16:04, its Linux
# binary at 16:16) - while the version check went on saying "codex is current".
npm_platform_tag() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) echo linux-x64 ;;
        Linux-aarch64 | Linux-arm64) echo linux-arm64 ;;
        Darwin-x86_64) echo darwin-x64 ;;
        Darwin-arm64) echo darwin-arm64 ;;
    esac
}
# npm_platform_published <pkg> <version>: 1 only when <pkg>@<version> names a binary package
# for this platform that the registry does not have yet. Unknown (no jq, no such dependency,
# registry unreachable for the first query) counts as published - the install goes ahead.
npm_platform_published() {
    local pkg="$1" ver="$2" tag spec
    tag="$(npm_platform_tag)"
    [ -n "$tag" ] && command -v jq &>/dev/null || return 0
    spec="$(npm view "$pkg@$ver" optionalDependencies --json 2>/dev/null | jq -b -r --arg k "$pkg-$tag" '.[$k] // empty' 2>/dev/null)" || spec=""
    [ -n "$spec" ] || return 0
    case "$spec" in
        npm:*) spec="${spec#npm:}" ;;
        *) spec="$pkg-$tag@$spec" ;;
    esac
    [ -n "$(npm view "$spec" version 2>/dev/null)" ]
}
codex_works() { command -v codex &>/dev/null && codex --version &>/dev/null; }
# upgrade_codex_npm <pkg>: current AND runnable -> nothing; the latest's binary for this
# platform not published yet -> keep what is installed; otherwise install, then make sure it
# starts.
upgrade_codex_npm() {
    local pkg="$1" want
    if codex_works && npm_global_current "$pkg"; then
        echo "   codex is current ($CURRENT_NPM_VERSION)"
        return 0
    fi
    want="$(npm view "$pkg" version 2>/dev/null | tr -d '[:space:]')" || want=""
    if [ -n "$want" ] && ! npm_platform_published "$pkg" "$want"; then
        if codex_works; then
            echo "   codex $want is out, but its $(npm_platform_tag) binary is not published yet - keeping the installed one (the next dot upgrade takes it)"
        else
            echo "   codex cannot start (its platform binary is missing) and $want's $(npm_platform_tag) binary is not published yet - re-run dot upgrade in a few minutes"
        fi
        return 0
    fi
    npm_global_upgrade codex "$want" "${pkg}@latest" || { echo "   Codex upgrade failed - continuing"; return 0; }
    codex_works || echo "   codex was installed but cannot start (npm skipped its platform binary) - re-run dot upgrade in a few minutes"
    return 0
}

# The npm sudo decision, once for every global npm step below. Same rule the
# installer template makes (#114): sudo only for the system-owned /usr prefix -
# a user-managed npm (nvm, homebrew) must never be sudo'd. The agent-browser
# step used to skip it and failed EACCES on apt-Node (WSL, 2026-10-02), hidden
# by its 2>/dev/null.
npm_sudo=""
if command -v npm &>/dev/null; then
    npm_bin="$(command -v npm)"
    npm_sudo="sudo"
    if [[ "$npm_bin" != /usr* ]]; then
        echo "   user-managed npm at $npm_bin - dropping sudo"
        npm_sudo=""
    fi
fi

dot_timing_mark 'NPM packages'
# 1. NPM Packages (Codex)
# Note: OpenCode is native on Linux/Mac, so it's not included here
if command -v npm &>/dev/null; then
    if deferred codex; then
        echo "  codex deferred - a codex session is live (dot upgrade reports it)."
    else
        echo "📦 Updating NPM packages..."
        # Package name from .chezmoidata/agents.yaml, read at runtime like the
        # guardrail pin (chezmoi is a hard prerequisite: this script runs via
        # `chezmoi source-path`). No literal fallback - that would be a copy.
        CODEX_PKG="$(chezmoi execute-template '{{ .agents.npm.codex }}' 2>/dev/null || true)"
        if [ -z "$CODEX_PKG" ]; then
            echo "   codex package name unavailable from chezmoi data - skipping"
        else
            upgrade_codex_npm "$CODEX_PKG"
        fi
    fi
    # The package catalog's npm globals (field `npm`: markdownlint-cli2), read at runtime
    # like the codex name. Updated only when installed and behind; `dot up` installs them.
    for npm_tool in $(chezmoi execute-template '{{ range .catalog.packages }}{{ if hasKey . "npm" }}{{ .npm }} {{ end }}{{ end }}' 2>/dev/null || true); do
        npm ls -g --depth=0 "$npm_tool" >/dev/null 2>&1 || continue
        if npm_global_current "$npm_tool"; then
            echo "   $npm_tool is current ($CURRENT_NPM_VERSION)"
        else
            npm_global_upgrade "$npm_tool" "$LATEST_NPM_VERSION" "${npm_tool}@latest" || echo "   $npm_tool upgrade failed - continuing"
        fi
    done
else
    echo "⚠️  npm not found. Skipping npm packages."
fi

dot_timing_mark 'Superpowers (Antigravity)'
# 1a. Superpowers plugin for Antigravity CLI (agy). agy self-updates (checksum
# verify each run), so this just refreshes the plugin - re-running `agy plugin
# install` is the same idempotent pattern used for Claude Code/OpenCode below.
if command -v agy &>/dev/null; then
    echo "✨ Updating Superpowers (Antigravity)..."
    agy plugin install https://github.com/obra/superpowers &>/dev/null || echo "   Superpowers plugin update for Antigravity failed - skipping"
fi

dot_timing_mark 'curated skills'
# 1b. Curated third-party skills via the `skills` CLI (vercel-labs/skills).
# Re-running the same `skills add` re-fetches latest (--copy overwrites). The
# add batch and the target-verification pass are shared verbatim with
# install_agent_skills() in run_onchange_install_packages.sh.tmpl via
# scripts/lib/agent-skills.sh (issue #123) - the "keep this list in sync"
# comment this block used to carry is obsolete: there is one copy now. The
# per-consumer glue below is only what differs: the catalog sits next to this
# script, the agent list renders from .chezmoidata/agents.yaml at runtime
# (chezmoi is a hard prerequisite: this script runs via `chezmoi
# source-path`), and the no-npx fallback derives its skipped count from the
# catalog - never a literal, which drifted every time the catalog gained a
# skill. Pure builtins in the fallback: the count must also resolve where
# chezmoi/grep are absent.
catalog="${BASH_SOURCE[0]%/*}/curated-agent-skills.txt"
curated_total=0
if [[ -r "$catalog" ]]; then
    while IFS= read -r skill || [[ -n "$skill" ]]; do
        [[ -z "$skill" || "$skill" == \#* ]] || ((curated_total += 1))
    done < "$catalog"
fi
if command -v npx &>/dev/null; then
    echo "✨ Updating curated agent skills (Matt Pocock + Anthropic + Vercel Labs)..."
    # The CLI refreshes $HOME/.claude/skills and $HOME/.agents/skills. OpenCode
    # and Codex discover the shared directory; this is the explicit refresh path.
    # From .chezmoidata/agents.yaml, read at runtime (see CODEX_PKG above).
    read -r -a AGENTS <<<"$(chezmoi execute-template '{{ join " " .agents.skills.agents }}' 2>/dev/null || true)"
    [ "${#AGENTS[@]}" -gt 0 ] || echo "   skills agent list unavailable from chezmoi data - skill updates may fail"
    claude_installed=0; claude_skipped=0; claude_failed=0
    opencode_installed=0; opencode_skipped=0; opencode_failed=0
    codex_installed=0; codex_skipped=0; codex_failed=0
    antigravity_installed=0; antigravity_skipped=0; antigravity_failed=0
    record_cli_result() {
        local status="$1" count="$2"
        for agent in "${AGENTS[@]}"; do
            case "$status:$agent" in
                installed:claude-code) ((claude_installed += count)) ;;
                installed:opencode) ((opencode_installed += count)) ;;
                installed:codex) ((codex_installed += count)) ;;
                skipped:claude-code) ((claude_skipped += count)) ;;
                skipped:opencode) ((opencode_skipped += count)) ;;
                skipped:codex) ((codex_skipped += count)) ;;
                failed:claude-code) ((claude_failed += count)) ;;
                failed:opencode) ((opencode_failed += count)) ;;
                failed:codex) ((codex_failed += count)) ;;
            esac
        done
    }
    # Skills dropped upstream are removed first (retired-agent-skills.txt, next to the catalog).
    skills_remove_retired "${catalog%/*}/retired-agent-skills.txt"
    skills_add_all
    if [[ ! -r "$catalog" ]]; then
        echo "   Warning: curated skill catalog is not readable: $catalog"
    else
        claude_reported="$claude_installed"; opencode_reported="$opencode_installed"; codex_reported="$codex_installed"
        claude_installed=0; opencode_installed=0; codex_installed=0
        verify_curated_skill_targets "$claude_reported" "$opencode_reported" "$codex_reported"
    fi
    echo "   Curated skills: Claude Code installed=$claude_installed skipped=$claude_skipped failed=$claude_failed"
    echo "   Curated skills: OpenCode installed=$opencode_installed skipped=$opencode_skipped failed=$opencode_failed"
    echo "   Curated skills: Antigravity installed=$antigravity_installed skipped=$antigravity_skipped failed=$antigravity_failed"
    echo "   Curated skills: Codex installed=$codex_installed skipped=$codex_skipped failed=$codex_failed"
else
    echo "   Curated skills: Claude Code installed=0 skipped=$curated_total failed=0"
    echo "   Curated skills: OpenCode installed=0 skipped=$curated_total failed=0"
    echo "   Curated skills: Antigravity installed=0 skipped=$curated_total failed=0"
    echo "   Curated skills: Codex installed=0 skipped=$curated_total failed=0"
fi

# Superpowers for Codex CLI: the pre-configured Codex plugin marketplace
# carries it, and `codex plugin add` both installs and updates (same command,
# idempotent - like `agy plugin install` above). Defer-aware: the plugin dir is
# resolved by live codex sessions, same premise as the npm upgrade above.
#
# The marketplace name comes from codex itself (see
# codex_superpowers_marketplace in scripts/lib/agent-skills.sh for why
# hardcoding it was wrong). The old line also MISREPORTED its failure: it sent
# the error to /dev/null and printed "Superpowers not installed for Codex",
# which was false - the plugin was installed, the add was failing on a
# nonexistent marketplace. A real failure now prints what codex said.
if command -v codex &>/dev/null; then
    if deferred codex; then
        echo "  codex deferred - Superpowers (Codex) update skipped with it."
    else
        echo "✨ Updating Superpowers (Codex)..."
        cx_market="$(codex_superpowers_marketplace)"
        if [ -z "$cx_market" ]; then
            echo "   no Codex marketplace lists a superpowers plugin - skipping"
        else
            cx_out="$(net_timeout 300 codex plugin add "superpowers@$cx_market" 2>&1)" \
                || { printf '%s\n' "$cx_out"; echo "   Superpowers update for Codex failed - skipping"; }
        fi
    fi
fi

dot_timing_mark 'guardrail'
# guardrail-section: begin
# 1c. Agent guardrails: single opt-in desired-state flag read from
#     ~/.config/chezmoi/chezmoi.toml [data.packages] guardrail (default false,
#     same semantics as the installer template). Installation itself lives in
#     agent-guardrails (its install.sh, ADR-0029 there) - binary download,
#     checksum, self-update of an older binary, and `guardrail setup` (plane
#     wiring, coverage). This script only fetches the pinned release's
#     install.sh + SHA256SUMS, verifies the installer against SHA256SUMS, and
#     runs it from the downloaded file (never piped):
#       true  = install.sh --version <pin> --state enabled
#       false = install.sh --version <pin> --state disabled, only when a
#               binary is already installed (never a download just to
#               disable; nothing is removed).
#     `guardrail setup` prints a WebAuthn approval URL and blocks until the
#     operator responds, so the installer's output streams through
#     untouched. Unlike the auto-run installer template (which fails the
#     whole reconciliation on a bad install), a non-zero installer exit here
#     is a WARNING, not fatal - this script keeps going to the remaining
#     tools below, matching how every other step in this file degrades.
#     Pin: single source of truth is .chezmoidata.yaml guardrail.version
#     (the installer templates render the same key) - read at runtime via
#     `chezmoi execute-template`, which this script can rely on because it is
#     itself invoked through `chezmoi source-path`.
GUARDRAIL_VERSION="$(chezmoi execute-template '{{ .guardrail.version }}' 2>/dev/null || true)"
GUARDRAIL_REPO="CtrlCarlitos/agent-guardrails"
guardrail_dest="$HOME/.local/bin/guardrail"
guardrail_enabled=false
if [ -f "$HOME/.config/chezmoi/chezmoi.toml" ]; then
    # [data.packages] section scanner shared via scripts/lib/chezmoi-config.sh
    # (issue #123); the literal section name above keeps the shape greppable.
    guardrail_enabled="$(pkg_config_flag_true "$HOME/.config/chezmoi/chezmoi.toml" guardrail || true)"
fi
guardrail_state=""
if [ "$guardrail_enabled" = "true" ]; then
    guardrail_state="enabled"
elif [ -x "$guardrail_dest" ]; then
    guardrail_state="disabled"
fi
if [ -n "$guardrail_state" ] && [ -z "$GUARDRAIL_VERSION" ]; then
    echo "  guardrail: pin unavailable from chezmoi data - skipping guardrail steps"
elif [ -z "$guardrail_state" ]; then
    echo "  guardrail disabled in config - nothing to do"
else
    gbase="https://github.com/${GUARDRAIL_REPO}/releases/download/${GUARDRAIL_VERSION}"
    gtmp="$(mktemp -d)"
    # Fetch + verify via the shared lib helper (issue #123): download to temp
    # (net_timeout-guarded - the updater previously had no wall-clock guard
    # here at all) and checksum-verify against the release's SHA256SUMS.
    if ! fetch_and_verify guardrail "$gbase/install.sh" "$gbase/SHA256SUMS" install.sh "$gtmp"; then
        rm -rf "$gtmp"
    else
        echo "  Running agent-guardrails installer ${GUARDRAIL_VERSION} (--state ${guardrail_state}); approval URL prints here if WebAuthn is required..."
        guardrail_code=0
        # Full output to the apply log (same file the installer uses); the console gets the filtered
        # view. The exit status goes through a file so it never depends on pipefail.
        glog="$HOME/.local/state/guardrail/apply.log"
        mkdir -p "$(dirname "$glog")"
        { sh "$gtmp/install.sh" --version "$GUARDRAIL_VERSION" --state "$guardrail_state" 2>&1 || echo "$?" >"$gtmp/exit"; } |
            tee -a "$glog" | guardrail_console_filter
        if [ -f "$gtmp/exit" ]; then guardrail_code="$(cat "$gtmp/exit")"; fi
        rm -rf "$gtmp"
        if [ "$guardrail_code" -ne 0 ]; then
            echo "  guardrail installer exited with code $guardrail_code - continuing"
        fi
    fi
fi
# guardrail-section: end

dot_timing_mark 'Claude Code'
# 2. Claude Code (Native)
if command -v claude &>/dev/null; then
    echo "🧠 Updating Claude Code..."
    # Deliberately NOT `claude update` (same as the Windows twin): dot upgrade is meant to
    # run with every agent and harness closed (codex and the others cannot be
    # replaced while a session runs, and Claude Code should not be replaced under one
    # either), and with nothing running the installer is the simple, predictable path.
    # Same installer URL as the installer template. Fetch-then-run, never piped: a piped
    # `curl | bash` exits 0 on a failed fetch (empty stdin) and would both skip the update
    # silently and - unguarded - abort this set -e script before
    # Playwright/agent-browser/Serena update (#114; this script promises
    # warn-and-continue).
    # Already the latest? The installer took ~20 s on every run to change nothing. Its npm
    # package carries the same version numbers; an unknown answer re-runs it as before.
    cl_pkg="$(chezmoi execute-template '{{ .agents.npm.claude_code_version }}' 2>/dev/null || true)"
    cl_have="$(claude --version 2>/dev/null | awk 'NR==1 {print $1}')"
    cl_want=""
    [ -n "$cl_pkg" ] && cl_want="$(npm view "$cl_pkg" version 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$cl_have" ] && [ "$cl_have" = "$cl_want" ]; then
        echo "   Claude Code is current ($cl_have)"
    else
        cl_inst="$(mktemp)"
        if curl -fsSL -o "$cl_inst" https://claude.ai/install.sh; then
            # The installer prints a banner, a location and a "next steps" block on every run; the
            # version is the only news. Its whole output is shown only when it fails.
            cl_out="$(mktemp)"
            if bash "$cl_inst" >"$cl_out" 2>&1; then
                cl_ver="$(sed -n 's/^[[:space:]]*Version:[[:space:]]*//p' "$cl_out")"
                echo "   Claude Code ${cl_ver:-installed} (installer re-run)"
            else
                cat "$cl_out"
                echo "   Claude Code installer failed - continuing"
            fi
            rm -f "$cl_out"
        else
            echo "   Claude Code installer download failed - continuing"
        fi
        rm -f "$cl_inst"
    fi

    # Superpowers skills plugin
    echo "✨ Updating Superpowers (Claude Code)..."
    # Named with its marketplace: a machine can carry superpowers from several marketplaces, and
    # the bare name then fails with "installed from more than one marketplace" (silently, here).
    claude plugin update superpowers@superpowers-marketplace -y &>/dev/null || echo "   Superpowers update for Claude Code failed - skipping"
fi

dot_timing_mark 'OpenCode'
# 3. OpenCode (Native)
if command -v opencode &>/dev/null; then
    if deferred opencode; then
        echo "  opencode deferred - an opencode session is live (upgrading it races the running binary)."
    else
        echo "💻 Updating OpenCode..."
        # Fetch-then-run with the same guard shape as the Claude installer
        # above (#114).
        oc_inst="$(mktemp)"
        if curl -fsSL -o "$oc_inst" https://opencode.ai/install; then
            # The installer prints a progress bar, an ASCII logo and a "to start" block; the
            # version is the only news. Its whole output is shown only when it fails.
            oc_out="$(mktemp)"
            if bash "$oc_inst" >"$oc_out" 2>&1; then
                oc_ver="$(opencode --version 2>/dev/null | head -n 1)" || oc_ver=""
                if grep -q 'already installed' "$oc_out"; then
                    echo "   OpenCode is current (${oc_ver:-installed})"
                else
                    echo "   OpenCode ${oc_ver:-updated} (installer re-run)"
                fi
            else
                cat "$oc_out"
                echo "   OpenCode installer failed - continuing"
            fi
            rm -f "$oc_out"
        else
            echo "   OpenCode installer download failed - continuing"
        fi
        rm -f "$oc_inst"
    fi
    # A legacy npm-global opencode-ai shim (dead binary - postinstall never
    # ran) can shadow the native binary this installer just refreshed; remove
    # it if present. Harmless when npm or the package is absent.
    npm rm -g opencode-ai &>/dev/null || true

    # Superpowers skills - not a `claude plugin`, it's a git-backed npm
    # package under OpenCode's own config dir; re-running the install pulls
    # the latest commit since no version/tag is pinned.
    echo "✨ Updating Superpowers (OpenCode)..."
    # --allow-git=all: npm 12+ blocks git-URL dependencies by default (EALLOWGIT)
    npm install "superpowers@git+https://github.com/obra/superpowers.git" --prefix "$HOME/.config/opencode" --allow-git=all --loglevel=error --no-progress --fund=false --audit=false >/dev/null 2>&1 || echo "   Superpowers not installed for OpenCode - skipping"
fi

dot_timing_mark 'Playwright Chromium'
# 4. Playwright Chromium (headless browser for agent automation)
if command -v npx &>/dev/null; then
    echo "🌐 Updating Playwright Chromium..."
    net_timeout 600 npx --yes playwright install chromium &>/dev/null || echo "   Playwright Chromium update failed - skipping"
fi

dot_timing_mark 'agent-browser'
# 5. agent-browser. Playwright runs first so this CLI can reuse its Chromium.
if command -v npm &>/dev/null; then
    NPM_BIN="$(command -v npm)"
    echo "🌐 Updating agent-browser..."
    # Skipped when already the registry's latest (the reinstall always printed "changed 1 package").
    # The browser setup and the verification below still run.
    if npm_global_current agent-browser; then
        echo "   agent-browser is current ($CURRENT_NPM_VERSION)"
    else
        npm_global_upgrade agent-browser "$LATEST_NPM_VERSION" --allow-scripts=agent-browser agent-browser || echo "   agent-browser install failed - skipping"
    fi
    AGENT_BROWSER_BIN="$("$NPM_BIN" prefix -g)/bin/agent-browser"
    if [[ -x "$AGENT_BROWSER_BIN" ]]; then
        net_timeout 600 "$AGENT_BROWSER_BIN" install &>/dev/null || echo "   agent-browser browser setup failed - skipping"
        "$AGENT_BROWSER_BIN" doctor --json &>/dev/null || echo "   agent-browser verification failed - continuing"
    fi
fi

dot_timing_mark 'Serena'
# 6. Serena (uv-managed). Defer-aware: uv recreates the package dir that live
# sessions resolve from (2026-09-20 live incidents).
if command -v serena &>/dev/null; then
    if deferred serena; then
        echo "  serena deferred - a serena process is live (dot upgrade reports it)."
    else
        echo "🧩 Updating Serena..."
        # uv's own news ("Nothing to upgrade" / "Upgraded serena-agent vX -> vY") prints to
        # stderr, not stdout (confirmed live, uv 0.12.24) - discarding it left this step
        # silent on every run, unlike every other tool here. Capture it instead.
        if serena_output=$(uv tool upgrade serena-agent 2>&1); then
            [ -n "$serena_output" ] && printf '%s\n' "$serena_output" | sed 's/^/  serena-agent: /'
        else
            serena_code=$?
            echo "  Warning: serena upgrade failed (exit $serena_code) - continuing"
            [ -n "$serena_output" ] && printf '%s\n' "$serena_output" | sed 's/^/    /'
        fi
    fi
fi

dot_timing_mark 'Graft retirement'
# 7. Graft was dropped from the dotfiles (2026-10-09): remove it where an earlier
# run installed it (graft_retire, scripts/lib/agent-skills.sh; quiet when there
# is nothing to do). Same npm sudo decision as the npm steps above.
graft_retire "$npm_sudo"

dot_timing_summary 'AI tools'
echo "✅ AI Tools Update Complete!"
