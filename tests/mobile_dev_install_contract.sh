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
#
# Task 9 added the Android SDK (install_android_sdk): the full SDK with the
# emulator and a default AVD on native Linux/macOS, platform-tools only under
# WSL, with Google's licenses accepted only after an interactive yes. Those
# checks execute the real rendered functions against stub tools, below.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"

. "$repo_root/tests/lib.sh"

[ -f "$tmpl" ] || { fail "$tmpl missing"; finish; }

# --- Structure: the function exists and is wired at the established gate ---
require "$tmpl" 'install_mobile_dev()'

# --- Maestro: manual pinned+verified install, NOT the vendor curl|bash ----
# The install itself is install_maestro in scripts/lib/agent-skills.sh (executed
# by tests/maestro_install_contract.sh), shared with `dot upgrade`; the template
# renders the pins into the call and passes the run_onchange re-entry command as
# the retry hint, because a failed download is otherwise never retried.
lib="$repo_root/scripts/lib/agent-skills.sh"
forbid "$tmpl" 'get.maestro.mobile.dev'
forbid "$lib" 'get.maestro.mobile.dev'
require "$lib" 'mobile-dev-inc/maestro/releases/download/cli-'
require "$lib" 'maestro CHECKSUM MISMATCH'
require "$lib" '$HOME/.local/opt'
require "$lib" '$HOME/.local/bin/maestro'
# The retry hint is `dot upgrade`: since #359 it installs a missing Maestro by itself (install_maestro
# is shared), so a failed download no longer needs the whole run_onchange installer re-entered.
require "$tmpl" "install_maestro '{{ .versions.maestro_version }}' '{{ .versions.maestro_sha256 }}' 'dot upgrade'"
forbid "$tmpl" "install_maestro '{{ .versions.maestro_version }}' '{{ .versions.maestro_sha256 }}' 'chezmoi state delete"
forbid "$tmpl" 'net_timeout 300 curl -fsSLo "$maestro_tmp'

# --- agent-device: npm global, reusing core's Node, command -v guarded ----
require "$tmpl" 'npm install -g agent-device'
require "$tmpl" 'command -v agent-device'

# --- Standalone JDK 17+: apt + brew branches, JAVA_HOME persisted ----------
# apt: the headless JDK. openjdk-17-jdk pulled libxt-dev and the X11 runtime
# into a WSL box for a CLI-only toolchain (2026-10-11); Maestro, agent-device
# and sdkmanager only need javac/java, which the -headless package ships at
# the same /usr/lib/jvm path the JAVA_HOME lookup already uses.
require "$tmpl" 'openjdk-{{ .versions.jdk_version }}-jdk-headless'
forbid "$tmpl" '"openjdk-{{ .versions.jdk_version }}-jdk"'
require "$tmpl" 'openjdk@{{ .versions.jdk_version }}'
require "$tmpl" 'JAVA_HOME'

# --- scrcpy (Task 10): apt + brew branches, command -v guarded -----------
# apt DOES carry a `scrcpy` package on current Ubuntu (universe repo,
# confirmed live via `apt-cache madison scrcpy` while writing this test) -
# both branches install it, no "apt doesn't have it" case to assert here.
# Quoted literal, like the standalone JDK's own package names right above -
# that is what keeps this install_mobile_dev()-local package name out of
# tests/package_catalog_contract.sh's "no literal apt install bypasses the
# catalog" scan (that scan is for install_apt()'s group-wide catalog
# installs, not install_mobile_dev()'s own conditional, host-gated ones).
require "$tmpl" 'apt install -y "scrcpy"'
require "$tmpl" 'brew install "scrcpy"'
require "$tmpl" 'command -v scrcpy'

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
# A failed registration is never retried by the next `dot up` (run_onchange), so
# every one of the four registrations carries the re-entry command as its retry hint
# (2026-10-11: a killed `claude mcp add` left agent-device unregistered with nothing
# saying how to redo it). They go through mcp_add_quiet (scripts/lib/agent-skills.sh:
# one dotfiles line on success, the CLI's output and the warn on failure -
# tests/mcp_add_quiet_contract.sh executes it).
for who in maestro agent-device; do
    for agent in "'Claude Code'" "'Codex'"; do
        require "$tmpl" "mcp_add_quiet $agent $who 'chezmoi state delete --bucket=entryState --key=\$HOME/install_packages.sh && dot up'"
    done
done

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
# every machine, so the JDK and ADB blocks are inert unless mobile_dev's
# installer ran here. The signal is install_mobile_dev()'s own marker
# (~/.local/state/dotfiles/mobile_dev), NOT Maestro's ~/.local/bin/maestro
# symlink (second final fix round, I-A): that symlink is missing whenever
# Maestro was pre-installed elsewhere or its download failed, while the
# JDK/Android SDK still installed and the WSL heads-up still promised the
# bridge.
require "$zshrc" 'if [[ -f "$HOME/.local/state/dotfiles/mobile_dev" ]]; then'
require "$zshrc" 'if [[ -z "${ADB_SERVER_SOCKET:-}" ]] && [[ -f "$HOME/.local/state/dotfiles/mobile_dev" ]]'
forbid "$zshrc" '[[ -x "$HOME/.local/bin/maestro" ]]'
require "$tmpl" 'touch "$HOME/.local/state/dotfiles/mobile_dev"'
if command -v zsh >/dev/null 2>&1; then
    # Execute both blocks under zsh with a HOME that has no Maestro: neither
    # JAVA_HOME, ADB_SERVER_SOCKET nor PATH may change.
    blocks="$(sed -n "/^# JDK (mobile_dev's Maestro CLI/,/^# ZSH completions\$/p" "$zshrc")"
    if [ -z "$blocks" ]; then
        fail "$zshrc: JDK/ADB blocks not found"
    else
        ztmp="$(mktemp -d)"
        got="$(HOME="$ztmp" zsh -fc 'unset JAVA_HOME ADB_SERVER_SOCKET ANDROID_HOME; before="$PATH"; '"$blocks"$'\n''print -r -- "${JAVA_HOME:-}|${ADB_SERVER_SOCKET:-}|${ANDROID_HOME:-}|$([[ "$PATH" == "$before" ]] && print same)"' 2>/dev/null)"
        if [ "$got" = '|||same' ]; then pass; else fail "dot_zshrc JDK/ADB/Android SDK blocks must be inert without mobile_dev installed (got '$got')"; fi
        # I-A: the marker present but NO Maestro symlink (Maestro pre-installed
        # elsewhere, or its download failed) - both blocks must still activate.
        # /proc/version is swapped for a WSL fixture and wslinfo/ip are stubs,
        # so the ADB block's WSL path runs deterministically on any host.
        mtmp="$(mktemp -d)"
        mkdir -p "$mtmp/home/.local/state/dotfiles" "$mtmp/stubs" "$mtmp/jdk/bin"
        touch "$mtmp/home/.local/state/dotfiles/mobile_dev"
        printf 'Linux version 5.15.0-microsoft-standard-WSL2\n' >"$mtmp/version"
        printf '#!/bin/sh\necho nat\n' >"$mtmp/stubs/wslinfo"
        printf '#!/bin/sh\necho "default via 172.21.144.1 dev eth0 proto kernel"\n' >"$mtmp/stubs/ip"
        chmod +x "$mtmp/stubs/wslinfo" "$mtmp/stubs/ip"
        wsl_blocks="${blocks//\/proc\/version/$mtmp/version}"
        got="$(HOME="$mtmp/home" PATH="$mtmp/stubs:$PATH" zsh -fc 'unset ADB_SERVER_SOCKET ANDROID_HOME; export JAVA_HOME="$1"; before="$PATH"; '"$wsl_blocks"$'\n''print -r -- "${ADB_SERVER_SOCKET:-}|${PATH%%:*}"' _ "$mtmp/jdk" 2>/dev/null)"
        [ -e "$mtmp/home/.local/bin/maestro" ] && fail "test setup: the marker-only HOME must have no Maestro symlink"
        if [ "$got" = "tcp:172.21.144.1:5037|$mtmp/jdk/bin" ]; then
            pass
        else
            fail "dot_zshrc: with the mobile_dev marker but no Maestro symlink, ADB_SERVER_SOCKET must be exported and \$JAVA_HOME/bin put on PATH (got '$got')"
        fi
        # ... and the same HOME without the marker stays inert even on WSL.
        rm -f "$mtmp/home/.local/state/dotfiles/mobile_dev"
        got="$(HOME="$mtmp/home" PATH="$mtmp/stubs:$PATH" zsh -fc 'unset ADB_SERVER_SOCKET; export JAVA_HOME="$1"; '"$wsl_blocks"$'\n''print -r -- "${ADB_SERVER_SOCKET:-}|${PATH%%:*}"' _ "$mtmp/jdk" 2>/dev/null)"
        if [ "$got" = "|$mtmp/stubs" ]; then pass; else fail "dot_zshrc: without the mobile_dev marker the JDK/ADB blocks must stay inert on WSL (got '$got')"; fi
        rm -rf "$mtmp"
        # Android SDK block (Task 9): with the installer's SDK present it
        # exports ANDROID_HOME and APPENDS the tool dirs that exist (an adb
        # already on PATH keeps precedence) ...
        sdk_dir="$ztmp/.local/opt/android-sdk"
        mkdir -p "$sdk_dir/platform-tools" "$sdk_dir/cmdline-tools/latest/bin"
        got="$(HOME="$ztmp" zsh -fc 'unset ANDROID_HOME; before="$PATH"; '"$blocks"$'\n''print -r -- "$ANDROID_HOME|${PATH#"$before"}"' 2>/dev/null)"
        if [ "$got" = "$sdk_dir|:$sdk_dir/platform-tools:$sdk_dir/cmdline-tools/latest/bin" ]; then
            pass
        else
            fail "dot_zshrc Android SDK block: expected ANDROID_HOME=$sdk_dir and platform-tools + cmdline-tools appended to PATH (got '$got')"
        fi
        # ... and never re-points an ANDROID_HOME the user set for their own SDK.
        got="$(HOME="$ztmp" zsh -fc 'export ANDROID_HOME=/opt/my-sdk; before="$PATH"; '"$blocks"$'\n''print -r -- "$ANDROID_HOME|$([[ "$PATH" == "$before" ]] && print same)"' 2>/dev/null)"
        if [ "$got" = '/opt/my-sdk|same' ]; then pass; else fail "dot_zshrc Android SDK block must leave a user's own ANDROID_HOME and PATH alone (got '$got')"; fi
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
# Task 9 closed both "Known gap" notes (no WSL adb client; no SDK/emulator on
# native Linux/macOS); the docs now describe what is installed instead.
forbid "$docs_file" '**Known gap:** this plan does not install an `adb` client inside WSL'
forbid "$docs_file" '**Known gap:** the Android SDK command-line tools'
require "$docs_file" '`mobile_dev_pixel`'
# shellcheck disable=SC2088  # literal ~ assertion: docs must reference the tilde form
require "$docs_file" '~/.local/opt/android-sdk'
require "$docs_file" 'chezmoi state delete --bucket=entryState --key=$HOME/install_packages.sh && dot up'

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

    # --- Android SDK (Task 9): WSL gets the adb client only, native gets
    # the full SDK. Asserted on the call site each render emits. -----------
    if grep -Eq '^    install_android_sdk adb \|\| warn' "$out" && ! grep -Eq '^    install_android_sdk full' "$out"; then
        pass
    else
        fail "render (WSL): install_mobile_dev must call 'install_android_sdk adb' (platform-tools only), never 'full'"
    fi
    # $isDevcontainer reads the DEVCONTAINER/REMOTE_CONTAINERS env vars at
    # render time (not override-data) - unset them so this "native Linux"
    # render is never accidentally mistaken for a devcontainer one when the
    # suite itself runs inside one (tests/mobile_dev_agent_toolkit_dependency_contract.sh's
    # own render_tmpl_interactive masks the same two vars the same way).
    sdk_render="$(mktemp -d)/linux.sh"
    ( unset DEVCONTAINER REMOTE_CONTAINERS; render_to "$sdk_render" sh "$(groups true true)" )
    if grep -Eq '^    install_android_sdk full \|\| warn' "$sdk_render" && ! grep -Eq '^    install_android_sdk adb' "$sdk_render"; then
        pass
    else
        fail "render (native Linux): install_mobile_dev must call 'install_android_sdk full', never 'adb'"
    fi

    # Devcontainers get neither mode (#336: no GUI/emulator in a container).
    # $isDevcontainer IS forceable via the DEVCONTAINER env var at render
    # time (tests/mobile_dev_flag_contract.sh's own devcontainer render does
    # exactly this) - a real executable render, not a structural grep.
    devc_render="$(mktemp -d)/devcontainer.sh"
    DEVCONTAINER=true render_to "$devc_render" sh "$(groups true true)"
    if grep -Fq 'Android SDK/emulator skipped (no GUI/emulator in a devcontainer)' "$devc_render" \
        && ! grep -Eq '^    install_android_sdk (full|adb) \|\| warn' "$devc_render"; then
        pass
    else
        fail "render (devcontainer): install_android_sdk must not be called (full or adb) - only the skip message"
    fi

    # --- scrcpy (Task 10): host-only ($isHost), same reasoning and render
    # pattern as the Android SDK checks directly above - $out still holds
    # the WSL render from render_wsl_to, sdk_render the native Linux one,
    # devc_render the devcontainer one. scrcpy's install must run only on
    # the native Linux render, never under WSL or in a devcontainer.
    if grep -Fq 'command -v scrcpy' "$out"; then
        fail "render (WSL): scrcpy install must not run under \$isHost=false (WSL)"
    else
        pass
    fi
    if grep -Fq 'command -v scrcpy' "$sdk_render"; then
        pass
    else
        fail "render (native Linux): scrcpy install must run under \$isHost=true"
    fi
    if grep -Fq 'command -v scrcpy' "$devc_render"; then
        fail "render (devcontainer): scrcpy install must not run under \$isHost=false (devcontainer)"
    else
        pass
    fi
    # I-A (second final fix round): execute the REAL rendered
    # install_mobile_dev() with Maestro and agent-device already on PATH
    # (a prior manual install - the installer skips both, so its own
    # ~/.local/bin/maestro symlink is never created). It must still write
    # the ~/.local/state/dotfiles/mobile_dev marker dot_zshrc gates on.
    mk="$(mktemp -d)"
    mkdir -p "$mk/home" "$mk/stubs"
    for stub in maestro agent-device npm; do
        printf '#!/bin/sh\nexit 0\n' >"$mk/stubs/$stub"
        chmod +x "$mk/stubs/$stub"
    done
    mk_fns='info() { :; }; success() { :; }; warn() { printf "warn: %s\n" "$1" >&2; }; install_android_sdk() { return 0; }; android_sdk_ask_licenses() { return 0; }'$'\n'
    # install_maestro comes from the included library (scripts/lib/agent-skills.sh)
    # and is part of what runs here: a Maestro already on PATH makes it a no-op.
    mk_fns+="$(fn_body "$sdk_render" install_maestro)"$'\n'
    mk_fns+="$(fn_body "$sdk_render" install_mobile_dev)"
    got="$(HOME="$mk/home" PATH="$mk/stubs:$PATH" PKG_MANAGER=none \
        bash -c 'set -euo pipefail; '"$mk_fns"$'\n''install_mobile_dev; echo rc=0' 2>&1)"
    case "$got" in *rc=0*) pass ;; *) fail "install_mobile_dev (Maestro pre-installed): did not complete (output: $got)" ;; esac
    if [ -f "$mk/home/.local/state/dotfiles/mobile_dev" ] && [ ! -e "$mk/home/.local/bin/maestro" ]; then
        pass
    else
        fail "install_mobile_dev (Maestro pre-installed): must write ~/.local/state/dotfiles/mobile_dev even though it lays down no Maestro symlink"
    fi
    rm -rf "$mk"
    # Licenses first (2026-10-11: the question sat behind the JDK, Maestro,
    # agent-device and command-line-tools downloads and waited 41 minutes for an
    # operator who had walked away; the timing summary then booked that wait as
    # "agent toolkit 54m03s"). Executes the REAL rendered install_mobile_dev()
    # with a Maestro download that fails fast (the first download it reaches),
    # install_android_sdk replaced by a probe of the answer it is handed, and the
    # timing helpers replaced by probes.
    lf="$(mktemp -d)"
    mkdir -p "$lf/home" "$lf/stubs"
    for stub in agent-device npm; do
        printf '#!/bin/sh\nexit 0\n' >"$lf/stubs/$stub"
        chmod +x "$lf/stubs/$stub"
    done
    printf '#!/bin/sh\necho "curl $*"\nexit 28\n' >"$lf/stubs/curl"
    chmod +x "$lf/stubs/curl"
    lf_fns='info() { printf "info: %s\n" "$1"; }; success() { :; }; warn() { printf "warn: %s\n" "$1" >&2; }; sha256_cmd() { echo sha256sum; }'
    lf_fns+='; android_sdk_interactive() { return "${LF_INTERACTIVE:-0}"; }; dot_timing_wait() { echo "timing-wait:$1"; }; dot_timing_resume() { echo "timing-resume"; }'
    lf_fns+='; install_android_sdk() { echo "install_android_sdk $1 licenses=${ANDROID_LICENSES:-unset}"; }'$'\n'
    for fn in install_maestro android_sdk_abi android_sdk_root android_sdk_wanted android_sdk_ask_licenses install_mobile_dev; do
        body="$(fn_body "$sdk_render" "$fn")"
        [ -n "$body" ] || fail "render: $fn() not found"
        lf_fns+="$body"$'\n'
    done
    # PATH is controlled: the host's own Maestro (~/.local/bin where `dot up` installed it) would
    # make the rendered install_maestro skip its download, and the first curl line never comes.
    run_lf() { # $1 = answer on stdin, $2 = interactive (0 yes / 1 no)
        printf '%s\n' "$1" | env -u ANDROID_HOME -u ANDROID_SDK_ROOT LF_INTERACTIVE="$2" HOME="$lf/home" PATH="$lf/stubs:/usr/bin:/bin" PKG_MANAGER=none \
            bash -c 'set -euo pipefail; '"$lf_fns"$'\n''install_mobile_dev; echo rc=0' 2>&1
    }
    # `read -p` shows its prompt only on a terminal, so the question is located by the
    # info line that precedes it.
    line_of() { { printf '%s\n' "$1" | grep -n -F -- "$2" || true; } | head -n1 | cut -d: -f1; }
    got="$(run_lf y 0)"
    case "$got" in *rc=0*) pass ;; *) fail "licenses-first (y): did not complete (output: $got)" ;; esac
    l_prompt="$(line_of "$got" 'Android SDK licenses accepted to download')"
    l_curl="$(line_of "$got" 'curl ')"
    l_wait="$(line_of "$got" 'timing-wait:Android licenses')"
    l_resume="$(line_of "$got" 'timing-resume')"
    if [ -n "$l_prompt" ] && [ -n "$l_curl" ] && [ "$l_prompt" -lt "$l_curl" ]; then
        pass
    else
        fail "licenses-first (y): the license question must come before the first download (prompt line: ${l_prompt:-none}, curl line: ${l_curl:-none}; output: $got)"
    fi
    if [ -n "$l_wait" ] && [ -n "$l_resume" ] && [ "$l_prompt" -lt "$l_wait" ] && [ "$l_wait" -lt "$l_resume" ] && [ "$l_resume" -lt "$l_curl" ]; then
        pass
    else
        fail "licenses-first (y): the wait must be timed as its own 'Android licenses' section around the prompt (output: $got)"
    fi
    case "$got" in *'install_android_sdk full licenses=y'*) pass ;; *) fail "licenses-first (y): install_android_sdk must receive the yes (output: $got)" ;; esac
    got="$(run_lf n 0)"
    case "$got" in *'install_android_sdk full licenses=n'*) pass ;; *) fail "licenses-first (n): install_android_sdk must receive the no (output: $got)" ;; esac
    got="$(run_lf '' 1)"
    case "$got" in
        *'Android SDK licenses accepted to download'*) fail "licenses-first (non-interactive): must not prompt (output: $got)" ;;
        *'install_android_sdk full licenses=unset'*) pass ;;
        *) fail "licenses-first (non-interactive): install_android_sdk must still run, with no answer (output: $got)" ;;
    esac
    # Nothing to ask when everything is already there: no prompt, no wait section.
    mkdir -p "$lf/home/.local/opt/android-sdk/platform-tools" "$lf/home/.local/opt/android-sdk/emulator" \
        "$lf/home/.local/opt/android-sdk/system-images/android-34/default/$(uname -m | sed 's/aarch64/arm64-v8a/; s/arm64$/arm64-v8a/; s/x86_64/x86_64/')"
    printf '#!/bin/sh\n' >"$lf/home/.local/opt/android-sdk/platform-tools/adb"; chmod +x "$lf/home/.local/opt/android-sdk/platform-tools/adb"
    printf '#!/bin/sh\n' >"$lf/home/.local/opt/android-sdk/emulator/emulator"; chmod +x "$lf/home/.local/opt/android-sdk/emulator/emulator"
    got="$(run_lf y 0)"
    case "$got" in
        *'Android SDK licenses accepted to download'*|*'timing-wait'*) fail "licenses-first (nothing missing): must ask nothing (output: $got)" ;;
        *) pass ;;
    esac
    rm -rf "$lf"
    for pin in sha256_linux sha256_mac_x86_64 sha256_mac_arm64; do
        want_pin="$(sed -n "s/^  android_commandlinetools_${pin}: \"\\([^\"]*\\)\"\$/\\1/p" "$repo_root/.chezmoidata.yaml")"
        if [ -n "$want_pin" ] && grep -Fq "want='$want_pin'" "$sdk_render"; then
            pass
        else
            fail "render: the android_commandlinetools_${pin} pin must render into the installer"
        fi
    done

    # Executes the REAL rendered functions (install_android_sdk and its
    # helpers) against stub curl/uname and a fixture command-line-tools zip
    # whose sdkmanager/avdmanager log what they are asked to do. PATH holds
    # only the stubs plus symlinks to the few real tools the code needs, so
    # a host's own adb/sdkmanager (GitHub runners ship an Android SDK) never
    # leaks in. The pins are swapped for the fixture zip's digest; the
    # mismatch scenario keeps the real pins.
    # The logging helpers are one-liners over color variables, so they are
    # stubbed; everything the SDK logic itself runs is the rendered code.
    sdk_fns='info() { printf "info: %s\n" "$1"; }; success() { printf "ok: %s\n" "$1"; }; warn() { printf "warn: %s\n" "$1" >&2; }; error() { printf "error: %s\n" "$1" >&2; }'$'\n'
    for fn in net_timeout _net_timeout_report sha256_cmd android_sdk_interactive android_sdk_abi android_sdk_root android_sdk_wanted android_sdkmanager android_cmdline_tools_install install_android_sdk; do
        body="$(fn_body "$sdk_render" "$fn")"
        if [ -z "$body" ]; then fail "render: $fn() not found"; fi
        sdk_fns+="$body"$'\n'
    done
    st="$(mktemp -d)"
    mkdir -p "$st/bin" "$st/fixture/cmdline-tools/bin"
    bash_bin="$(command -v bash)"
    for tool in mkdir rm mv cut mktemp unzip sha256sum shasum timeout gtimeout id perl cat grep; do
        tp="$(command -v "$tool" 2>/dev/null || true)"
        [ -n "$tp" ] && ln -s "$tp" "$st/bin/$tool"
    done
    cat >"$st/bin/uname" <<EOF
#!$bash_bin
case "\$1" in -s) echo "\$FAKE_OS" ;; -m) echo "\$FAKE_ARCH" ;; *) echo "\$FAKE_OS" ;; esac
EOF
    cat >"$st/bin/curl" <<EOF
#!$bash_bin
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in -fsSLo|-o) out="\$2"; shift 2 ;; -*) shift ;; *) echo "curl \$1" >>"\$SDK_LOG"; shift ;; esac
done
exec cat "\$FIXTURE_ZIP" >"\$out"
EOF
    # sdkmanager: logs its arguments; --licenses counts the y answers it
    # was fed; a package list lays down what that package would.
    cat >"$st/fixture/cmdline-tools/bin/sdkmanager" <<EOF
#!$bash_bin
sdk="\${0%/cmdline-tools/latest/bin/sdkmanager}"
echo "WARNING: The SDK Manager CLI tool (sdkmanager) is deprecated. Use Android CLI instead." >&2
echo "The 'android' binary can also be found in the cmdline-tools directory, and 'android sdk' is the replacement for 'sdkmanager'." >&2
echo "To learn more about the Android CLI and how to use it, see the documentation (https://d.android.com/tools/agents/android-cli)" >&2
echo "" >&2
if [ "\$1" = --licenses ]; then
    n=0; while IFS= read -r line; do [ "\$line" = y ] && n=\$((n + 1)); done
    echo "sdkmanager --licenses (fed \$n y)" >>"\$SDK_LOG"
    exit 0
fi
echo "sdkmanager \$*" >>"\$SDK_LOG"
for p in "\$@"; do
    case "\$p" in
        platform-tools) /bin/mkdir -p "\$sdk/platform-tools"; printf '#!$bash_bin\necho "Android Debug Bridge version 1.0.41"\n' >"\$sdk/platform-tools/adb"; /bin/chmod +x "\$sdk/platform-tools/adb" ;;
        emulator) /bin/mkdir -p "\$sdk/emulator"; printf '#!$bash_bin\n' >"\$sdk/emulator/emulator"; /bin/chmod +x "\$sdk/emulator/emulator" ;;
        "system-images;"*) IFS=';' read -r _ api tag abi <<<"\$p"; /bin/mkdir -p "\$sdk/system-images/\$api/\$tag/\$abi" ;;
    esac
done
EOF
    cat >"$st/fixture/cmdline-tools/bin/avdmanager" <<EOF
#!$bash_bin
echo "avdmanager \$*" >>"\$SDK_LOG"
read -r answer || true
[ "\$answer" = no ] || echo "avdmanager: custom hardware profile question not answered 'no'" >>"\$SDK_LOG"
name=""; while [ \$# -gt 0 ]; do [ "\$1" = -n ] && name="\$2"; shift; done
/bin/mkdir -p "\$HOME/.android/avd/\$name.avd"
EOF
    chmod +x "$st/bin/uname" "$st/bin/curl" "$st/fixture/cmdline-tools/bin/sdkmanager" "$st/fixture/cmdline-tools/bin/avdmanager"
    (cd "$st/fixture" && zip -qr "$st/fixture.zip" cmdline-tools) || fail "could not build the command-line tools fixture zip"
    fixture_sha="$(sha256sum "$st/fixture.zip" 2>/dev/null || shasum -a 256 "$st/fixture.zip")"
    fixture_sha="${fixture_sha%% *}"
    swapped_fns="$(printf '%s' "$sdk_fns" | sed -E "s/^( *want=')[0-9a-f]{64}'\$/\\1$fixture_sha'/")"

    # run_sdk HOME FNS MODE ANSWER INTERACTIVE OS ARCH [ANDROID_HOME]
    #   Runs `install_android_sdk MODE || warn ...` under set -euo pipefail,
    #   as main() does. INTERACTIVE=yes overrides android_sdk_interactive
    #   (no real terminal in a test) and feeds ANSWER on stdin; =no keeps the
    #   real check with stdin from /dev/null. Prints the run's combined output.
    run_sdk() {
        local home="$1" fns="$2" mode="$3" answer="$4" interactive="$5" os="$6" arch="$7" ahome="${8:-}"
        local override=""
        [ "$interactive" = yes ] && override='android_sdk_interactive() { return 0; }'
        if [ "$interactive" = yes ]; then
            printf '%s\n' "$answer" | env -i HOME="$home" PATH="$st/bin" SDK_LOG="$home/sdk.log" FIXTURE_ZIP="$st/fixture.zip" \
                FAKE_OS="$os" FAKE_ARCH="$arch" ${ahome:+ANDROID_HOME="$ahome"} ${ANDROID_LICENSES:+ANDROID_LICENSES="$ANDROID_LICENSES"} \
                "$bash_bin" -c 'set -euo pipefail; '"$fns"$'\n'"$override"$'\n''install_android_sdk "$1" || warn "install_android_sdk failed"; echo "rc=0"' _ "$mode" 2>&1
        else
            env -i HOME="$home" PATH="$st/bin" SDK_LOG="$home/sdk.log" FIXTURE_ZIP="$st/fixture.zip" \
                FAKE_OS="$os" FAKE_ARCH="$arch" ${ahome:+ANDROID_HOME="$ahome"} ${ANDROID_LICENSES:+ANDROID_LICENSES="$ANDROID_LICENSES"} \
                "$bash_bin" -c 'set -euo pipefail; '"$fns"$'\n''install_android_sdk "$1" || warn "install_android_sdk failed"; echo "rc=0"' _ "$mode" </dev/null 2>&1
        fi
    }
    log_has() { grep -Fxq -- "$2" "$1/sdk.log" 2>/dev/null; }
    own=".local/opt/android-sdk"

    # A. Native Linux, a person answers y: pinned zip, the cmdline-tools/latest
    #    layout, licenses fed, platform-tools + emulator + the android-34
    #    image in ONE sdkmanager call, then the pixel_6 AVD.
    h="$st/a"; mkdir -p "$h"
    got="$(run_sdk "$h" "$swapped_fns" full y yes Linux x86_64)"
    case "$got" in *rc=0*) pass ;; *) fail "SDK full/yes: did not complete (output: $got)" ;; esac
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    log_has "$h" 'curl https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip' && pass \
        || fail "SDK full/yes: must download the pinned Linux command-line tools zip"
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    [ -x "$h/$own/cmdline-tools/latest/bin/sdkmanager" ] && [ ! -e "$h/$own/cmdline-tools/.incoming" ] && pass \
        || fail "SDK full/yes: sdkmanager must land at ~/$own/cmdline-tools/latest/bin with no staging dir left"
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    log_has "$h" 'sdkmanager --licenses (fed 50 y)' && pass || fail "SDK full/yes: licenses not accepted after the person's y"
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    log_has "$h" 'sdkmanager platform-tools emulator system-images;android-34;default;x86_64' && pass \
        || fail "SDK full/yes: expected 'sdkmanager platform-tools emulator system-images;android-34;default;x86_64'"
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    log_has "$h" 'avdmanager create avd -n mobile_dev_pixel -k system-images;android-34;default;x86_64 -d pixel_6' && pass \
        || fail "SDK full/yes: expected the mobile_dev_pixel AVD on android-34/pixel_6"
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    grep -Fq "custom hardware profile question" "$h/sdk.log" && fail "SDK full/yes: avdmanager's hardware-profile question must be answered 'no'" || pass
    # Google's "sdkmanager is deprecated, use Android CLI" banner prints on every
    # sdkmanager call (twice per dot up, 2026-10-11); it is filtered, errors are not.
    if printf '%s' "$got" | grep -q 'sdkmanager) is deprecated'; then
        fail "SDK full/yes: sdkmanager's deprecation banner must be filtered from the terminal (output: $got)"
    else
        pass
    fi

    # B. Idempotent: a second run downloads nothing and asks nothing.
    : >"$h/sdk.log"
    got="$(run_sdk "$h" "$swapped_fns" full n yes Linux x86_64)"
    if [ ! -s "$h/sdk.log" ]; then pass; else fail "SDK full rerun: must be a no-op once everything is present (log: $(cat "$h/sdk.log"))"; fi

    # C. Non-interactive: the command-line tools still install (no license
    #    needed), but licenses and everything behind them are skipped with a
    #    warning naming the re-run - never accepted, never a hang.
    h="$st/c"; mkdir -p "$h"
    got="$(run_sdk "$h" "$swapped_fns" full '' no Linux x86_64)"
    case "$got" in *rc=0*) pass ;; *) fail "SDK non-interactive: did not complete (output: $got)" ;; esac
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    [ -x "$h/$own/cmdline-tools/latest/bin/sdkmanager" ] && pass || fail "SDK non-interactive: command-line tools must still install"
    if grep -Eq '^(sdkmanager|avdmanager)' "$h/sdk.log"; then
        fail "SDK non-interactive: sdkmanager/avdmanager must not run (log: $(cat "$h/sdk.log"))"
    else
        pass
    fi
    case "$got" in
        *"not accepting Google's Android SDK licenses on your behalf"*'chezmoi state delete --bucket=entryState --key=$HOME/install_packages.sh'*) pass ;;
        *) fail "SDK non-interactive: must warn that the licenses were skipped and how to re-run (output: $got)" ;;
    esac

    # D. A person answers n: same as C - nothing behind the licenses runs.
    h="$st/d"; mkdir -p "$h"
    got="$(run_sdk "$h" "$swapped_fns" full n yes Linux x86_64)"
    if grep -Eq '^(sdkmanager|avdmanager)' "$h/sdk.log"; then fail "SDK full/n: nothing may run after a declined prompt"; else pass; fi

    # E. WSL (adb mode): platform-tools only - no emulator, image or AVD.
    h="$st/e"; mkdir -p "$h"
    got="$(run_sdk "$h" "$swapped_fns" adb y yes Linux x86_64)"
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    log_has "$h" 'sdkmanager platform-tools' && pass || fail "SDK adb/yes: expected exactly 'sdkmanager platform-tools'"
    if grep -Eq 'emulator|system-images|^avdmanager' "$h/sdk.log"; then
        fail "SDK adb/yes: the WSL path must never fetch the emulator, a system image, or create an AVD (log: $(cat "$h/sdk.log"))"
    else
        pass
    fi
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    [ -x "$h/$own/platform-tools/adb" ] && pass || fail "SDK adb/yes: adb must land under ~/$own/platform-tools"

    # F. Checksum mismatch (the real pins vs the fixture): nothing installed.
    h="$st/f"; mkdir -p "$h"
    got="$(run_sdk "$h" "$sdk_fns" full y yes Linux x86_64)"
    case "$got" in *'CHECKSUM MISMATCH'*rc=0*) pass ;; *) fail "SDK mismatch: must warn CHECKSUM MISMATCH and continue (output: $got)" ;; esac
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    [ ! -e "$h/$own/cmdline-tools/latest" ] && pass || fail "SDK mismatch: nothing may be extracted from an unverified zip"

    # G. An existing ANDROID_HOME is used in place, never replaced by ours.
    h="$st/g"; mkdir -p "$h/mysdk"
    got="$(run_sdk "$h" "$swapped_fns" full n yes Linux x86_64 "$h/mysdk")"
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    [ -x "$h/mysdk/cmdline-tools/latest/bin/sdkmanager" ] && [ ! -e "$h/$own" ] && pass \
        || fail "SDK existing ANDROID_HOME: tools must go into that SDK, and ~/$own must not be created"

    # J. The licenses were accepted up front (install_mobile_dev asks before any
    #    download and hands the answer over in ANDROID_LICENSES): no second
    #    prompt, and a non-interactive stdin is no obstacle any more.
    h="$st/j"; mkdir -p "$h"
    got="$(ANDROID_LICENSES=y run_sdk "$h" "$swapped_fns" adb '' no Linux x86_64)"
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    log_has "$h" 'sdkmanager --licenses (fed 50 y)' && log_has "$h" 'sdkmanager platform-tools' && pass \
        || fail "SDK ANDROID_LICENSES=y: must accept and download without asking again (log: $(/bin/cat "$h/sdk.log" 2>/dev/null))"
    case "$got" in
        *'Android SDK licenses accepted to download'*) fail "SDK ANDROID_LICENSES=y: must not prompt a second time (output: $got)" ;;
        *) pass ;;
    esac
    # K. ... and a declined answer skips everything behind the licenses, with the re-run hint.
    h="$st/k"; mkdir -p "$h"
    got="$(ANDROID_LICENSES=n run_sdk "$h" "$swapped_fns" adb '' no Linux x86_64)"
    if grep -Eq '^(sdkmanager|avdmanager)' "$h/sdk.log" 2>/dev/null; then fail "SDK ANDROID_LICENSES=n: nothing may run after a declined prompt"; else pass; fi
    case "$got" in
        *'Skipped the Android SDK licenses'*'chezmoi state delete --bucket=entryState --key=$HOME/install_packages.sh'*) pass ;;
        *) fail "SDK ANDROID_LICENSES=n: must say the licenses were skipped and how to re-run (output: $got)" ;;
    esac
    # The package download budget: a multi-GB system image on a slow link
    # (2026-10-11: 300 MB took the whole 300 s Maestro had) is not a 30-minute job.
    require "$tmpl" 'net_timeout 7200 "$sdkmanager"'

    # H. macOS Apple Silicon: the mac_arm64 zip and an arm64-v8a image.
    h="$st/h"; mkdir -p "$h"
    got="$(run_sdk "$h" "$swapped_fns" full y yes Darwin arm64)"
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    log_has "$h" 'curl https://dl.google.com/android/repository/commandlinetools-mac_arm64-15859902_latest.zip' && pass \
        || fail "SDK Darwin arm64: must download the mac_arm64 zip"
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    log_has "$h" 'sdkmanager platform-tools emulator system-images;android-34;default;arm64-v8a' && pass \
        || fail "SDK Darwin arm64: must request the arm64-v8a android-34 image"
    h="$st/i"; mkdir -p "$h"
    got="$(run_sdk "$h" "$swapped_fns" full n yes Darwin x86_64)"
    # shellcheck disable=SC2015  # A && B || { fallback } is the intended shape here
    log_has "$h" 'curl https://dl.google.com/android/repository/commandlinetools-mac_x86_64-15859902_latest.zip' && pass \
        || fail "SDK Darwin x86_64: must download the mac_x86_64 zip"
    rm -rf "$st"
else
    skip "chezmoi not installed"
fi

finish
