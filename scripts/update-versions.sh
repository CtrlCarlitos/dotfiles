#!/usr/bin/env bash
# update-versions.sh - refresh the version pins this repo carries: the
# chezmoi pin in .chezmoi-version and the Antigravity 2.0 hub pin rendered
# by the installer templates. Run by the weekly CI cron; a run with no pin
# movement makes no change. See the per-pin comments below for the failure
# lessons (gzip decoding, channel matching) baked into this script.

set -e

# Shared helpers (issue #123): net_timeout + sha256_cmd (the sha256-tool
# detection ladder the installers use - this script used to carry its own copy).
. "$(dirname "$0")/lib/agent-skills.sh"

# Run from the repo root no matter where the script is invoked from.
cd "$(dirname "$0")/.."

echo "Starting Auto-Update Script..."

# 1. Update Chezmoi Version (net_timeout: same wall-clock contract as the
# installers - this is a network fetch like any other).
echo "Fetching latest Chezmoi version..."
LATEST_CHEZMOI=$(net_timeout 60 curl -s "https://api.github.com/repos/twpayne/chezmoi/releases/latest" | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4)
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
LATEST=$(net_timeout 60 curl -sL --compressed https://antigravity.google/download \
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
        # Rewrite the pin in .chezmoidata.yaml versions.antigravity_hub (#125,
        # the single source the installer template renders - it used to sed the
        # template directly). Windows needs nothing here: it installs Antigravity
        # via Chocolatey, which floats to whatever the community package
        # carries - there is no pin in the ps1 template to bump.
        # Portable in-place edit (BSD sed has no `sed -i` without an arg):
        # write to a temp file, then mv over the original.
        tmp_data="$(mktemp)"
        sed -E "s|^  antigravity_hub: .*|  antigravity_hub: \"$LATEST\"|" .chezmoidata.yaml > "$tmp_data"
        mv "$tmp_data" .chezmoidata.yaml
    else
        echo "Warning: Not updating Antigravity hub version - one or more asset URLs are broken."
        echo "  This usually means Google changed the hub channel layout; the URL"
        echo "  templates need a manual look."
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
    # Same sha256 detection ladder as the installers, via the shared lib
    # (scripts/lib/agent-skills.sh): Linux ships sha256sum, macOS ships shasum
    # (gsha256sum if coreutils is installed).
    SHA_CMD="$(sha256_cmd)"
    if [ -z "$SHA_CMD" ]; then
        echo "  Warning: no sha256 tool found - URLs will move but checksums cannot be recomputed."
    fi
    repos="$(grep -oE 'github\.com/[^/"]+/[^/"]+/archive' "$EXTERNALS" | sed 's|github\.com/||; s|/archive$||' | sort -u)"
    for repo in $repos; do
        refresh_external "$repo"
    done
fi

# 4. agent-guardrails stays pinned to the reviewed release in the installer
# templates and manual updaters. Never replace that pin with GitHub's latest.

# 5. Sync the DERIVED copies of the .chezmoidata.yaml versions.* pins (#125):
#    - versions.node_major -> the catalog's brew formula name (node@NN)
#    - versions.gum        -> the bootstraps' fallback literals in install.sh
#                             and install.ps1 (they only cover the one-liner
#                             run where the yaml was never downloaded)
#    No network: the canonical values are deliberate hand-reviewed pins - a
#    bump edits .chezmoidata.yaml, this run then carries the derived copies
#    through the same PR so they cannot drift.
echo "Syncing derived pin copies..."
NODE_MAJOR="$(sed -n 's/^  node_major: \([0-9][0-9]*\)$/\1/p' .chezmoidata.yaml)"
if [ -n "$NODE_MAJOR" ]; then
    tmp_file="$(mktemp)"
    sed -E "s/(brew: node@)[0-9]+\$/\1${NODE_MAJOR}/" .chezmoidata/packages.yaml > "$tmp_file"
    if ! cmp -s "$tmp_file" .chezmoidata/packages.yaml; then
        mv "$tmp_file" .chezmoidata/packages.yaml
        echo "  .chezmoidata/packages.yaml: node@$NODE_MAJOR"
    else
        rm -f "$tmp_file"
        echo "  .chezmoidata/packages.yaml: node@ already $NODE_MAJOR"
    fi
else
    echo "  Warning: versions.node_major not found in .chezmoidata.yaml - catalog sync skipped."
fi

GUM_PIN="$(sed -n 's/^  gum: "\([^"]*\)"$/\1/p' .chezmoidata.yaml)"
if [ -n "$GUM_PIN" ]; then
    tmp_file="$(mktemp)"
    # Rewrite just the fallback-literal lines; cmp+mv reports/skips no-ops.
    awk -v pin="$GUM_PIN" '/^GUM_VERSION=/{ sub(/:-[^}]*\}/, ":-" pin "}") } { print }' install.sh > "$tmp_file"
    if cmp -s "$tmp_file" install.sh; then
        echo "  install.sh: gum fallback already $GUM_PIN"
        rm -f "$tmp_file"
    else
        mv "$tmp_file" install.sh
        echo "  install.sh: gum fallback -> $GUM_PIN"
    fi
    tmp_file="$(mktemp)"
    awk -v pin="$GUM_PIN" '/^\$gumVersion = /{ sub(/= .*/, "= \047" pin "\047") } { print }' install.ps1 > "$tmp_file"
    if cmp -s "$tmp_file" install.ps1; then
        echo "  install.ps1: gum fallback already $GUM_PIN"
        rm -f "$tmp_file"
    else
        mv "$tmp_file" install.ps1
        echo "  install.ps1: gum fallback -> $GUM_PIN"
    fi
else
    echo "  Warning: versions.gum not found in .chezmoidata.yaml - bootstrap fallback sync skipped."
fi

echo "Version updates complete."
