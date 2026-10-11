#!/usr/bin/env bash
# scripts/lib/vscode-wsl.sh - the VS Code server fetch a WSL `code` call hides.
#
# Consumers:
#   - run_onchange_install_packages.sh.tmpl: inlined at RENDER time via
#     `{{ include "scripts/lib/vscode-wsl.sh" }}`, called before the extension step.
#   - scripts/dotupgrade.sh: sources this file, called before `code --update-extensions`.
# Template-free plain bash, like agent-skills.sh: both consumers load it byte-for-byte.
# Needs info/warn (agent-skills.sh) and dot_timing_wait/resume (timing.sh), both loaded by
# both consumers; the timing calls are no-ops outside a timed run.
#
# On WSL there is no Linux VS Code. `code` is the Windows client's bin/code, reached through
# interop (Windows PATH entries are on the WSL PATH, and the launcher is an extensionless sh
# script). It hands every CLI call to Remote-WSL's wslCode.sh, which first installs the VS Code
# SERVER for the client's commit under ~/.vscode-server/bin when that folder is missing - which
# it is after every VS Code update on Windows. So the first `code` call after an update downloads
# 200+ MB before it answers. A WSL `dot up` (2026-10-11) sat 22 minutes on "Installing VS Code
# extensions" with nothing on screen: the download ran inside `$(code --list-extensions)` with
# stderr to /dev/null, and the Timings line booked it as "VS Code 22m07s".
#
# The extensions themselves DO belong on the WSL side (Remote-WSL runs workspace extensions
# there; all 24 curated ones were installed there), so the extension step stays. What changes:
# the fetch is announced, runs in the foreground as one `code --version` so Remote-WSL's own
# progress reaches the terminal, and is its own timing section ("VS Code server fetch").
#
# The launcher is recognised by content, not by path (/mnt/c is the usual mount, not the only
# one): COMMIT="<hex>", SERVERDATAFOLDER="..." and the WSL_DISTRO_NAME branch, the three
# things resources/win32/bin/code.sh has and the Linux launcher has not.
# tests/vscode_wsl_server_fetch_contract.sh executes this against fixture launchers.

# vscode_wsl_launcher - prints the path of `code` when it is the Windows client's WSL launcher;
# returns 1 (prints nothing) for a native `code` or none at all.
vscode_wsl_launcher() {
    local launcher
    launcher="$(command -v code 2>/dev/null)" || return 1
    [ -f "$launcher" ] || return 1
    grep -aq 'WSL_DISTRO_NAME' "$launcher" 2>/dev/null || return 1
    grep -aq '^SERVERDATAFOLDER="' "$launcher" 2>/dev/null || return 1
    grep -aq '^COMMIT="[0-9a-f]*"' "$launcher" 2>/dev/null || return 1
    printf '%s\n' "$launcher"
}

# vscode_wsl_server_fetch [retry-hint] - make sure the WSL server for the Windows client's
# commit is installed before the caller's first real `code` call.
#   0  nothing to fetch (server present, native code, or no code), or fetched
#   1  the fetch failed (warned, with the hint): the caller skips its VS Code step this run
#      rather than letting the next `code` call retry the download silently
vscode_wsl_server_fetch() {
    local hint="${1:-re-run dot upgrade}" launcher commit folder rc=0
    launcher="$(vscode_wsl_launcher)" || return 0
    commit="$(sed -n 's/^COMMIT="\([0-9a-f]*\)".*/\1/p' "$launcher" | head -n 1)"
    folder="$(sed -n 's/^SERVERDATAFOLDER="\([^"]*\)".*/\1/p' "$launcher" | head -n 1)"
    [ -n "$commit" ] && [ -n "$folder" ] || return 0
    [ ! -d "$HOME/$folder/bin/$commit" ] || return 0
    info "VS Code was updated on Windows: fetching its WSL server (~200 MB, commit ${commit:0:10}) before the extension step - the progress below is VS Code's own, and a slow link makes this the long step"
    dot_timing_wait 'VS Code server fetch' 2>/dev/null || true
    # One foreground call: wslCode.sh installs the server, then answers. stdin from /dev/null -
    # wslCode.sh reads stdin when it is not a terminal and an argument is "-".
    code --version </dev/null || rc=$?
    dot_timing_resume 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        warn "VS Code server fetch failed (exit $rc) - skipping the VS Code extension step this run ($hint)"
        return 1
    fi
    return 0
}
