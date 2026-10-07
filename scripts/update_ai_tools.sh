#!/bin/bash
# update_ai_tools.sh - refresh the AI coding tools and curated skills, no
# package-manager sweep. Upgrades the AI CLIs (Claude Code, Codex, OpenCode,
# agy, Serena, Graft, act) and re-runs the curated-skill install, honoring
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
npm_global_current() {
    local pkg="$1" have want
    command -v jq &>/dev/null || return 1
    have="$(npm ls -g "$pkg" --depth=0 --json 2>/dev/null | jq -b -r --arg p "$pkg" '.dependencies[$p].version // empty' 2>/dev/null)" || have=""
    want="$(npm view "$pkg" version 2>/dev/null | tr -d '[:space:]')" || want=""
    [ -n "$have" ] && [ "$have" = "$want" ] && CURRENT_NPM_VERSION="$have"
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
            if npm_global_current "$CODEX_PKG"; then
                echo "   codex is current ($CURRENT_NPM_VERSION)"
            else
                $npm_sudo npm install -g "${CODEX_PKG}@latest" --loglevel=error --no-progress || echo "   Codex upgrade failed - continuing"
            fi
        fi
    fi
    # The package catalog's npm globals (field `npm`: markdownlint-cli2), read at runtime
    # like the codex name. Updated only when installed and behind; `dot up` installs them.
    for npm_tool in $(chezmoi execute-template '{{ range .catalog.packages }}{{ if hasKey . "npm" }}{{ .npm }} {{ end }}{{ end }}' 2>/dev/null || true); do
        npm ls -g --depth=0 "$npm_tool" >/dev/null 2>&1 || continue
        if npm_global_current "$npm_tool"; then
            echo "   $npm_tool is current ($CURRENT_NPM_VERSION)"
        else
            $npm_sudo npm install -g "${npm_tool}@latest" --loglevel=error --no-progress || echo "   $npm_tool upgrade failed - continuing"
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

# Superpowers for Codex CLI: the official Codex plugin marketplace
# (`openai-curated-remote`, pre-configured in codex) carries it, and
# `codex plugin add` both installs and updates (same command, idempotent -
# like `agy plugin install` above). Defer-aware: the plugin dir is resolved
# by live codex sessions, same premise as the npm upgrade above.
if command -v codex &>/dev/null; then
    if deferred codex; then
        echo "  codex deferred - Superpowers (Codex) update skipped with it."
    else
        echo "✨ Updating Superpowers (Codex)..."
        net_timeout 300 codex plugin add superpowers@openai-curated-remote &>/dev/null \
            || echo "   Superpowers not installed for Codex - skipping"
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
    # run with every agent and harness closed (graft, codex and the others cannot be
    # replaced while a session runs, and Claude Code should not be replaced under one
    # either), and with nothing running the installer is the simple, predictable path.
    # Same installer URL as the installer template. Fetch-then-run, never piped: a piped
    # `curl | bash` exits 0 on a failed fetch (empty stdin) and would both skip the update
    # silently and - unguarded - abort this set -e script before
    # Playwright/agent-browser/Serena/Graft update (#114; this script promises
    # warn-and-continue).
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

    # Superpowers skills plugin
    echo "✨ Updating Superpowers (Claude Code)..."
    claude plugin update superpowers -y &>/dev/null || echo "   Superpowers not installed for Claude Code - skipping"
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
    npx --yes playwright install chromium &>/dev/null || echo "   Playwright Chromium update failed - skipping"
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
        $npm_sudo "$NPM_BIN" install -g --allow-scripts=agent-browser agent-browser --loglevel=error --no-progress || echo "   agent-browser install failed - skipping"
    fi
    AGENT_BROWSER_BIN="$("$NPM_BIN" prefix -g)/bin/agent-browser"
    if [[ -x "$AGENT_BROWSER_BIN" ]]; then
        "$AGENT_BROWSER_BIN" install &>/dev/null || echo "   agent-browser browser setup failed - skipping"
        "$AGENT_BROWSER_BIN" doctor --json &>/dev/null || echo "   agent-browser verification failed - continuing"
    fi
fi

dot_timing_mark 'Serena and Graft'
# 6. Serena (uv-managed) + Graft (self-upgrading via `graft upgrade`).
# Both are defer-aware: uv/graft recreate package dirs that live sessions
# resolve from (2026-09-20 live incidents).
if command -v serena &>/dev/null; then
    if deferred serena; then
        echo "  serena deferred - a serena process is live (dot upgrade reports it)."
    else
        uv tool upgrade serena-agent 2>/dev/null || echo "  Warning: serena upgrade failed - continuing"
    fi
fi
if command -v graft &>/dev/null; then
    if deferred graft; then
        echo "  graft deferred - agent session(s) are live; graft's dir is resolved by every hook event (dot upgrade reports it)."
    else
        # `graft upgrade` runs `npm install -g` against npm's DEFAULT prefix.
        # A graft living under another prefix (a stale ~/.local install,
        # nvm) then fails EACCES on the system /usr prefix and was never
        # upgraded (WSL: 0.18.0 stuck while 0.21.1 shipped). Point npm at the
        # prefix graft actually lives in.
        graft_real="$(readlink -f "$(command -v graft)" 2>/dev/null || true)"
        graft_prefix=""
        case "$graft_real" in
            */lib/node_modules/@nanonets/graft/*) graft_prefix="${graft_real%/lib/node_modules/@nanonets/graft/*}" ;;
        esac
        # `graft upgrade` reinstalls even when nothing changed (0.21.1 -> 0.21.1 took 41 s on
        # WSL). `graft version` prints the installed version and the latest published one;
        # equal means nothing to do. "unreachable" or no answer still upgrades.
        graft_version_out="$(graft version 2>/dev/null || true)"
        graft_have="$(printf '%s\n' "$graft_version_out" | sed -n 's/^graft \([0-9][^ ]*\).*/\1/p' | head -n 1)"
        # Online: "latest on npm: 0.21.1 <check> up to date"; offline: "latest: unreachable (offline?)".
        graft_latest="$(printf '%s\n' "$graft_version_out" | sed -n 's/^latest\( on npm\)\{0,1\}: \([0-9][^ ]*\).*/\2/p' | head -n 1)"
        if [ -n "$graft_have" ] && [ "$graft_have" = "$graft_latest" ]; then
            echo "  graft is current ($graft_have)"
        elif [ -n "$graft_prefix" ] && [ ! -w "$graft_prefix/lib/node_modules" ]; then
            echo "  Warning: graft is in $graft_prefix (not writable) - reinstall with: sudo npm install -g @nanonets/graft@latest"
        else
            # npm 12 skips install scripts unless allow-listed, so a bare
            # `graft upgrade` replaces graft with a build that crashes at
            # startup ("No native build was found", tree-sitter parsers never
            # compiled - seen on WSL 2026-10-02). Hand the installer's own
            # allow-list to npm as NPM_CONFIG_ALLOW_SCRIPTS, read from the
            # catalog like the codex package name (no literal copy here).
            graft_allow="$(chezmoi execute-template '{{ join "," .agents.npm.graft_allow_scripts }}' 2>/dev/null || true)"
            if [ -z "$graft_allow" ]; then
                echo "  Warning: graft allow-scripts list unavailable from chezmoi data - skipping graft upgrade"
            else
                NPM_CONFIG_ALLOW_SCRIPTS="$graft_allow" NPM_CONFIG_PREFIX="${graft_prefix:-$(npm prefix -g 2>/dev/null)}" \
                    graft upgrade 2>/dev/null || echo "  Warning: graft upgrade failed - continuing"
                # A graft that cannot start breaks every agent hook: say so now.
                graft --version >/dev/null 2>&1 ||
                    echo "  Warning: graft does not start after the upgrade - reinstall: NPM_CONFIG_ALLOW_SCRIPTS='$graft_allow' npm install -g @nanonets/graft@latest"
            fi
        fi
    fi
fi
# No Codex hook-path normalization here, unlike the .ps1 twin: graft writes
# this OS's native separator, so on Linux/macOS ~/.codex/hooks.json already
# carries forward slashes. The backslash bug (dotfiles #170) is Windows-only
# - git bash, which the Codex TUI spawns there, eats backslashes - and the
# Windows twin normalizes it after every graft upgrade.

dot_timing_summary 'AI tools'
echo "✅ AI Tools Update Complete!"
