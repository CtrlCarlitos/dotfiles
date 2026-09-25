#!/usr/bin/env bash
# scripts/lib/agent-skills.sh - the curated-agent-skills lifecycle and its
# supporting helpers, shared by every shell consumer (issue #123).
#
# Consumers:
#   - run_onchange_install_packages.sh.tmpl: inlined at RENDER time via
#     `{{ include "scripts/lib/agent-skills.sh" }}` - a run_onchange script
#     must stay self-contained, so the installer cannot source at runtime.
#   - scripts/update_ai_tools.sh: sources this file directly
#     (". "${BASH_SOURCE[0]%/*}/lib/agent-skills.sh"").
#   - scripts/update-versions.sh: net_timeout + sha256_cmd only.
#
# The file is deliberately TEMPLATE-FREE plain bash: both consumers must be
# able to load it byte-for-byte. Every value that differs per consumer
# (catalog path, agent list, npx wrapper, tally counters, record_cli_result)
# is resolved dynamically from the caller's scope.
#
# Behavior pins: tests/agent_skill_wiring_contract.sh extracts the lifecycle
# by marker and executes it in fixtures; tests/install_agent_skills_arguments.sh
# pins the exact npx argument vector. The add/verify bodies here are verbatim
# from the installer (previously copy-pasted into update_ai_tools.sh, which
# had drifted: no net_timeout, no shared logging - the 2026-08-30 hang class).

#-------------------------------------------------------------------------------
# Colors + logging - the one shell convention (the installer used to define
# these inline; the updater used raw echo).
#-------------------------------------------------------------------------------
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { printf "${BLUE}▸${NC} %s\n" "$1"; }
success() { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}⚠${NC} %s\n" "$1" >&2; }
error()   { printf "${RED}✗${NC} %s\n" "$1" >&2; }

#-------------------------------------------------------------------------------
# net_timeout <seconds> <cmd...> - wall-clock guard for network install steps.
#
# A stalled download or `curl | sh` installer (no built-in timeout) otherwise
# freezes a `set -e` run indefinitely - confirmed live: Ollama's ~1.5GB bundle
# stalled mid-transfer for 15+ min with nothing else able to proceed, and the
# skills CLI once hung at its intro banner. Wrap the fetch so a dead
# connection is killed and the caller's `|| warn` can carry on.
#
# Uses coreutils `timeout` (always present on Linux) or `gtimeout` (macOS -
# `coreutils` is first in the brew core list so it lands before the guarded
# steps); if neither exists the command runs unguarded rather than failing.
# Resolved per-call, not cached, so a `gtimeout` installed partway through a
# macOS run is picked up by later steps. `-k 10` follows SIGTERM with SIGKILL
# after 10s for processes that ignore the first signal. Exit 124 = timed out.
#-------------------------------------------------------------------------------
net_timeout() {
    local secs="$1"; shift
    local bin=""
    if command -v timeout &>/dev/null; then bin="timeout"
    elif command -v gtimeout &>/dev/null; then bin="gtimeout"
    fi
    if [ -n "$bin" ]; then
        "$bin" -k 10 "$secs" "$@"
    else
        "$@"
    fi
}

#-------------------------------------------------------------------------------
# sha256_cmd - print the available SHA-256 tool ("shasum -a 256" included
# verbatim: stock macOS ships shasum, not sha256sum), empty when none.
#-------------------------------------------------------------------------------
sha256_cmd() {
    if command -v sha256sum &>/dev/null; then printf '%s\n' "sha256sum"
    elif command -v gsha256sum &>/dev/null; then printf '%s\n' "gsha256sum"
    elif command -v shasum &>/dev/null; then printf '%s\n' "shasum -a 256"
    fi
}

#-------------------------------------------------------------------------------
# fetch_and_verify <name> <asset_url> <sums_url> <asset_name> <dest_dir>
#
# Download-to-temp + checksum-verify for third-party installers that publish
# SHA256SUMS (#125's verify_and_run_installer): fetches the asset and its
# SHA256SUMS into <dest_dir> (net_timeout-guarded, never piped), verifies
# <asset_name> against the one-line SHA256SUMS entry, returns 0 iff verified.
# Verifies from a one-line file, not stdin (like agent-guardrails' own
# installer): a BSD-compatible sha256sum (macOS 14+) may not read `-c -`.
# No <asset_name> line fails the grep, so a partial SHA256SUMS fail-closes.
# Warns and returns non-zero on any failure; the caller owns cleanup and the
# run-from-a-file step.
#-------------------------------------------------------------------------------
fetch_and_verify() {
    local name="$1" asset_url="$2" sums_url="$3" asset_name="$4" dest="$5"
    if ! net_timeout 60 curl -fLo "$dest/$asset_name" "$asset_url" ||
        ! net_timeout 60 curl -fLo "$dest/SHA256SUMS" "$sums_url"; then
        warn "$name: installer download failed or timed out - skipping"
        return 1
    fi
    local sha
    sha="$(sha256_cmd)"
    if [ -z "$sha" ]; then
        warn "$name: no SHA-256 tool found - cannot verify installer, skipping"
        return 1
    fi
    if ! ( cd "$dest" && grep " ${asset_name}\$" SHA256SUMS >SHA256SUMS.one &&
        $sha -c SHA256SUMS.one ); then
        warn "$name: installer CHECKSUM MISMATCH - not running it"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# skills_add_all - the curated third-party skills, installed via the `skills`
# CLI (vercel-labs/skills) for Claude Code / OpenCode / Antigravity / Codex.
#
# Caller-provided (dynamic scope):
#   SK      array - the npx wrapper, e.g. (npx --yes --loglevel=error skills@latest)
#   AGENTS  array - adapters from .chezmoidata/agents.yaml skills.agents
#   record_cli_result <status> <count> - the caller's per-agent tally
#   info/warn - provided by this file
#
# Every call: `</dev/null` keeps any prompt from ever holding the terminal
# (chezmoi run_onchange scripts inherit the terminal's TTY on stdin; a CLI
# that decides to prompt - or a stalled fetch with no internal timeout - then
# blocks the whole run; confirmed live 2026-08-30). net_timeout stays as the
# wall-clock backstop.
#-------------------------------------------------------------------------------
skills_add_all() {
    # Matt Pocock's engineering/productivity skills - 11 installed as-is.
    # teach + writing-for-agents live under skills/productivity/, the rest under
    # skills/engineering/; the CLI resolves by skill name, not path (grilling and
    # handoff are already productivity/ skills that resolve fine here).
    info "Installing Matt Pocock's skills (Claude Code / OpenCode / Antigravity)..."
    if net_timeout 300 "${SK[@]}" add mattpocock/skills \
        -s codebase-design domain-modeling grill-with-docs improve-codebase-architecture \
           prototype research grilling handoff teach writing-for-agents \
           resolving-merge-conflicts \
        -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 11
    else
        record_cli_result failed 11
        warn "Matt Pocock skills install failed or timed out - continuing"
    fi

    # code-review -> mp-code-review. The `skills` CLI has no rename flag, so
    # stage a renamed copy with its `name:` frontmatter patched and install
    # that local directory. "mp-" keeps it distinct from this repo's own
    # /code-review command and Superpowers' receiving-code-review skill.
    local sk_tmp; sk_tmp="$(mktemp -d)"
    # net_timeout: same wall-clock contract as every other network fetch here
    # (docs/tool-parity.md's Network-step timeouts section includes git clones).
    if net_timeout 60 git clone --quiet --depth 1 https://github.com/mattpocock/skills "$sk_tmp/repo" 2>/dev/null; then
        local src="$sk_tmp/repo/skills/engineering/code-review"
        [[ -d "$src" ]] || src="$sk_tmp/repo/code-review"
        if [[ -d "$src" ]]; then
            mkdir -p "$sk_tmp/stage/mp-code-review"
            cp -r "$src/." "$sk_tmp/stage/mp-code-review/"
            local skf="$sk_tmp/stage/mp-code-review/SKILL.md"
            if [[ -f "$skf" ]]; then
                # portable in-place edit (GNU and BSD sed differ on -i).
                # Guarded: a bare failing `sed ... && mv` here would trip
                # set -e and abort the whole run - frontend-design, Playwright,
                # act, desktop apps and shell setup all come after this.
                sed 's/^name:[[:space:]].*/name: mp-code-review/' "$skf" > "$skf.tmp" && mv "$skf.tmp" "$skf"
                if net_timeout 120 "${SK[@]}" add "$sk_tmp/stage" -s mp-code-review -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
                    record_cli_result installed 1
                else
                    record_cli_result failed 1
                    warn "mp-code-review skill install failed - continuing"
                fi
            else
                record_cli_result skipped 1
                warn "SKILL.md missing from staged code-review - upstream layout changed? Skipping mp-code-review."
            fi
        else
            record_cli_result skipped 1
            warn "code-review skill dir not found in mattpocock/skills - upstream layout changed?"
        fi
    else
        record_cli_result failed 1
        warn "mp-code-review skill source clone failed or timed out - continuing"
    fi
    rm -rf "$sk_tmp"

    # Anthropic's frontend-design skill - distinctive visual direction for new UI.
    info "Installing Anthropic's frontend-design skill..."
    if net_timeout 300 "${SK[@]}" add anthropics/skills -s frontend-design -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
    else
        record_cli_result failed 1
        warn "frontend-design skill install failed or timed out - continuing"
    fi

    # find-skills (vercel-labs/skills, 3.4M installs on skills.sh) - lets an
    # agent search and install skills from skills.sh mid-session.
    info "Installing find-skills skill..."
    if net_timeout 300 "${SK[@]}" add vercel-labs/skills -s find-skills -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
    else
        record_cli_result failed 1
        warn "find-skills skill install failed or timed out - continuing"
    fi

    # agent-browser (vercel-labs/agent-browser, 843.8K installs) - browser
    # automation: navigate, click, fill, scrape, screenshot.
    info "Installing agent-browser skill..."
    if net_timeout 300 "${SK[@]}" add vercel-labs/agent-browser -s agent-browser -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
    else
        record_cli_result failed 1
        warn "agent-browser skill install failed or timed out - continuing"
    fi

    # skill-creator (CtrlCarlitos/skills) - our drop-in fork of Anthropic's skill-creator with Windows fixes (pipe reader, UTF-8 file I/O, --project-root); pinned upstream commit + patch queue in that repo, drop when anthropics/skills#1827 lands.
    # Upstream was: (anthropics/skills, 380K installs) - Anthropic's
    # skill-authoring lifecycle tool with benchmarks and eval viewer.
    info "Installing Anthropic's skill-creator skill..."
    if net_timeout 300 "${SK[@]}" add CtrlCarlitos/skills -s skill-creator -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
    else
        record_cli_result failed 1
        warn "skill-creator skill install failed or timed out - continuing"
    fi

    # taste skills (Leonxlnx/taste-skill, MIT): design-taste-frontend infers a
    # visual direction for new pages behind tunable dials plus an anti-slop
    # checklist; redesign-existing-projects audits an existing UI's styling
    # and applies targeted fixes without changing behaviour. Chosen 2026-09-24
    # for function, not popularity - the repo's style presets, image-generation
    # skills, GPT/Stitch variants and v1 were left out (see
    # docs/skills-install-strategy.md). Overlaps anthropics/frontend-design on
    # purpose; drop one if they double-trigger.
    info "Installing taste skills (design-taste-frontend, redesign-existing-projects)..."
    if net_timeout 300 "${SK[@]}" add Leonxlnx/taste-skill -s design-taste-frontend redesign-existing-projects -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 2
    else
        record_cli_result failed 2
        warn "taste skills install failed or timed out - continuing"
    fi

    # code-search (CtrlCarlitos/skills, MIT): our own search-escalation skill.
    # Probes once per session which tools can see the code (graft graph built
    # and covering the language, serena LSP, rg, grep), routes each question
    # down graft > serena > rg > grep, and stops re-asking a semantic tool after
    # one empty result. Added 2026-09-24 after graft's "graph first for ANY
    # task" block cost every session in this repo two empty queries (the graph
    # covers one Lua file here) - docs/skills-install-strategy.md.
    info "Installing code-search skill..."
    if net_timeout 300 "${SK[@]}" add CtrlCarlitos/skills -s code-search -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
    else
        record_cli_result failed 1
        warn "code-search skill install failed or timed out - continuing"
    fi

    # (writing-great-skills removed 2026-09-14: mattpocock renamed it upstream to
    #  writing-for-agents, which is already in the batch above — the old name
    #  failed silently on every run.)
}

#-------------------------------------------------------------------------------
# verify_curated_skill_targets - the post-install verification pass over the
# catalog (scripts/curated-agent-skills.txt), shared verbatim.
#
# Caller-provided (dynamic scope):
#   catalog         - path to the curated catalog
#   claude_reported / opencode_reported / codex_reported - CLI-phase tallies
#                     (a target is only "failed" when its CLI phase ran)
#   claude_installed / opencode_installed / codex_installed /
#   antigravity_installed / antigravity_skipped / antigravity_failed - tallies
#   info/warn - provided by this file
#
# A successful CLI exit only means its copy operation completed: an agent is
# counted installed only after its supported discovery target exists, the
# Claude copy is fanned out to Antigravity with backup/restore, and a
# managed-by marker guards the OpenCode command shim.
#-------------------------------------------------------------------------------
verify_curated_skill_targets() {
    local skill source target tmp backup command_dir command_file antigravity_status
    while IFS= read -r skill || [[ -n "$skill" ]]; do
        [[ -z "$skill" || "$skill" == \#* ]] && continue

        # Count an agent installed only after its supported discovery target
        # exists; the CLI exit status alone is insufficient.
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
                    warn "Failed to prepare Antigravity skill backup: $skill"
                elif [[ -e "$target" || -L "$target" ]]; then
                    if mv "$target" "$backup"; then
                        if mv "$tmp" "$target"; then
                            rm -rf "$backup"
                            antigravity_status=installed
                        else
                            rm -rf "$tmp"
                            warn "Failed to promote curated skill for Antigravity: $skill"
                            mv "$backup" "$target" || warn "Failed to restore Antigravity skill backup: $skill"
                        fi
                    else
                        rm -rf "$tmp"
                        warn "Failed to back up existing Antigravity skill: $skill"
                    fi
                elif mv "$tmp" "$target"; then
                    antigravity_status=installed
                else
                    rm -rf "$tmp"
                    warn "Failed to promote curated skill for Antigravity: $skill"
                fi
            else
                rm -rf "$tmp"
                warn "Failed to copy curated skill for Antigravity: $skill"
            fi
        else
            antigravity_status=skipped
            warn "Claude skill missing; skipping Antigravity copy: $skill"
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
                warn "OpenCode command is user-managed; leaving unchanged: $command_file"
            else
                tmp="$(mktemp "$command_dir/.${skill}.tmp.XXXXXX")"
                {
                    printf '%s\n' '<!-- managed-by: chezmoi-curated-skills -->' '---'
                    printf 'description: Run the %s skill\n' "$skill"
                    printf '%s\n' '---'
                    # shellcheck disable=SC2016 # OpenCode expands this placeholder at command invocation.
                    printf 'Load the native `%s` skill with the skill tool, then follow it for: $ARGUMENTS\n' "$skill"
                } > "$tmp"
                mv "$tmp" "$command_file"
            fi
        elif [[ -f "$command_file" ]] && grep -Fq 'managed-by: chezmoi-curated-skills' "$command_file"; then
            rm -f "$command_file"
        fi
    done < "$catalog"
}
