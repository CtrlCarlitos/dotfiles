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
# net_timeout_tty <seconds> <cmd...> - net_timeout for commands that need the
# terminal (sudo). Plain `timeout` runs its command in a NEW process group, so
# a sudo/pty that touches the tty from there is a background job and the
# kernel can stop it (SIGTTIN/SIGTTOU). `--foreground` keeps the command in
# the shell's foreground group. Seen: `sudo npx playwright install-deps` on
# WSL sat in state T for the full timeout AFTER apt had finished (the cause is
# a strong suspect, not reproduced: it needs a sudo password). Trade-off:
# --foreground times out only the direct child, not its descendants.
#-------------------------------------------------------------------------------
net_timeout_tty() {
    local secs="$1"; shift
    if command -v timeout &>/dev/null; then
        timeout --foreground -k 10 "$secs" "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout --foreground -k 10 "$secs" "$@"
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
    if ! net_timeout 60 curl -fsSL -o "$dest/$asset_name" "$asset_url" ||
        ! net_timeout 60 curl -fsSL -o "$dest/SHA256SUMS" "$sums_url"; then
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
#-------------------------------------------------------------------------------
# agent_browser_doctor <agent-browser binary> - run `doctor --json` (60 s cap) and print
# a one-line summary plus one line per warn/fail check, instead of the ~3 KB JSON blob it
# used to dump on every run. Output that is not the expected JSON (or no jq) is printed
# raw, never dropped. Returns doctor's own exit status.
#-------------------------------------------------------------------------------
agent_browser_doctor() {
    local out rc=0
    out="$(net_timeout 60 "$1" doctor --json 2>&1)" || rc=$?
    if command -v jq &>/dev/null && printf '%s' "$out" | jq -e '.summary' >/dev/null 2>&1; then
        printf '%s' "$out" | jq -b -r '"agent-browser doctor: \(.summary.pass // 0) pass, \(.summary.warn // 0) warn, \(.summary.fail // 0) fail", (.checks[]? | select(.status == "warn" or .status == "fail") | "  \(.status): \(.message)" + (if .fix then " (fix: \(.fix))" else "" end))'
    else
        printf '%s\n' "$out"
    fi
    return "$rc"
}

#-------------------------------------------------------------------------------
# skills_up_to_date <owner/repo> <skill>... - 0 when this source need not be
# fetched again, 1 when it must be (or when anything is unknown).
#
# `skills add` re-fetches every skill on every run, and a cold `npx
# skills@latest` costs 30+ s even when nothing moved upstream. A source is
# skipped only when ALL of these hold:
#   - DOT_SKILLS_FORCE is not 1,
#   - every named skill is present for Claude (~/.claude/skills) and for
#     OpenCode/Codex (~/.agents/skills),
#   - upstream HEAD (one `git ls-remote`) equals the commit recorded after the
#     last successful install of this exact source + skill list + agent list.
# An unreachable remote never skips. Why not `skills update`: it takes no
# --copy / -a flags and re-links the Claude copy as a symlink into
# ~/.agents (measured on skills 1.7.0), but these installs are deliberately
# copies. This is the version check instead.
#
# Side effect: remembers the key and the HEAD it saw in SKILLS_PENDING_KEY /
# SKILLS_PENDING_HEAD, so skills_record_source (called after the add succeeds)
# stores exactly the commit that was checked.
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# quiet_apt_enable - make every `apt install|update` / `apt-get install|update` this shell runs
# print only what matters.
#
# A WSL `dot up` printed ~100 lines of apt chatter ("git is already the newest version",
# "Reading package lists...", "N upgraded, 0 newly installed...", the update's Hit:/Get: list)
# across ~13 install groups, while the Windows run (choco) was quiet. `apt -qq` still prints the
# "already the newest version" lines; `apt-get -qq` prints nothing but errors (and dpkg's own
# lines for a real install), and has no "apt does not have a stable CLI interface" warning. So
# install and update are routed to `apt-get -qq`; every other apt subcommand, and every other
# sudo command, passes through untouched. Done with functions so none of the ~40 call sites
# (pinned by tests/package_catalog_contract.sh) has to change, and
# with NO pipe, so prompts, sudo's password request and exit codes behave exactly as before.
# DOT_APT_VERBOSE=1 leaves apt alone. Call it only once the package manager is known to be apt.
#-------------------------------------------------------------------------------
_qapt_rewrite() {
    QAPT_ARGS=("$@")
    case "$1:${2:-}" in
        apt:install | apt:update | apt-get:install | apt-get:update) QAPT_ARGS=(apt-get -qq "${@:2}") ;;
    esac
}

quiet_apt_enable() {
    [ "${DOT_APT_VERBOSE:-}" != 1 ] || return 0
    # shellcheck disable=SC2317  # defined here, called by the installer's own commands
    sudo() {
        if [ "${1:-}" = apt ] || [ "${1:-}" = apt-get ]; then
            _qapt_rewrite "$@"
            command sudo "${QAPT_ARGS[@]}"
        else
            command sudo "$@"
        fi
    }
    # shellcheck disable=SC2317
    apt() { _qapt_rewrite apt "$@"; command "${QAPT_ARGS[@]}"; }
    # shellcheck disable=SC2317
    apt-get() { _qapt_rewrite apt-get "$@"; command "${QAPT_ARGS[@]}"; }
    info "apt install/update output is quiet (DOT_APT_VERBOSE=1 shows it); errors are always shown."
}

#-------------------------------------------------------------------------------
# guardrail_console_filter - stdin: the agent-guardrails installer's output; stdout: the
# same, minus the routine status lines.
#
# The installer ends every run with a ~45-line doctor dump (policy, recipes, audit log, hook
# latency, four planes registered, four probe summaries, MCP coverage...). On a healthy run
# that is the same text every time and it buried the lines that matter. The FULL output still
# goes to the apply log (tee, upstream of this filter); the console loses only the lines whose
# shape is on the list below. Everything else stays: a warning, a problem, a verdict, the hook
# latency, and anything this list has never seen - above all an approval prompt or URL, which
# the installer blocks on, so nothing is ever hidden by default.
# DOT_GUARDRAIL_VERBOSE=1 shows everything.
#-------------------------------------------------------------------------------
guardrail_console_filter() {
    if [ "${DOT_GUARDRAIL_VERBOSE:-}" = 1 ]; then cat; return 0; fi
    awk '
        /^(cwd|GUARDRAIL_CONFIG|overlay|policy warnings|waivers|audit log|approval mode|operator authenticators|engine health|spawn latency):/ { hidden++; next }
        /^web-research enforcement:/ { hidden++; next }
        /^recipes / { hidden++; next }
        /^(claude|opencode|antigravity|codex): (already enabled|probes pass|guardrail (hook|hooks|integration) registered)/ { hidden++; next }
        /^(claude|opencode|antigravity|codex) settings: guardrail (hook|hooks|integration) registered($|;)/ { hidden++; next }
        /^(claude|opencode|antigravity|codex) ownership: (manifest matches settings|no manifest)/ { hidden++; next }
        /^antigravity coverage:/ { hidden++; next }
        /^  (configured MCP servers|declared MCP tools|uncontracted)/ { hidden++; next }
        /^note: codex probes invoke the hook directly/ { hidden++; next }
        /^setup: (registering|plane status)/ { hidden++; next }
        /^guardrail v[0-9]/ { hidden++; next }
        { print; fflush() }
        END { if (hidden > 0) printf "  (%d routine guardrail status line(s) hidden; full output in the apply log, or DOT_GUARDRAIL_VERBOSE=1)\n", hidden }
    '
}

#-------------------------------------------------------------------------------
# skills_remove_retired <list-file> - remove skills listed in
# scripts/retired-agent-skills.txt (`<skill> <source>` per line) from every agent
# directory, the OpenCode command shim we generated, and the skills CLI lock.
#
# Only when the lock records that exact source for the skill: a skill of the same
# name written by hand (no lock entry, or another source) is never touched. The
# name is restricted to [a-z0-9-] so a malformed list cannot reach another path.
# Best effort and idempotent; needs jq (without it nothing is removed).
#-------------------------------------------------------------------------------
skills_remove_retired() {
    local list="${1:-}" lock="$HOME/.agents/.skill-lock.json" name source shim tmp
    [ -r "$list" ] && [ -r "$lock" ] && command -v jq &>/dev/null || return 0
    while read -r name source _; do
        case "$name" in '' | '#'*) continue ;; esac
        [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || continue
        [ "$(jq -b -r --arg n "$name" '.skills[$n].source // empty' "$lock" 2>/dev/null)" = "$source" ] || continue
        rm -rf "${HOME:?}/.claude/skills/$name" "${HOME:?}/.agents/skills/$name" "${HOME:?}/.gemini/antigravity-cli/skills/$name"
        shim="$HOME/.config/opencode/commands/$name.md"
        if [ -f "$shim" ] && grep -Fq 'managed-by: chezmoi-curated-skills' "$shim" 2>/dev/null; then
            rm -f "$shim"
        fi
        tmp="$lock.tmp.$$"
        if jq --arg n "$name" 'del(.skills[$n])' "$lock" >"$tmp" 2>/dev/null; then
            mv "$tmp" "$lock"
        else
            rm -f "$tmp"
        fi
        info "Removed retired skill: $name"
    done <"$list"
    return 0
}

skills_source_state() {
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/skills-sources"
}

# Every source key a run checked (skills_up_to_date appends); skills_prune_state keeps those.
SKILLS_SEEN_KEYS=()
SKILLS_STALE_REASON=""

skills_up_to_date() {
    local repo="$1"; shift
    local skill recorded
    SKILLS_PENDING_KEY="$repo|$*|${AGENTS[*]}"
    SKILLS_SEEN_KEYS+=("$SKILLS_PENDING_KEY")
    SKILLS_PENDING_HEAD="$(net_timeout 20 git ls-remote "https://github.com/$repo.git" HEAD 2>/dev/null | cut -f1 | head -n 1)" || SKILLS_PENDING_HEAD=""
    # Why the answer is "not current", printed with the install line (twin of
    # $script:SkillsStaleReason): a reinstall on every run then says why.
    SKILLS_STALE_REASON=""
    if [ "${DOT_SKILLS_FORCE:-}" = 1 ]; then SKILLS_STALE_REASON="DOT_SKILLS_FORCE=1"; return 1; fi
    for skill in "$@"; do
        if [ ! -f "$HOME/.claude/skills/$skill/SKILL.md" ]; then SKILLS_STALE_REASON="$skill missing from ~/.claude/skills"; return 1; fi
        if [ ! -f "$HOME/.agents/skills/$skill/SKILL.md" ]; then SKILLS_STALE_REASON="$skill missing from ~/.agents/skills"; return 1; fi
    done
    if [ -z "$SKILLS_PENDING_HEAD" ]; then SKILLS_STALE_REASON="upstream unreachable"; return 1; fi
    recorded="$(awk -F'\t' -v k="$SKILLS_PENDING_KEY" '$1 == k { print $2 }' "$(skills_source_state)" 2>/dev/null || true)"
    if [ -z "$recorded" ]; then SKILLS_STALE_REASON="no install recorded for this selection"; return 1; fi
    if [ "$recorded" != "$SKILLS_PENDING_HEAD" ]; then SKILLS_STALE_REASON="upstream changed"; return 1; fi
}

# skills_prune_state - drop state lines this run superseded. A source key is
# repo|skills|agents, so changing a selection (a skill added or retired) leaves the old key
# behind for good. For every repo this run checked, keep only the keys it checked; lines for
# repos it did not touch are never removed. Best effort: the state is only a cache, and a
# wrongly dropped line costs one reinstall.
skills_prune_state() {
    local state tmp seen
    [ "${#SKILLS_SEEN_KEYS[@]}" -gt 0 ] || return 0
    state="$(skills_source_state)"
    [ -f "$state" ] || return 0
    seen="$(mktemp 2>/dev/null)" || return 0
    printf '%s\n' "${SKILLS_SEEN_KEYS[@]}" >"$seen"
    tmp="$state.tmp.$$"
    if awk -F'\t' -v seenfile="$seen" '
        BEGIN { while ((getline k < seenfile) > 0) { keys[k] = 1; split(k, p, "|"); repos[p[1]] = 1 } }
        { split($1, q, "|"); if (!(q[1] in repos) || ($1 in keys)) print }
    ' "$state" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$state" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
    rm -f "$seen"
    return 0
}

# skills_record_source - after a successful add: store the HEAD that
# skills_up_to_date saw for the same key. Best effort (state is only a cache).
skills_record_source() {
    [ -n "${SKILLS_PENDING_HEAD:-}" ] || return 0
    local state tmp
    state="$(skills_source_state)"
    mkdir -p "${state%/*}" 2>/dev/null || return 0
    tmp="$state.tmp.$$"
    {
        awk -F'\t' -v k="$SKILLS_PENDING_KEY" '$1 != k' "$state" 2>/dev/null || true
        printf '%s\t%s\n' "$SKILLS_PENDING_KEY" "$SKILLS_PENDING_HEAD"
    } >"$tmp"
    mv "$tmp" "$state" 2>/dev/null || rm -f "$tmp"
    return 0
}

# skills_cli <seconds> <cmd...> - net_timeout for a `skills` CLI call. Each call prints a banner, a
# summary box and a security table (about 35 lines, eight calls per run) that say nothing a
# "installed" line does not. Shown only when the call fails, or with DOT_SKILLS_VERBOSE=1.
skills_cli() {
    local secs="$1" out rc=0
    shift
    if [ "${DOT_SKILLS_VERBOSE:-}" = 1 ]; then
        net_timeout "$secs" "$@"
        return
    fi
    out="$(mktemp)"
    net_timeout "$secs" "$@" >"$out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then cat "$out" >&2; fi
    rm -f "$out"
    return "$rc"
}

skills_add_all() {
    # The npx wrapper is identical for every consumer, so the function that
    # uses it owns the definition (it used to sit in each consumer and drift).
    local -a SK=(npx --yes --loglevel=error skills@latest)

    # Matt Pocock's engineering/productivity skills - 12 installed as-is (pr and retro added
    # 2026-10-05, #269; the count below is the array length, never a literal).
    # teach + writing-for-agents live under skills/productivity/, the rest under
    # skills/engineering/; the CLI resolves by skill name, not path (grilling and
    # handoff are already productivity/ skills that resolve fine here).
    local -a mp_skills=(codebase-design domain-modeling grill-with-docs improve-codebase-architecture
        prototype research grilling handoff teach writing-for-agents pr retro)
    if skills_up_to_date mattpocock/skills "${mp_skills[@]}"; then
        info "Matt Pocock's skills: up to date"
        record_cli_result installed "${#mp_skills[@]}"
    elif info "Installing Matt Pocock's skills (Claude Code / OpenCode / Antigravity)..." && skills_cli 300 "${SK[@]}" add mattpocock/skills \
        -s "${mp_skills[@]}" \
        -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed "${#mp_skills[@]}"
        info "Matt Pocock's skills: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed "${#mp_skills[@]}"
        warn "Matt Pocock skills install failed or timed out - continuing"
    fi

    # code-review -> mp-code-review. The `skills` CLI has no rename flag, so
    # stage a renamed copy with its `name:` frontmatter patched and install
    # that local directory. "mp-" keeps it distinct from this repo's own
    # /code-review command and Superpowers' receiving-code-review skill.
    if skills_up_to_date mattpocock/skills mp-code-review; then
        info "mp-code-review: up to date"
        record_cli_result installed 1
    else
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
                    if skills_cli 120 "${SK[@]}" add "$sk_tmp/stage" -s mp-code-review -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
                        record_cli_result installed 1
                        skills_record_source
                        info "mp-code-review: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
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
    fi

    # Anthropic's frontend-design skill - distinctive visual direction for new UI.
    if skills_up_to_date anthropics/skills frontend-design; then
        info "frontend-design: up to date"
        record_cli_result installed 1
    elif info "Installing Anthropic's frontend-design skill..." && skills_cli 300 "${SK[@]}" add anthropics/skills -s frontend-design -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
        info "frontend-design: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed 1
        warn "frontend-design skill install failed or timed out - continuing"
    fi

    # find-skills (vercel-labs/skills, 3.4M installs on skills.sh) - lets an
    # agent search and install skills from skills.sh mid-session.
    if skills_up_to_date vercel-labs/skills find-skills; then
        info "find-skills: up to date"
        record_cli_result installed 1
    elif info "Installing find-skills skill..." && skills_cli 300 "${SK[@]}" add vercel-labs/skills -s find-skills -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
        info "find-skills: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed 1
        warn "find-skills skill install failed or timed out - continuing"
    fi

    # agent-browser (vercel-labs/agent-browser, 843.8K installs) - browser
    # automation: navigate, click, fill, scrape, screenshot.
    if skills_up_to_date vercel-labs/agent-browser agent-browser; then
        info "agent-browser: up to date"
        record_cli_result installed 1
    elif info "Installing agent-browser skill..." && skills_cli 300 "${SK[@]}" add vercel-labs/agent-browser -s agent-browser -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
        info "agent-browser: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed 1
        warn "agent-browser skill install failed or timed out - continuing"
    fi

    # skill-creator (CtrlCarlitos/skills) - our drop-in fork of Anthropic's skill-creator with Windows fixes (pipe reader, UTF-8 file I/O, --project-root); pinned upstream commit + patch queue in that repo, drop when anthropics/skills#1827 lands.
    # Upstream was: (anthropics/skills, 380K installs) - Anthropic's
    # skill-authoring lifecycle tool with benchmarks and eval viewer.
    if skills_up_to_date CtrlCarlitos/skills skill-creator; then
        info "skill-creator: up to date"
        record_cli_result installed 1
    elif info "Installing Anthropic's skill-creator skill..." && skills_cli 300 "${SK[@]}" add CtrlCarlitos/skills -s skill-creator -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
        info "skill-creator: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
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
    if skills_up_to_date Leonxlnx/taste-skill design-taste-frontend redesign-existing-projects; then
        info "taste skills: up to date"
        record_cli_result installed 2
    elif info "Installing taste skills (design-taste-frontend, redesign-existing-projects)..." && skills_cli 300 "${SK[@]}" add Leonxlnx/taste-skill -s design-taste-frontend redesign-existing-projects -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 2
        info "taste skills: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
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
    if skills_up_to_date CtrlCarlitos/skills code-search; then
        info "code-search: up to date"
        record_cli_result installed 1
    elif info "Installing code-search skill..." && skills_cli 300 "${SK[@]}" add CtrlCarlitos/skills -s code-search -a "${AGENTS[@]}" -g -y --copy < /dev/null; then
        record_cli_result installed 1
        info "code-search: installed${SKILLS_STALE_REASON:+ ($SKILLS_STALE_REASON)}"
        skills_record_source
    else
        record_cli_result failed 1
        warn "code-search skill install failed or timed out - continuing"
    fi

    # (writing-great-skills removed 2026-09-14: mattpocock renamed it upstream to
    #  writing-for-agents, which is already in the batch above — the old name
    #  failed silently on every run.)

    skills_prune_state
}

#-------------------------------------------------------------------------------
# verify_curated_skill_targets <claude_reported> <opencode_reported> <codex_reported>
# - the post-install verification pass over the catalog
# (scripts/curated-agent-skills.txt), shared verbatim.
#
# Arguments: the CLI-phase tallies from the caller's skills_add_all phase -
# a target is only counted "failed" when its CLI phase actually ran. Passed
# explicitly rather than via dynamic scope so the data flow stays visible.
#
# Caller-provided (dynamic scope):
#   catalog         - path to the curated catalog
#   claude_installed / opencode_installed / codex_installed /
#   antigravity_installed / antigravity_skipped / antigravity_failed - tallies
#   info/warn - provided by this file
#
# A successful CLI exit only means its copy operation completed: an agent is
# counted installed only after its supported discovery target exists, the
# Claude copy is fanned out to Antigravity with backup/restore, and a
# managed-by marker guards the OpenCode command shim.
# catalog is resolved from the caller's scope (the installer renders its
# sourceDir; the updater derives it from BASH_SOURCE) - invisible to static
# analysis by design, hence the whole-function suppression.
# shellcheck disable=SC2154
#-------------------------------------------------------------------------------
verify_curated_skill_targets() {
    local claude_reported="$1" opencode_reported="$2" codex_reported="$3"
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
