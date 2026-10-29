#!/usr/bin/env bash
set -euo pipefail

# Telegram on a Linux release without telegram-desktop, EXECUTED.
#
# Ubuntu 26.04 ships no telegram-desktop, so the dev_desktop apt loop only warned "not
# installable" (#431 Run 17). The rendered installer's loop and install_telegram_linux run against
# stubs (apt-cache, curl, a logging $SUDO) and a fixture release whose asset is a real tar.xz:
#   1. apt has telegram-desktop - apt installs it, the procedure is not used;
#   2. apt has none - the official build is installed: sha256 checked, unpacked to
#      ~/.local/opt/Telegram, ~/.local/bin/telegram links to it, no sudo;
#   3. already installed - no download (it updates itself);
#   4. the download does not match the published sha256 - nothing installed;
#   5. the release publishes no sha256 - refused before any download.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v jq >/dev/null 2>&1 || skip 'jq not installed'
command -v xz >/dev/null 2>&1 || skip 'xz not installed (the fixture is a tar.xz)'
# The sandboxed PATH below finds jq and xz in /usr/bin on Linux/macOS/WSL; on Windows Git Bash jq is
# a winget/choco install and xz lives in /mingw64/bin, and without them every procedure case only
# warns "jq unavailable" or tar cannot exec xz (#430 Run 17).
tool_dirs="$(dirname -- "$(command -v jq)"):$(dirname -- "$(command -v xz)")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_to "$tmp/installer.sh" sh '{"dev_desktop": true}'
fn() { awk -v n="$1" 'index($0, n "() {") == 1 {on = 1} on {print} on && /^\}/ {exit}' "$tmp/installer.sh"; }
{ fn apt_has_candidate; fn install_telegram_linux; } >"$tmp/fns.sh"
# The dev_desktop apt loop: the one whose rendered package list carries telegram-desktop.
awk '/^    for pkg in .*telegram-desktop/ {on = 1} on {print} on && /^    done/ {exit}' "$tmp/installer.sh" >"$tmp/loop.sh"
grep -q 'install_telegram_linux() {' "$tmp/fns.sh" || fail "install_telegram_linux not found in the rendered installer"
grep -q 'install_telegram_linux' "$tmp/loop.sh" || fail "the dev_desktop apt loop does not reach install_telegram_linux"

# Fixture release: a tar.xz shaped like Telegram's (Telegram/Telegram + Telegram/Updater).
mkdir -p "$tmp/fixture/Telegram"
printf '#!/bin/sh\necho telegram\n' >"$tmp/fixture/Telegram/Telegram"
printf '#!/bin/sh\n' >"$tmp/fixture/Telegram/Updater"
chmod +x "$tmp/fixture/Telegram/Telegram" "$tmp/fixture/Telegram/Updater"
tar -cJf "$tmp/asset.tar.xz" -C "$tmp/fixture" Telegram
good_sum="$(sha256sum "$tmp/asset.tar.xz" | cut -d' ' -f1)"
release() { # $1 = digest field value ("" = none)
    jq -n --arg d "$1" '{tag_name: "v9.9.9", assets: [
        {name: "td-setup-linux-x64-9.9.9.tar.xz", browser_download_url: "https://example.invalid/td.tar.xz", digest: (if $d == "" then null else $d end)},
        {name: "tsetup.9.9.9.zip", browser_download_url: "https://example.invalid/other.zip", digest: "sha256:00"}]}' >"$tmp/release.json"
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${CURL_LOG:?}"
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
case "$url" in
    *api.invalid*) cat "${RELEASE_JSON:?}" ;;
    *td.tar.xz) cp "${ASSET:?}" "$out" ;;
    *) exit 22 ;;
esac
EOF
cat >"$tmp/bin/apt-cache" <<'EOF'
#!/bin/sh
printf '%s:\n  Installed: (none)\n  Candidate: %s\n' "$3" "${CANDIDATE:?}"
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/apt-cache"
{
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'info() { printf "info: %s\n" "$1"; }' 'warn() { printf "warn: %s\n" "$1"; }' 'success() { printf "ok: %s\n" "$1"; }'
    printf '%s\n' 'stub_sudo() { printf "%s\n" "$*" >>"$SUDO_LOG"; }' 'SUDO=stub_sudo'
    printf '%s\n' 'net_timeout() { shift; "$@"; }'
    cat "$tmp/fns.sh"
    printf '%s\n' 'f() {'
    cat "$tmp/loop.sh"
    printf '%s\n' '}' 'f'
} >"$tmp/harness.sh"

home="$tmp/home"
run() { # $1 = apt candidate for telegram-desktop; env: ASSET
    : >"$tmp/sudo.log"; : >"$tmp/curl.log"; mkdir -p "$home" "$tmp/work"
    HOME="$home" WORK="$tmp/work" CANDIDATE="$1" ASSET="${ASSET:-$tmp/asset.tar.xz}" RELEASE_JSON="$tmp/release.json" \
        TELEGRAM_RELEASE_API="https://api.invalid/latest" SUDO_LOG="$tmp/sudo.log" CURL_LOG="$tmp/curl.log" \
        PATH="$tmp/bin:/usr/bin:/bin:$tool_dirs" bash "$tmp/harness.sh" 2>&1
}

# 1. apt can install it: apt does, the procedure stays out of it.
release "sha256:$good_sum"
out="$(run '4.14.9+ds-1')"
grep -q 'apt install -y telegram-desktop' "$tmp/sudo.log" && pass || fail "apt candidate: telegram-desktop must come from apt (sudo: $(tr '\n' ';' <"$tmp/sudo.log"))"
[ -s "$tmp/curl.log" ] && fail "apt candidate: no download may run (curl: $(cat "$tmp/curl.log"))" || pass

# 2. No apt candidate: the official build, verified, in ~/.local/opt/Telegram, linked, no sudo.
out="$(run '(none)')"
[ -x "$home/.local/opt/Telegram/Telegram" ] && [ -x "$home/.local/opt/Telegram/Updater" ] && pass ||
    fail "no candidate: Telegram (and its Updater) must be in ~/.local/opt/Telegram (got: $out)"
if symlinks_work; then
    [ "$(readlink "$home/.local/bin/telegram")" = "$home/.local/opt/Telegram/Telegram" ] && pass ||
        fail "no candidate: ~/.local/bin/telegram must link to it"
else
    skip_part "no candidate: the ~/.local/bin/telegram symlink (ln -s copies here)"
fi
# The loop's other packages still go through apt; nothing about Telegram needs sudo.
grep -qi 'telegram' "$tmp/sudo.log" && fail "no candidate: nothing for Telegram may need sudo (sudo: $(tr '\n' ';' <"$tmp/sudo.log"))" || pass
case "$out" in *'Telegram installed'*'menu entry'*) pass ;; *) fail "no candidate: the install, and the first run that adds the menu entry, must be said (got: $out)" ;; esac
[ -z "$(ls -A "$tmp/work")" ] && pass || fail "no candidate: the download and unpack dir must be cleaned up ($(ls -A "$tmp/work"))"

# 3. Already installed: no download, it updates itself.
out="$(run '(none)')"
[ -s "$tmp/curl.log" ] && fail "installed: no download may run (curl: $(cat "$tmp/curl.log"))" || pass
case "$out" in *'already installed'*) pass ;; *) fail "installed: must say so (got: $out)" ;; esac

# 4. The download does not match the published sha256: nothing installed.
rm -rf "$home"
release "sha256:$(printf '%064d' 0)"
out="$(run '(none)')"
[ -e "$home/.local/opt/Telegram" ] && fail "bad sha256: nothing may be installed"
case "$out" in *'does not match its published sha256'*) pass ;; *) fail "bad sha256: must warn (got: $out)" ;; esac

# 5. No sha256 published: refused before downloading.
rm -rf "$home"
release ""
out="$(run '(none)')"
grep -q 'td.tar.xz' "$tmp/curl.log" && fail "no sha256: the asset must not be downloaded"
[ -e "$home/.local/opt/Telegram" ] && fail "no sha256: nothing may be installed"
case "$out" in *'no Linux x64 build with a sha256'*) pass ;; *) fail "no sha256: must warn (got: $out)" ;; esac

finish
