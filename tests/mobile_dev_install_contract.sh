#!/usr/bin/env bash
set -euo pipefail

# install_mobile_dev() contract (SDD plan 2026-10-10-mobile-dev-wsl-linux-macos,
# Task 2): Maestro CLI, agent-device, and a standalone JDK 17+.
#
# Maestro is NOT installed via the vendor's own
# `curl -fsSL https://get.maestro.mobile.dev | bash` one-liner (the task
# brief's original plan). Task 1's review found that installer only runs
# `unzip -qt` on what it downloads - a corruption check, not an authenticity
# one - which is exactly why .chezmoidata.yaml pins versions.maestro_version
# and versions.maestro_sha256 (tests/mobile_dev_version_pins_contract.sh).
# Running the vendor script would make that pin meaningless: "latest" would
# be fetched with no checksum enforced at all. install_mobile_dev() therefore
# downloads the pinned release asset directly and verifies it itself, the
# same shape install_powershell() already uses for its own pinned, verified
# download (net_timeout-wrapped curl, sha256_cmd, warn-and-continue on a
# mismatch - never abort under `set -e`).
#
# The release asset lives at a URL built from versions.maestro_version with a
# "cli-" tag prefix that is NOT part of the stored version string itself
# (confirmed directly against the real mobile-dev-inc/maestro release via
# `gh release view`/`gh release download` while writing this test - see the
# exact URL required below). Maestro is a single-user tool: it installs
# under $HOME/.local/opt (no $SUDO, unlike install_powershell()'s
# /opt/microsoft/... system install) with its binary symlinked into
# $HOME/.local/bin, which docs/agent-context-tools.md already documents as
# on PATH (uv's own tool shims land there the same way).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"

. "$repo_root/tests/lib.sh"

[ -f "$tmpl" ] || { fail "$tmpl missing"; finish; }

# --- Structure: the function exists and is wired at the established gate ---
require "$tmpl" 'install_mobile_dev()'

# --- Maestro: manual pinned+verified install, NOT the vendor curl|bash ----
forbid "$tmpl" 'get.maestro.mobile.dev'
require "$tmpl" 'mobile-dev-inc/maestro/releases/download/cli-'
require "$tmpl" '.versions.maestro_version'
require "$tmpl" '.versions.maestro_sha256'
require "$tmpl" 'maestro CHECKSUM MISMATCH'
require "$tmpl" '$HOME/.local/opt'
require "$tmpl" '$HOME/.local/bin/maestro'

# --- agent-device: npm global, reusing core's Node, command -v guarded ----
require "$tmpl" 'npm install -g agent-device'
require "$tmpl" 'command -v agent-device'

# --- Standalone JDK 17+: apt + brew branches, JAVA_HOME persisted ----------
require "$tmpl" 'openjdk-{{ .versions.jdk_version }}-jdk'
require "$tmpl" 'openjdk@{{ .versions.jdk_version }}'
require "$tmpl" 'JAVA_HOME'

# --- Maestro MCP registration for Claude Code and Codex, idempotent -------
# (Task 3, moved by the final fix round): mirrors the serena precedent's own
# gating shape ("mcp get" idempotency check, warn-and-continue on failure -
# never abort under `set -e`). Maestro has no vendor setup helper, unlike
# serena, so the raw "mcp add" call is used directly. Claude Code's call is
# USER scope: the default (local) scope is private to the installer's own
# working directory, invisible from every real project. Codex has no scope
# concept (one global config.toml), so its call carries no flag. Where the
# calls live (install_claude_cli/install_chatgpt_cli, not install_mobile_dev)
# is asserted on the render below.
require "$tmpl" 'claude mcp add -s user maestro -- maestro mcp'
forbid "$tmpl" 'claude mcp add maestro -- maestro mcp'
require "$tmpl" 'codex mcp add maestro -- maestro mcp'
require "$tmpl" 'claude mcp get maestro'
require "$tmpl" 'codex mcp get maestro'

# --- agent-device MCP registration for Claude Code and Codex, idempotent --
# (Task 8, mirrors Maestro's own two call sites above exactly): same scope
# rule (Claude Code at user scope, Codex with no scope flag) and same
# gating (command -v agent-device, "mcp get" idempotency check).
require "$tmpl" 'claude mcp add -s user agent-device -- agent-device mcp'
forbid "$tmpl" 'claude mcp add agent-device -- agent-device mcp'
require "$tmpl" 'codex mcp add agent-device -- agent-device mcp'
require "$tmpl" 'claude mcp get agent-device'
require "$tmpl" 'codex mcp get agent-device'

# --- WSL: the ADB bridge to the Windows ADB server (Task 5) ---------------
# install_mobile_dev() itself only prints a heads-up, gated on $isWsl like
# everything else in this file - the actual export lives in dot_zshrc,
# never in a run_onchange script (docs/invariants.md #3: a run_onchange
# script must never write to a file chezmoi itself owns, and dot_zshrc is
# applied byte-for-byte on every machine).
require "$tmpl" 'ADB_SERVER_SOCKET'
require "$tmpl" '{{- if $isWsl }}'

zshrc="$repo_root/dot_zshrc"
[ -f "$zshrc" ] || { fail "$zshrc missing"; finish; }

require "$zshrc" 'ADB_SERVER_SOCKET'
# Guarded so a user's own override is never clobbered.
require "$zshrc" '[[ -z "${ADB_SERVER_SOCKET:-}" ]]'
# WSL detection, shell-native (dot_zshrc has no chezmoi template variables).
require "$zshrc" '/proc/version'
require "$zshrc" 'microsoft'
# Mirrored-vs-NAT resolution order: wslinfo first, resolv.conf fallback.
require "$zshrc" 'wslinfo --networking-mode'
require "$zshrc" 'mirrored'
require "$zshrc" '/etc/resolv.conf'
require "$zshrc" 'nameserver'
# Inconclusive detection warns on stderr instead of failing silently.
require "$zshrc" 'could not resolve the Windows host for ADB_SERVER_SOCKET'
# NAT mode resolves via the default route's gateway, NOT resolv.conf's
# nameserver first (final fix round, C2): with DNS tunneling (default on
# current WSL builds) the nameserver is 10.255.255.254, a WSL-side DNS proxy,
# and the bridge silently pointed at nothing.
require "$zshrc" 'ip route show default'

# Executes the real resolver against fixtures (pure function: wslinfo answer,
# route text and a resolv.conf path in, host out).
resolver="$(sed -n '/^_adb_resolve_host() {$/,/^}$/p' "$zshrc")"
if [ -z "$resolver" ]; then
    fail "$zshrc: no _adb_resolve_host() function"
else
    rtmp="$(mktemp -d)"
    printf 'nameserver 10.255.255.254\n' >"$rtmp/tunneled.conf"
    printf '# generated by WSL\nnameserver 172.30.64.1\n' >"$rtmp/legacy.conf"
    resolve() { bash -c "$resolver"$'\n''_adb_resolve_host "$@"' _ "$@"; }
    expect() { # $1 = label, $2 = want, rest = resolver args
        local label="$1" want="$2" got
        shift 2
        got="$(resolve "$@")"
        if [ "$got" = "$want" ]; then pass; else fail "_adb_resolve_host $label: want '$want', got '$got'"; fi
    }
    route='default via 172.21.144.1 dev eth0 proto kernel
172.21.144.0/20 dev eth0 proto kernel scope link src 172.21.152.7'
    expect 'NAT + DNS tunneling must use the default gateway, not the DNS proxy' \
        172.21.144.1 nat "$route" "$rtmp/tunneled.conf"
    expect 'mirrored must use loopback' 127.0.0.1 mirrored "$route" "$rtmp/tunneled.conf"
    expect 'no wslinfo answer must still use the default gateway' 172.21.144.1 '' "$route" "$rtmp/tunneled.conf"
    expect 'no route (no ip) must fall back to resolv.conf' 172.30.64.1 nat '' "$rtmp/legacy.conf"
    expect 'nothing resolvable must print nothing' '' nat '' "$rtmp/missing.conf"
    rm -rf "$rtmp"
fi

# Disabled = no side effects (final fix round, I3): dot_zshrc is applied on
# every machine, so the JDK and ADB blocks are inert unless mobile_dev
# installed Maestro here ($HOME/.local/bin/maestro, install_mobile_dev's
# symlink), alongside their existing no-clobber guards.
require "$zshrc" 'if [[ -x "$HOME/.local/bin/maestro" ]]; then'
require "$zshrc" 'if [[ -z "${ADB_SERVER_SOCKET:-}" ]] && [[ -x "$HOME/.local/bin/maestro" ]]'
if command -v zsh >/dev/null 2>&1; then
    # Execute both blocks under zsh with a HOME that has no Maestro: neither
    # JAVA_HOME, ADB_SERVER_SOCKET nor PATH may change.
    blocks="$(sed -n "/^# JDK (mobile_dev's Maestro CLI/,/^# ZSH completions\$/p" "$zshrc")"
    if [ -z "$blocks" ]; then
        fail "$zshrc: JDK/ADB blocks not found"
    else
        ztmp="$(mktemp -d)"
        got="$(HOME="$ztmp" zsh -fc 'unset JAVA_HOME ADB_SERVER_SOCKET; before="$PATH"; '"$blocks"$'\n''print -r -- "${JAVA_HOME:-}|${ADB_SERVER_SOCKET:-}|$([[ "$PATH" == "$before" ]] && print same)"' 2>/dev/null)"
        if [ "$got" = '||same' ]; then pass; else fail "dot_zshrc JDK/ADB blocks must be inert without Maestro installed (got '$got')"; fi
        rm -rf "$ztmp"
    fi
fi

docs_file="$repo_root/docs/mobile-development.md"
[ -f "$docs_file" ] || { fail "$docs_file missing"; finish; }

require "$docs_file" 'adb -a -P 5037 nodaemon server'
require "$docs_file" 'ADB_SERVER_SOCKET'
require "$docs_file" 'mirrored'
# Task 6 has since landed and filled in the Linux/macOS section; both
# generations of placeholder comment are gone now.
forbid "$docs_file" '<!-- TODO: WSL/Linux/macOS plan Tasks 2-5'
forbid "$docs_file" '<!-- TODO: WSL/Linux/macOS plan Tasks 2 and 6'

# tests/zshrc_startup_contract.sh already runs `zsh -n` + shellcheck on the
# whole file; a quick syntax check here just pins this task's own addition.
if command -v zsh >/dev/null 2>&1; then
    if zsh -n "$zshrc"; then pass; else fail "dot_zshrc has invalid zsh syntax after the ADB bridge addition"; fi
fi

# --- Wiring: the placeholder comment is replaced by a real call -----------
forbid "$tmpl" 'a sibling task (WSL/Windows installer plan) inserts the mobile_dev install call here'
require "$tmpl" 'install_mobile_dev'

# --- Executable: render the real template with mobile_dev+agent_toolkit on
# and confirm the call actually reaches main(), is bash-syntax-valid, and
# that toggling mobile_dev off removes the call (same render-based style as
# tests/mobile_dev_agent_toolkit_dependency_contract.sh's Part D). ----------
if command -v chezmoi >/dev/null 2>&1; then
    groups() { # $1 = mobile_dev bool, $2 = agent_toolkit bool
        printf '{"core":true,"modern_cli":true,"fonts":true,"agent_toolkit":%s,"opencode_cli":true,"opencode_desktop":false,"claude_cli":true,"claude_desktop":false,"chatgpt_cli":true,"chatgpt_desktop":false,"antigravity_cli":true,"antigravity_desktop":false,"remote_access":true,"remote_access_server":true,"guardrail":false,"dev_desktop":true,"vscode_settings":false,"mobile_dev":%s}' "$2" "$1"
    }

    out="$(mktemp -d)/rendered.sh"
    render_to "$out" sh "$(groups true true)"
    grep -Fq 'install_mobile_dev' "$out" || fail "render (mobile_dev=true, agent_toolkit=true): install_mobile_dev call missing"
    if command -v bash >/dev/null 2>&1; then
        bash -n "$out" || fail "rendered installer has invalid bash syntax with mobile_dev=true"
    fi
    pass

    # --- Maestro MCP placement (final fix round, C1/I1/C3): main() calls
    # install_mobile_dev BEFORE install_claude_cli/install_chatgpt_cli, so a
    # registration inside install_mobile_dev() no-ops for good on a fresh
    # machine (claude/codex do not exist yet). Each agent's registration lives
    # in that agent's own install function, after its binary exists.
    fn_body() { # $1 = rendered file, $2 = function name: the top-level body
        sed -n "/^$2() {\$/,/^}\$/p" "$1"
    }
    body="$(fn_body "$out" install_claude_cli)"
    case "$body" in
        *'claude mcp add -s user maestro -- maestro mcp'*) pass ;;
        *) fail "render (mobile_dev=true): install_claude_cli must register Maestro MCP at user scope" ;;
    esac
    case "$body" in
        *'command -v maestro'*) pass ;;
        *) fail "render: install_claude_cli's Maestro registration must be gated on the maestro binary" ;;
    esac
    body="$(fn_body "$out" install_chatgpt_cli)"
    case "$body" in
        *'codex mcp add maestro -- maestro mcp'*) pass ;;
        *) fail "render (mobile_dev=true): install_chatgpt_cli must register Maestro MCP for Codex" ;;
    esac
    case "$body" in
        *'command -v maestro'*) pass ;;
        *) fail "render: install_chatgpt_cli's Maestro registration must be gated on the maestro binary" ;;
    esac

    # --- agent-device MCP placement (Task 8, mirrors Maestro's above): same
    # install_claude_cli/install_chatgpt_cli locations, same gating. ----------
    body="$(fn_body "$out" install_claude_cli)"
    case "$body" in
        *'claude mcp add -s user agent-device -- agent-device mcp'*) pass ;;
        *) fail "render (mobile_dev=true): install_claude_cli must register agent-device MCP at user scope" ;;
    esac
    case "$body" in
        *'command -v agent-device'*) pass ;;
        *) fail "render: install_claude_cli's agent-device registration must be gated on the agent-device binary" ;;
    esac
    body="$(fn_body "$out" install_chatgpt_cli)"
    case "$body" in
        *'codex mcp add agent-device -- agent-device mcp'*) pass ;;
        *) fail "render (mobile_dev=true): install_chatgpt_cli must register agent-device MCP for Codex" ;;
    esac
    case "$body" in
        *'command -v agent-device'*) pass ;;
        *) fail "render: install_chatgpt_cli's agent-device registration must be gated on the agent-device binary" ;;
    esac

    body="$(fn_body "$out" install_mobile_dev)"
    [ -n "$body" ] || fail "render: install_mobile_dev() body not found"
    case "$body" in
        *'mcp add'*) fail "render: install_mobile_dev() must not register MCP itself (it runs before claude/codex exist)" ;;
        *) pass ;;
    esac
    # main() order: the catalog sync (OpenCode/agy) runs after install_mobile_dev
    # and after the OpenCode/agy CLI installs, never inside install_agent_toolkit.
    call_line() { grep -n "^    $2\$" "$1" | head -n1 | cut -d: -f1; }
    l_mobile="$(call_line "$out" install_mobile_dev)"
    l_sync="$(call_line "$out" sync_agent_mcp_catalog)"
    l_oc="$(call_line "$out" install_opencode_cli)"
    l_agy="$(call_line "$out" install_antigravity_cli)"
    if [ -n "$l_mobile" ] && [ -n "$l_sync" ] && [ -n "$l_oc" ] && [ -n "$l_agy" ] \
        && [ "$l_sync" -gt "$l_mobile" ] && [ "$l_sync" -gt "$l_oc" ] && [ "$l_sync" -gt "$l_agy" ]; then
        pass
    else
        fail "render: main() must call sync_agent_mcp_catalog after install_mobile_dev and the OpenCode/agy installs (lines: mobile=$l_mobile sync=$l_sync opencode=$l_oc agy=$l_agy)"
    fi
    case "$(fn_body "$out" install_agent_toolkit)" in
        *'opencode_mcp_sync'*|*'AGY_WANT'*) fail "render: the OpenCode/agy catalog sync must not live inside install_agent_toolkit()" ;;
        *) pass ;;
    esac

    render_to "$out" sh "$(groups false true)"
    if grep -Fq 'maestro -- maestro mcp' "$out"; then
        fail "render (mobile_dev=false): no Maestro MCP registration may render for Claude Code/Codex"
    else
        pass
    fi
    if grep -Fq 'agent-device -- agent-device mcp' "$out"; then
        fail "render (mobile_dev=false): no agent-device MCP registration may render for Claude Code/Codex"
    else
        pass
    fi
    if grep -Fq 'install_mobile_dev$' "$out" || grep -Eq '^\s*install_mobile_dev\s*$' "$out"; then
        fail "render (mobile_dev=false): install_mobile_dev must not be CALLED"
    else
        pass
    fi
    # The function DEFINITION is unconditional (like install_powershell()'s);
    # only the call site is gated.
    grep -Fq 'install_mobile_dev()' "$out" || fail "render (mobile_dev=false): install_mobile_dev() definition must still be present"

    render_to "$out" sh "$(groups true false)"
    grep -Fq 'mobile_dev requires agent_toolkit' "$out" || fail "render (mobile_dev=true, agent_toolkit=false): safety-net warning missing"
    if grep -Eq '^\s*install_mobile_dev\s*$' "$out"; then
        fail "render (agent_toolkit=false): install_mobile_dev must not be called without agent_toolkit"
    else
        pass
    fi

    # --- WSL gating (Task 5): render_to's "sh" platform is always native
    # Linux ("6.8.0-generic" - no "microsoft"), so it already proves the ADB
    # bridge heads-up is a true no-op on native Linux/macOS (reused above:
    # groups(true,true)'s render contains no ADB_SERVER_SOCKET at all).
    # Forcing a WSL kernel release through the same render path proves the
    # other half: the heads-up actually appears once $isWsl is true.
    render_to "$out" sh "$(groups true true)"
    if grep -Fq 'WSL detected' "$out"; then
        fail "render (native Linux, mobile_dev=true): ADB bridge heads-up must be a no-op off WSL"
    else
        pass
    fi

    render_wsl_to() { # $1 = outfile, $2 = override JSON - render_to, forced to a WSL kernel release
        command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
        local out="$1" override="$2" scratch config
        scratch="$(mktemp -d "${TMPDIR:-/tmp}/render-wsl-repo-XXXXXX")"
        config="$scratch/empty.toml"
        mkdir -p "$scratch/repo/scripts"
        cp "$repo_root/.chezmoidata.yaml" "$scratch/repo/"
        cp -r "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$scratch/repo/"
        if [ -d "$repo_root/scripts/lib" ]; then
            cp -r "$repo_root/scripts/lib" "$scratch/repo/scripts/"
        fi
        if [ -f "$repo_root/scripts/curated-agent-skills.txt" ]; then
            cp "$repo_root/scripts/curated-agent-skills.txt" "$scratch/repo/scripts/"
        fi
        seed_vscode_config "$config"
        chezmoi execute-template --config "$config" --source "$scratch/repo" \
            --override-data "{\"chezmoi\":{\"os\":\"linux\",\"kernel\":{\"osrelease\":\"5.15.0-microsoft-standard-WSL2\"}},\"packages\":$override}" \
            <"$tmpl" | tr -d '\r' >"$out"
    }

    render_wsl_to "$out" "$(groups true true)"
    if grep -Fq 'WSL detected' "$out"; then
        pass
    else
        fail "render (WSL, mobile_dev=true, agent_toolkit=true): ADB bridge heads-up missing under \$isWsl"
    fi
    if command -v bash >/dev/null 2>&1; then
        bash -n "$out" || fail "WSL render has invalid bash syntax"
    fi
else
    skip "chezmoi not installed"
fi

finish
