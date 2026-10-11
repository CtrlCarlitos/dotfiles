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
        got="$(HOME="$ztmp" zsh -fc 'unset JAVA_HOME ADB_SERVER_SOCKET ANDROID_HOME; before="$PATH"; '"$blocks"$'\n''print -r -- "${JAVA_HOME:-}|${ADB_SERVER_SOCKET:-}|${ANDROID_HOME:-}|$([[ "$PATH" == "$before" ]] && print same)"' 2>/dev/null)"
        if [ "$got" = '|||same' ]; then pass; else fail "dot_zshrc JDK/ADB/Android SDK blocks must be inert without mobile_dev installed (got '$got')"; fi
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
require "$docs_file" '~/.local/opt/android-sdk'
require "$docs_file" 'chezmoi state delete-bucket --bucket=scriptState && dot up'

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
    sdk_render="$(mktemp -d)/linux.sh"
    render_to "$sdk_render" sh "$(groups true true)"
    if grep -Eq '^    install_android_sdk full \|\| warn' "$sdk_render" && ! grep -Eq '^    install_android_sdk adb' "$sdk_render"; then
        pass
    else
        fail "render (native Linux): install_mobile_dev must call 'install_android_sdk full', never 'adb'"
    fi

    # Devcontainers get neither mode (#336: no GUI/emulator in a container).
    # $isDevcontainer is derived from env/`/.dockerenv` at render time, not
    # overridable via --override-data like os/kernel - so this pins the
    # template's own branch structure (a real executable render of the
    # devcontainer path isn't available to this test harness) rather than
    # executing it.
    if grep -Fq '{{- else if $isHost }}' "$tmpl" && grep -Fq 'Android SDK/emulator skipped (no GUI/emulator in a devcontainer)' "$tmpl"; then
        pass
    else
        fail "install_mobile_dev must gate the Android SDK's full/adb modes on \$isHost/\$isWsl, leaving devcontainers with neither"
    fi
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
    for fn in net_timeout sha256_cmd android_sdk_interactive android_cmdline_tools_install install_android_sdk; do
        body="$(fn_body "$sdk_render" "$fn")"
        if [ -z "$body" ]; then fail "render: $fn() not found"; fi
        sdk_fns+="$body"$'\n'
    done
    st="$(mktemp -d)"
    mkdir -p "$st/bin" "$st/fixture/cmdline-tools/bin"
    bash_bin="$(command -v bash)"
    for tool in mkdir rm mv cut mktemp unzip sha256sum shasum timeout gtimeout id perl cat; do
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
                FAKE_OS="$os" FAKE_ARCH="$arch" ${ahome:+ANDROID_HOME="$ahome"} \
                "$bash_bin" -c 'set -euo pipefail; '"$fns"$'\n'"$override"$'\n''install_android_sdk "$1" || warn "install_android_sdk failed"; echo "rc=0"' _ "$mode" 2>&1
        else
            env -i HOME="$home" PATH="$st/bin" SDK_LOG="$home/sdk.log" FIXTURE_ZIP="$st/fixture.zip" \
                FAKE_OS="$os" FAKE_ARCH="$arch" ${ahome:+ANDROID_HOME="$ahome"} \
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
    log_has "$h" 'curl https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip' && pass \
        || fail "SDK full/yes: must download the pinned Linux command-line tools zip"
    [ -x "$h/$own/cmdline-tools/latest/bin/sdkmanager" ] && [ ! -e "$h/$own/cmdline-tools/.incoming" ] && pass \
        || fail "SDK full/yes: sdkmanager must land at ~/$own/cmdline-tools/latest/bin with no staging dir left"
    log_has "$h" 'sdkmanager --licenses (fed 50 y)' && pass || fail "SDK full/yes: licenses not accepted after the person's y"
    log_has "$h" 'sdkmanager platform-tools emulator system-images;android-34;default;x86_64' && pass \
        || fail "SDK full/yes: expected 'sdkmanager platform-tools emulator system-images;android-34;default;x86_64'"
    log_has "$h" 'avdmanager create avd -n mobile_dev_pixel -k system-images;android-34;default;x86_64 -d pixel_6' && pass \
        || fail "SDK full/yes: expected the mobile_dev_pixel AVD on android-34/pixel_6"
    grep -Fq "custom hardware profile question" "$h/sdk.log" && fail "SDK full/yes: avdmanager's hardware-profile question must be answered 'no'" || pass

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
    [ -x "$h/$own/cmdline-tools/latest/bin/sdkmanager" ] && pass || fail "SDK non-interactive: command-line tools must still install"
    if grep -Eq '^(sdkmanager|avdmanager)' "$h/sdk.log"; then
        fail "SDK non-interactive: sdkmanager/avdmanager must not run (log: $(cat "$h/sdk.log"))"
    else
        pass
    fi
    case "$got" in
        *"not accepting Google's Android SDK licenses on your behalf"*'chezmoi state delete-bucket --bucket=scriptState'*) pass ;;
        *) fail "SDK non-interactive: must warn that the licenses were skipped and how to re-run (output: $got)" ;;
    esac

    # D. A person answers n: same as C - nothing behind the licenses runs.
    h="$st/d"; mkdir -p "$h"
    got="$(run_sdk "$h" "$swapped_fns" full n yes Linux x86_64)"
    if grep -Eq '^(sdkmanager|avdmanager)' "$h/sdk.log"; then fail "SDK full/n: nothing may run after a declined prompt"; else pass; fi

    # E. WSL (adb mode): platform-tools only - no emulator, image or AVD.
    h="$st/e"; mkdir -p "$h"
    got="$(run_sdk "$h" "$swapped_fns" adb y yes Linux x86_64)"
    log_has "$h" 'sdkmanager platform-tools' && pass || fail "SDK adb/yes: expected exactly 'sdkmanager platform-tools'"
    if grep -Eq 'emulator|system-images|^avdmanager' "$h/sdk.log"; then
        fail "SDK adb/yes: the WSL path must never fetch the emulator, a system image, or create an AVD (log: $(cat "$h/sdk.log"))"
    else
        pass
    fi
    [ -x "$h/$own/platform-tools/adb" ] && pass || fail "SDK adb/yes: adb must land under ~/$own/platform-tools"

    # F. Checksum mismatch (the real pins vs the fixture): nothing installed.
    h="$st/f"; mkdir -p "$h"
    got="$(run_sdk "$h" "$sdk_fns" full y yes Linux x86_64)"
    case "$got" in *'CHECKSUM MISMATCH'*rc=0*) pass ;; *) fail "SDK mismatch: must warn CHECKSUM MISMATCH and continue (output: $got)" ;; esac
    [ ! -e "$h/$own/cmdline-tools/latest" ] && pass || fail "SDK mismatch: nothing may be extracted from an unverified zip"

    # G. An existing ANDROID_HOME is used in place, never replaced by ours.
    h="$st/g"; mkdir -p "$h/mysdk"
    got="$(run_sdk "$h" "$swapped_fns" full n yes Linux x86_64 "$h/mysdk")"
    [ -x "$h/mysdk/cmdline-tools/latest/bin/sdkmanager" ] && [ ! -e "$h/$own" ] && pass \
        || fail "SDK existing ANDROID_HOME: tools must go into that SDK, and ~/$own must not be created"

    # H. macOS Apple Silicon: the mac_arm64 zip and an arm64-v8a image.
    h="$st/h"; mkdir -p "$h"
    got="$(run_sdk "$h" "$swapped_fns" full y yes Darwin arm64)"
    log_has "$h" 'curl https://dl.google.com/android/repository/commandlinetools-mac_arm64-15859902_latest.zip' && pass \
        || fail "SDK Darwin arm64: must download the mac_arm64 zip"
    log_has "$h" 'sdkmanager platform-tools emulator system-images;android-34;default;arm64-v8a' && pass \
        || fail "SDK Darwin arm64: must request the arm64-v8a android-34 image"
    h="$st/i"; mkdir -p "$h"
    got="$(run_sdk "$h" "$swapped_fns" full n yes Darwin x86_64)"
    log_has "$h" 'curl https://dl.google.com/android/repository/commandlinetools-mac_x86_64-15859902_latest.zip' && pass \
        || fail "SDK Darwin x86_64: must download the mac_x86_64 zip"
    rm -rf "$st"
else
    skip "chezmoi not installed"
fi

finish
