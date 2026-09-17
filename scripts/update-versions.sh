#!/usr/bin/env bash

set -e

echo "Starting Auto-Update Script..."

# 1. Update Chezmoi Version
echo "Fetching latest Chezmoi version..."
LATEST_CHEZMOI=$(curl -s "https://api.github.com/repos/twpayne/chezmoi/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
if [ -n "$LATEST_CHEZMOI" ]; then
    echo "Latest Chezmoi: $LATEST_CHEZMOI"
    # Update in .chezmoi-version
    echo "$LATEST_CHEZMOI" > .chezmoi-version
else
    echo "Warning: Could not fetch Chezmoi version."
fi

# 2. Update Antigravity 2.0 hub pin (re-added 2026-09-13 - supersedes the
# 2026-09-11 removal: the hub desktop app is back, pinned for macOS+Linux in
# run_onchange_install_packages.sh.tmpl).
echo "Fetching latest Antigravity hub version..."
# --compressed is REQUIRED: this page is served gzip-encoded, and a plain
# `curl -sL` returns raw compressed bytes - every grep silently matches
# nothing and this leg no-ops (that exact bug once left the old pin stale
# for the script's entire life before it was diagnosed).
#
# Channel-matching matters: the download page mixes URLs from TWO release
# channels - the stable IDE channel (edgedl.me.gvt1.com/.../stable/<ver>/...)
# and the 2.0 hub channel (.../antigravity-hub/<ver>/...). A bare
# "[0-9]+\.[0-9]+\.[0-9]+-[0-9]+" over the whole page historically grabbed
# the IDE channel's number, producing a "hub" version whose assets 404 (the
# wrong-channel bug). Anchoring the pattern to the antigravity-hub/ path
# means only the hub channel's version can be derived.
LATEST=$(curl -sL --compressed https://antigravity.google/download \
    | grep -oE 'antigravity-hub/[0-9]+\.[0-9]+\.[0-9]+-[0-9]+/' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' \
    | head -1)

if [ -n "$LATEST" ]; then
    echo "Latest Antigravity hub: $LATEST"

    # Validate before writing: a scraped number alone has fooled this script
    # before (wrong channel -> nonexistent version -> broken install much
    # later). Confirm both pinned assets actually resolve before touching
    # the template.
    check_url() {
        local url="$1"
        local status
        status=$(curl -sL -o /dev/null -w "%{http_code}" "$url")
        [ "$status" = "200" ]
    }

    AG_HUB_BASE="https://storage.googleapis.com/antigravity-public/antigravity-hub/${LATEST}"

    URLS_OK=true
    for pair in "macOS arm64:${AG_HUB_BASE}/darwin-arm/Antigravity.dmg" "Linux x64:${AG_HUB_BASE}/linux-x64/Antigravity.tar.gz"; do
        label="${pair%%:*}"
        url="${pair#*:}"
        if check_url "$url"; then
            echo "  OK: $label -> $url"
        else
            echo "  Warning: $label download URL did not return 200: $url"
            URLS_OK=false
        fi
    done

    if [ "$URLS_OK" = true ]; then
        # Rewrite the pin in the sh template. Windows needs nothing here: it
        # installs Antigravity via Chocolatey, which floats to whatever the
        # community package carries - there is no pin in the ps1 template to
        # bump.
        sed -i -E "s/ANTIGRAVITY_HUB_VERSION=\"[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\"/ANTIGRAVITY_HUB_VERSION=\"$LATEST\"/" run_onchange_install_packages.sh.tmpl
    else
        echo "Warning: Not updating Antigravity hub version - one or more asset URLs are broken."
        echo "  This usually means Google changed the hub channel layout; the URL"
        echo "  templates in run_onchange_install_packages.sh.tmpl need a manual look."
    fi
else
    echo "Warning: Could not derive Antigravity hub version from the download page - leaving pin unchanged."
fi

# 3. agent-guardrails stays pinned to the reviewed release in the installer
# templates and manual updaters. Never replace that pin with GitHub's latest.

# Note: Node.js is not dynamically bumped here. It is pinned to 24.x in
# three installers by hand - run_onchange_install_packages.ps1.tmpl (choco
# nodejs --version), the NodeSource setup_24.x script (Linux), and brew
# node@24 (macOS) - bump those together when moving majors.

echo "Version updates complete."
