#!/usr/bin/env bash

set -e

# Run from the repo root no matter where the script is invoked from.
cd "$(dirname "$0")/.."

echo "Starting Auto-Update Script..."

# 1. Update Chezmoi Version
echo "Fetching latest Chezmoi version..."
LATEST_CHEZMOI=$(curl -s "https://api.github.com/repos/twpayne/chezmoi/releases/latest" | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4)
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
        # Portable in-place edit (BSD sed has no `sed -i` without an arg):
        # write to a temp file, then mv over the original.
        tmp_tmpl="$(mktemp)"
        sed -E "s/ANTIGRAVITY_HUB_VERSION=\"[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\"/ANTIGRAVITY_HUB_VERSION=\"$LATEST\"/" run_onchange_install_packages.sh.tmpl > "$tmp_tmpl"
        mv "$tmp_tmpl" run_onchange_install_packages.sh.tmpl
    else
        echo "Warning: Not updating Antigravity hub version - one or more asset URLs are broken."
        echo "  This usually means Google changed the hub channel layout; the URL"
        echo "  templates in run_onchange_install_packages.sh.tmpl need a manual look."
    fi
else
    echo "Warning: Could not derive Antigravity hub version from the download page - leaving pin unchanged."
fi

# 3. Refresh .chezmoiexternal.toml pins: resolve each external repo's
# default-branch SHA (git ls-remote - no API auth), rewrite the
# /archive/<sha>.tar.gz URL, download the archive once, and pin its sha256 so
# every `chezmoi apply` verifies byte-identical content. The weekly updater
# PR carries the fresh pins through CI like every other version bump.
refresh_external() {
    repo="$1"
    sha="$(git ls-remote "https://github.com/${repo}" HEAD 2>/dev/null | cut -f1)"
    if [ -z "$sha" ]; then
        echo "  Warning: could not resolve HEAD for $repo - pin left unchanged."
        return 0
    fi
    sum=""
    if [ -n "$SHA_CMD" ]; then
        tarball="$(mktemp)"
        if curl -fsSL "https://github.com/${repo}/archive/${sha}.tar.gz" -o "$tarball"; then
            sum="$($SHA_CMD "$tarball" | cut -d' ' -f1)"
        else
            echo "  Warning: could not download ${repo}@${sha} - pin left unchanged."
            rm -f "$tarball"
            return 0
        fi
        rm -f "$tarball"
    fi
    tmp_file="$(mktemp)"
    # The archive URL is the version: point it at the new HEAD SHA.
    sed -E "s|(github\.com/${repo}/archive/)[0-9a-f]{40}\.tar\.gz|\1${sha}.tar.gz|" "$EXTERNALS" > "$tmp_file"
    mv "$tmp_file" "$EXTERNALS"
    if [ -n "$sum" ]; then
        # One entry per repo: re-pin the checksum inside the entry whose URL
        # carries this repo (the checksum line follows the url line).
        tmp_file="$(mktemp)"
        awk -v repo="$repo" -v sum="$sum" '
            index($0, "github.com/" repo "/archive/") { in_repo = 1 }
            in_repo && /checksum\.sha256/ && !done { sub(/"[0-9a-f]*"/, "\"" sum "\""); done = 1 }
            { print }
        ' "$EXTERNALS" > "$tmp_file"
        mv "$tmp_file" "$EXTERNALS"
        # An entry whose URL moved but which carries no checksum line would
        # silently skip chezmoi's verification - keep that visible.
        if ! grep -A5 -E "github\.com/${repo}/archive" "$EXTERNALS" | grep -q 'checksum\.sha256'; then
            echo "  Warning: $repo entry has no checksum.sha256 line - verification skipped by chezmoi."
        fi
    else
        echo "  Warning: refreshed URL for $repo without checksum (no sha256 tool) - re-run on a host with sha256sum/shasum."
    fi
    echo "  $repo -> $(printf '%s' "$sha" | cut -c1-12)"
}

EXTERNALS=".chezmoiexternal.toml"
if [ ! -f "$EXTERNALS" ]; then
    echo "Warning: $EXTERNALS not found - external pins not refreshed."
else
    echo "Refreshing external pins in $EXTERNALS..."
    # Same sha256 detection ladder as the installers: Linux ships sha256sum,
    # macOS ships shasum (gsha256sum if coreutils is installed).
    SHA_CMD=""
    if command -v sha256sum >/dev/null 2>&1; then
        SHA_CMD="sha256sum"
    elif command -v gsha256sum >/dev/null 2>&1; then
        SHA_CMD="gsha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        SHA_CMD="shasum -a 256"
    else
        echo "  Warning: no sha256 tool found - URLs will move but checksums cannot be recomputed."
    fi
    repos="$(grep -oE 'github\.com/[^/"]+/[^/"]+/archive' "$EXTERNALS" | sed 's|github\.com/||; s|/archive$||' | sort -u)"
    for repo in $repos; do
        refresh_external "$repo"
    done
fi

# 4. agent-guardrails stays pinned to the reviewed release in the installer
# templates and manual updaters. Never replace that pin with GitHub's latest.

# Note: Node.js is not dynamically bumped here. It is pinned to 24.x in
# three installers by hand - run_onchange_install_packages.ps1.tmpl (choco
# nodejs --version), the NodeSource setup_24.x script (Linux), and brew
# node@24 (macOS) - bump those together when moving majors.

echo "Version updates complete."
