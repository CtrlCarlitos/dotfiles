#!/bin/bash
set -e

echo "🤖 Updating AI Coding Tools..."

# 1. NPM Packages (Codex)
# Note: OpenCode is native on Linux/Mac, so it's not included here
if command -v npm &>/dev/null; then
    echo "📦 Updating NPM packages..."
    sudo npm update -g @openai/codex
else
    echo "⚠️  npm not found. Skipping npm packages."
fi

# 1a. Superpowers plugin for Antigravity CLI (agy). agy self-updates (checksum
# verify each run), so this just refreshes the plugin - re-running `agy plugin
# install` is the same idempotent pattern used for Claude Code/OpenCode below.
if command -v agy &>/dev/null; then
    echo "✨ Updating Superpowers (Antigravity)..."
    agy plugin install https://github.com/obra/superpowers &>/dev/null || echo "   Superpowers plugin update for Antigravity failed - skipping"
fi

# 1b. Curated third-party skills via the `skills` CLI (vercel-labs/skills).
# Re-running the same `skills add` re-fetches latest (--copy overwrites). Keep
# this list in sync with install_agent_skills() in
# run_onchange_install_packages.sh.tmpl. --loglevel=error kills npm 12's benign
# per-run "npm notice run ..." stderr hint; </dev/null keeps any prompt from
# ever holding the terminal (see installer for full notes).
if command -v npx &>/dev/null; then
    echo "✨ Updating curated agent skills (Matt Pocock + Anthropic + Vercel Labs)..."
    catalog="$(chezmoi source-path)/scripts/curated-agent-skills.txt"
    SK=(npx --yes --loglevel=error skills@latest)
    # The CLI refreshes $HOME/.claude/skills and $HOME/.agents/skills. OpenCode
    # and Codex discover the shared directory; this is the explicit refresh path.
    AGENTS=(claude-code opencode codex)
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
    if "${SK[@]}" add mattpocock/skills \
        -s codebase-design domain-modeling grill-with-docs improve-codebase-architecture \
           prototype research grilling handoff teach writing-for-agents \
           resolving-merge-conflicts \
        -a "${AGENTS[@]}" -g -y --copy < /dev/null &>/dev/null; then
        record_cli_result installed 11
    else
        record_cli_result failed 11
        echo "   Matt Pocock skills update failed - skipping"
    fi
    sk_tmp="$(mktemp -d)"
    if git clone --quiet --depth 1 https://github.com/mattpocock/skills "$sk_tmp/repo" &>/dev/null; then
        src="$sk_tmp/repo/skills/engineering/code-review"
        [[ -d "$src" ]] || src="$sk_tmp/repo/code-review"
        if [[ -d "$src" ]]; then
            mkdir -p "$sk_tmp/stage/mp-code-review"
            cp -r "$src/." "$sk_tmp/stage/mp-code-review/"
            skf="$sk_tmp/stage/mp-code-review/SKILL.md"
            # guarded: bare `sed && mv` aborts this set -e script if SKILL.md
            # is missing (upstream layout drift) - mirrors the installer
            if [[ -f "$skf" ]]; then
                sed 's/^name:[[:space:]].*/name: mp-code-review/' "$skf" > "$skf.tmp" && mv "$skf.tmp" "$skf"
                if "${SK[@]}" add "$sk_tmp/stage" -s mp-code-review -a "${AGENTS[@]}" -g -y --copy < /dev/null &>/dev/null; then
                    record_cli_result installed 1
                else
                    record_cli_result failed 1
                    echo "   mp-code-review update failed - skipping"
                fi
            else
                record_cli_result skipped 1
                echo "   Warning: SKILL.md missing from staged code-review - upstream layout changed? Skipping mp-code-review."
            fi
        else
            record_cli_result skipped 1
            echo "   Warning: code-review skill dir not found in mattpocock/skills - upstream layout changed?"
        fi
    else
        record_cli_result failed 1
        echo "   Warning: mp-code-review skill source clone failed - continuing"
    fi
    rm -rf "$sk_tmp"
    if "${SK[@]}" add anthropics/skills -s frontend-design -a "${AGENTS[@]}" -g -y --copy < /dev/null &>/dev/null; then
        record_cli_result installed 1
    else
        record_cli_result failed 1
        echo "   frontend-design update failed - skipping"
    fi
    # find-skills (vercel-labs/skills, 3.4M installs) - search/install skills from skills.sh mid-session
    if "${SK[@]}" add vercel-labs/skills -s find-skills -a "${AGENTS[@]}" -g -y --copy < /dev/null &>/dev/null; then
        record_cli_result installed 1
    else
        record_cli_result failed 1
        echo "   find-skills update failed - skipping"
    fi
    # agent-browser (vercel-labs/agent-browser, 843.8K installs) - navigate, click, fill, scrape, screenshot
    if "${SK[@]}" add vercel-labs/agent-browser -s agent-browser -a "${AGENTS[@]}" -g -y --copy < /dev/null &>/dev/null; then
        record_cli_result installed 1
    else
        record_cli_result failed 1
        echo "   agent-browser update failed - skipping"
    fi
    # skill-creator (anthropics/skills, 380K installs) - skill-authoring lifecycle with benchmarks + eval viewer
    if "${SK[@]}" add anthropics/skills -s skill-creator -a "${AGENTS[@]}" -g -y --copy < /dev/null &>/dev/null; then
        record_cli_result installed 1
    else
        record_cli_result failed 1
        echo "   skill-creator update failed - skipping"
    fi
    # (writing-great-skills removed 2026-09-14: mattpocock renamed it upstream to
    #  writing-for-agents, which is already in the batch above — the old name
    #  failed silently on every run.)

    if [[ ! -r "$catalog" ]]; then
        echo "   Warning: curated skill catalog is not readable: $catalog"
    else
        claude_reported="$claude_installed"; opencode_reported="$opencode_installed"; codex_reported="$codex_installed"
        claude_installed=0; opencode_installed=0; codex_installed=0
        while IFS= read -r skill || [[ -n "$skill" ]]; do
            [[ -z "$skill" || "$skill" == \#* ]] && continue

            # Count an agent installed only after its supported discovery
            # target exists; the CLI exit status alone is insufficient.
            if [[ -f "$HOME/.claude/skills/$skill/SKILL.md" ]]; then
                claude_installed=$((claude_installed + 1))
            elif ((claude_reported > 0)); then
                claude_failed=$((claude_failed + 1))
            fi
            if [[ -f "$HOME/.agents/skills/$skill/SKILL.md" ]]; then
                opencode_installed=$((opencode_installed + 1))
                codex_installed=$((codex_installed + 1))
            else
                if ((opencode_reported > 0)); then
                    opencode_failed=$((opencode_failed + 1))
                fi
                if ((codex_reported > 0)); then
                    codex_failed=$((codex_failed + 1))
                fi
            fi

            source="$HOME/.claude/skills/$skill"
            target="$HOME/.gemini/antigravity-cli/skills/$skill"
            if [[ -f "$source/SKILL.md" ]]; then
                antigravity_status=failed
                mkdir -p "$HOME/.gemini/antigravity-cli/skills"
                tmp="$(mktemp -d "$HOME/.gemini/antigravity-cli/skills/.${skill}.tmp.XXXXXX")"
                if cp -R "$source/." "$tmp/"; then
                    backup="$(mktemp -d "$HOME/.gemini/antigravity-cli/skills/.${skill}.backup.XXXXXX")"
                    if ! rmdir "$backup"; then
                        rm -rf "$tmp"
                        echo "   Warning: failed to prepare Antigravity skill backup: $skill"
                    elif [[ -e "$target" || -L "$target" ]]; then
                        if mv "$target" "$backup"; then
                            if mv "$tmp" "$target"; then
                                rm -rf "$backup"
                                antigravity_status=installed
                            else
                                rm -rf "$tmp"
                                echo "   Warning: failed to promote curated skill for Antigravity: $skill"
                                mv "$backup" "$target" || echo "   Warning: failed to restore Antigravity skill backup: $skill"
                            fi
                        else
                            rm -rf "$tmp"
                            echo "   Warning: failed to back up existing Antigravity skill: $skill"
                        fi
                    elif mv "$tmp" "$target"; then
                        antigravity_status=installed
                    else
                        rm -rf "$tmp"
                        echo "   Warning: failed to promote curated skill for Antigravity: $skill"
                    fi
                else
                    rm -rf "$tmp"
                    echo "   Warning: failed to copy curated skill for Antigravity: $skill"
                fi
            else
                antigravity_status=skipped
                echo "   Warning: Claude skill missing; skipping Antigravity copy: $skill"
            fi

            case "$antigravity_status" in
                installed) ((antigravity_installed += 1)) ;;
                skipped) ((antigravity_skipped += 1)) ;;
                *) ((antigravity_failed += 1)) ;;
            esac

            command_dir="$HOME/.config/opencode/commands"
            command_file="$command_dir/$skill.md"
            source="$HOME/.agents/skills/$skill"
            if [[ -f "$source/SKILL.md" ]]; then
                mkdir -p "$command_dir"
                if [[ -f "$command_file" ]] && ! grep -Fq 'managed-by: chezmoi-curated-skills' "$command_file"; then
                    echo "   Warning: OpenCode command is user-managed; leaving unchanged: $command_file"
                else
                    tmp="$(mktemp "$command_dir/.${skill}.tmp.XXXXXX")"
                    {
                        printf '%s\n' '<!-- managed-by: chezmoi-curated-skills -->' '---'
                        printf 'description: Run the %s skill\n' "$skill"
                        printf '%s\n' '---'
                        printf 'Load the native `%s` skill with the skill tool, then follow it for: $ARGUMENTS\n' "$skill"
                    } > "$tmp"
                    mv "$tmp" "$command_file"
                fi
            elif [[ -f "$command_file" ]] && grep -Fq 'managed-by: chezmoi-curated-skills' "$command_file"; then
                rm -f "$command_file"
            fi
        done < "$catalog"
    fi
    echo "   Curated skills: Claude Code installed=$claude_installed skipped=$claude_skipped failed=$claude_failed"
    echo "   Curated skills: OpenCode installed=$opencode_installed skipped=$opencode_skipped failed=$opencode_failed"
    echo "   Curated skills: Antigravity installed=$antigravity_installed skipped=$antigravity_skipped failed=$antigravity_failed"
    echo "   Curated skills: Codex installed=$codex_installed skipped=$codex_skipped failed=$codex_failed"
else
    echo "   Curated skills: Claude Code installed=0 skipped=16 failed=0"
    echo "   Curated skills: OpenCode installed=0 skipped=16 failed=0"
    echo "   Curated skills: Antigravity installed=0 skipped=16 failed=0"
    echo "   Curated skills: Codex installed=0 skipped=16 failed=0"
fi

# Superpowers for Codex CLI: not automated - see run_onchange_install_packages.sh.tmpl
# for why (the only scriptable option is structurally incompatible with this
# plugin's manifest format, confirmed via an isolated test, not just an
# interactive-prompt issue). Update it via Codex's own `/plugins` UI.

# 1c. Agent guardrails (agent-guardrails release binary + Claude gen-config).
#     Keep GUARDRAIL_VERSION in sync with run_onchange_install_packages.sh.tmpl.
GUARDRAIL_VERSION="v0.18.0-dev"
GUARDRAIL_REPO="CtrlCarlitos/agent-guardrails"
guardrail_dest="$HOME/.local/bin/guardrail"
if [ "$(command -v guardrail >/dev/null 2>&1 && guardrail version 2>/dev/null)" != "guardrail ${GUARDRAIL_VERSION}" ]; then
    case "$(uname -s)" in Linux) gos=linux ;; Darwin) gos=darwin ;; *) gos= ;; esac
    case "$(uname -m)" in x86_64|amd64) garch=amd64 ;; aarch64|arm64) garch=arm64 ;; *) garch= ;; esac
    if [ -n "$gos" ] && [ -n "$garch" ]; then
        gtmp="$(mktemp -d)"
        gbase="https://github.com/${GUARDRAIL_REPO}/releases/download/${GUARDRAIL_VERSION}"
        # stock macOS ships `shasum`, not `sha256sum` — without this the pipeline
        # returns 127, the install is skipped, and the Mac is left with NO guard
        # under a message that misattributes it to a checksum mismatch.
        SHA_CMD=""
        if command -v sha256sum &>/dev/null; then SHA_CMD="sha256sum"
        elif command -v gsha256sum &>/dev/null; then SHA_CMD="gsha256sum"
        elif command -v shasum &>/dev/null; then SHA_CMD="shasum -a 256"
        else echo "  guardrail: no SHA-256 tool found - cannot verify, skipping install"; fi
        if [ -z "$SHA_CMD" ]; then
            :
        elif curl -fLo "$gtmp/guardrail_${gos}_${garch}" "${gbase}/guardrail_${gos}_${garch}" \
           && curl -fLo "$gtmp/SHA256SUMS" "${gbase}/SHA256SUMS" \
           && ( cd "$gtmp" && grep " guardrail_${gos}_${garch}\$" SHA256SUMS | $SHA_CMD -c - ); then
            mkdir -p "$HOME/.local/bin"
            if ! install -m 0755 "$gtmp/guardrail_${gos}_${garch}" "$guardrail_dest"; then
                echo "  guardrail install failed - skipping"
            else
                echo "  guardrail updated to ${GUARDRAIL_VERSION}"
            fi
        else
            echo "  guardrail update failed or checksum mismatch - skipping"
        fi
        rm -rf "$gtmp"
    fi
fi
if command -v claude >/dev/null 2>&1 && [ -x "$guardrail_dest" ]; then
    "$guardrail_dest" gen-config claude --merge "$HOME/.claude/settings.json" --binary "$guardrail_dest" || true
fi
if command -v opencode >/dev/null 2>&1 && [ -x "$guardrail_dest" ]; then
    mkdir -p "$HOME/.local/share/guardrail"
    "$guardrail_dest" gen-config opencode --merge "$HOME/.config/opencode/opencode.json" --binary "$guardrail_dest" --plugin-dir "$HOME/.local/share/guardrail" || true
fi
if command -v agy >/dev/null 2>&1 && [ -x "$guardrail_dest" ]; then
    mkdir -p "$HOME/.gemini/config"
    "$guardrail_dest" gen-config antigravity --merge "$HOME/.gemini/config/hooks.json" --binary "$guardrail_dest" || true
fi

# 2. Claude Code (Native)
if command -v claude &>/dev/null; then
    echo "🧠 Updating Claude Code..."
    # Try built-in update first (if it exists/works), otherwise reinstall
    if ! claude update &>/dev/null; then
        echo "   Running installer to update..."
        curl -L https://claude.ai/download/cli/linux | sh
    fi

    # Superpowers skills plugin
    echo "✨ Updating Superpowers (Claude Code)..."
    claude plugin update superpowers -y &>/dev/null || echo "   Superpowers not installed for Claude Code - skipping"
fi

# 3. OpenCode (Native)
if command -v opencode &>/dev/null; then
    echo "💻 Updating OpenCode..."
    curl -fsSL https://opencode.ai/install | bash
    # A legacy npm-global opencode-ai shim (dead binary - postinstall never
    # ran) can shadow the native binary this installer just refreshed; remove
    # it if present. Harmless when npm or the package is absent.
    npm rm -g opencode-ai &>/dev/null || true

    # Superpowers skills - not a `claude plugin`, it's a git-backed npm
    # package under OpenCode's own config dir; re-running the install pulls
    # the latest commit since no version/tag is pinned.
    echo "✨ Updating Superpowers (OpenCode)..."
    # --allow-git=all: npm 12+ blocks git-URL dependencies by default (EALLOWGIT)
    npm install "superpowers@git+https://github.com/obra/superpowers.git" --prefix "$HOME/.config/opencode" --allow-git=all --loglevel=error --no-progress 2>/dev/null || echo "   Superpowers not installed for OpenCode - skipping"
fi

# 4. Playwright Chromium (headless browser for agent automation)
if command -v npx &>/dev/null; then
    echo "🌐 Updating Playwright Chromium..."
    npx --yes playwright install chromium &>/dev/null || echo "   Playwright Chromium update failed - skipping"
fi

# 5. agent-browser. Playwright runs first so this CLI can reuse its Chromium.
if command -v npm &>/dev/null; then
    NPM_BIN="$(command -v npm)"
    echo "🌐 Updating agent-browser..."
    "$NPM_BIN" install -g --allow-scripts=agent-browser agent-browser --loglevel=error --no-progress 2>/dev/null || echo "   agent-browser install failed - skipping"
    AGENT_BROWSER_BIN="$("$NPM_BIN" prefix -g)/bin/agent-browser"
    if [[ -x "$AGENT_BROWSER_BIN" ]]; then
        "$AGENT_BROWSER_BIN" install &>/dev/null || echo "   agent-browser browser setup failed - skipping"
        "$AGENT_BROWSER_BIN" doctor --json &>/dev/null || echo "   agent-browser verification failed - continuing"
    fi
fi

# 6. Serena (uv-managed) + Graft (self-upgrading via `graft upgrade`)
command -v serena &>/dev/null && { uv tool upgrade serena-agent 2>/dev/null || echo "  Warning: serena upgrade failed - continuing"; }
command -v graft &>/dev/null && { graft upgrade 2>/dev/null || echo "  Warning: graft upgrade failed - continuing"; }

echo "✅ AI Tools Update Complete!"
