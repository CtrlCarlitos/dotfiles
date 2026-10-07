#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the fakes are called by the sourced function
set -euo pipefail

# Docs tooling for the release-notes and update-docs skills (CtrlCarlitos/skills#2, #3):
# markdownlint-cli2 (npm), lychee and vale (binaries). This pins:
#   - the catalog carries all three in modern_cli, with the managers each OS uses;
#   - the rendered installers install them: brew/choco from the catalog, apt by a pinned,
#     checksum-verified release tarball, npm only when missing;
#   - install_release_binary is EXECUTED: a matching checksum installs the archive member,
#     a mismatch installs nothing, a tool already on PATH is not downloaded;
#   - dot upgrade updates the npm globals (both twins), and names lychee/vale as Linux
#     tarballs it cannot upgrade.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

catalog="$repo_root/.chezmoidata/packages.yaml"
sh_t="$repo_root/run_onchange_install_packages.sh.tmpl"
ps_t="$repo_root/run_onchange_install_packages.ps1.tmpl"
fx="$(mktemp -d)"
trap 'rm -rf "$fx"' EXIT

# --- catalog ---------------------------------------------------------------------------------
record() { awk -v id="$1" '$0 ~ "^    - id: "id"$" {f=1; next} f && /^    - id: / {exit} f' "$catalog"; }
record markdownlint-cli2 | grep -Fqx '      npm: markdownlint-cli2' || fail "catalog: markdownlint-cli2 must be an npm record"
for tool in lychee vale; do
    rec="$(record "$tool")"
    printf '%s\n' "$rec" | grep -Fqx '      group: modern_cli' || fail "catalog: $tool must be in modern_cli"
    printf '%s\n' "$rec" | grep -Fqx "      brew: $tool" || fail "catalog: $tool needs its brew formula"
    case "$tool" in
        lychee) printf '%s\n' "$rec" | grep -Fqx "      winget: lycheeverse.lychee" || fail "catalog: lychee needs its winget package" ;;
        vale) printf '%s\n' "$rec" | grep -Fqx "      choco: vale" || fail "catalog: vale needs its choco package (winget's lags)" ;;
    esac
    if printf '%s\n' "$rec" | grep -q '^      apt:'; then fail "catalog: $tool is not in the Ubuntu archive - no apt key"; fi
done
pass

# --- rendered installers ---------------------------------------------------------------------
if command -v chezmoi >/dev/null 2>&1; then
    on='{"core":true,"modern_cli":true}'
    render --override-data "{\"chezmoi\":{\"os\":\"linux\",\"kernel\":{\"osrelease\":\"6.8-generic\"}},\"packages\":$on}" --file "$sh_t" >"$fx/linux.sh"
    if ! grep -Fq 'npm_tools="markdownlint-cli2"' "$fx/linux.sh" || ! grep -Eq '^ *install_npm_tools \$npm_tools$' "$fx/linux.sh"; then
        fail "linux render: markdownlint-cli2 is not installed through install_npm_tools"
    fi
    for tool in lychee vale; do
        n="$(grep -c "install_release_binary $tool \"https://github.com/" "$fx/linux.sh" || true)"
        [ "$n" = 2 ] || fail "linux render: $tool needs one pinned release per architecture (amd64, arm64), got $n"
    done
    [ "$(grep -cE '^ +[0-9a-f]{64} (lychee|vale)' "$fx/linux.sh" || true)" = 4 ] || fail "linux render: every lychee/vale download needs its sha256"
    render --override-data "{\"chezmoi\":{\"os\":\"darwin\",\"kernel\":{\"osrelease\":\"24.0.0\"}},\"packages\":$on}" --file "$sh_t" >"$fx/darwin.sh"
    grep -Fq 'npm_tools="markdownlint-cli2"' "$fx/darwin.sh" || fail "macOS render: markdownlint-cli2 is not installed"
    grep -Eq '^ *brew install .*\blychee\b.*\bvale\b' "$fx/darwin.sh" || fail "macOS render: lychee and vale must come from brew"
    render --override-data "{\"chezmoi\":{\"os\":\"windows\"},\"packages\":$on}" --file "$ps_t" >"$fx/win.ps1"
    grep -Fq "Install-NpmCatalogTool -Package @('markdownlint-cli2' -split ' '" "$fx/win.ps1" || fail "windows render: markdownlint-cli2 is not installed through Install-NpmCatalogTool"
    grep -Fq '$wingetPackages += "lycheeverse.lychee||lychee"' "$fx/win.ps1" || fail "windows render: lychee is not in the winget list"
    grep -Fq '$packages += "vale"' "$fx/win.ps1" || fail "windows render: vale is not in the choco list"
    pass
else
    printf 'note: chezmoi not installed - render checks skipped\n'
fi

# --- install_release_binary, executed ------------------------------------------------------------
extract_fn() { awk -v n="$1" 'index($0, n "() {") == 1 {f=1} f{print} f && /^}$/{exit}' "$sh_t"; }
extract_fn install_release_binary >"$fx/fn.sh"
grep -q '^install_release_binary() {' "$fx/fn.sh" || fail "install_release_binary() not found in the installer template"
mkdir -p "$fx/pkg/tool-x" "$fx/bin" "$fx/dest"
printf '#!/bin/sh\necho fake\n' >"$fx/pkg/tool-x/faketool"
chmod +x "$fx/pkg/tool-x/faketool"
tar -czf "$fx/release.tar.gz" -C "$fx/pkg" tool-x
fx_sha=sha256sum; command -v sha256sum >/dev/null 2>&1 || fx_sha="shasum -a 256"
good="$($fx_sha "$fx/release.tar.gz" | cut -c1-64)"
cat >"$fx/bin/curl" <<EOF
#!/usr/bin/env bash
# curl -fsSLo <out> <url>: copy the fixture archive, log the call
echo "\$*" >>"$fx/curl.log"
cp "$fx/release.tar.gz" "\$2"
EOF
chmod +x "$fx/bin/curl"
run_install() { # <sha>; installs into $fx/dest through a fake `install`
    trap - EXIT   # called inside $( ): the parent's cleanup must not run when that subshell ends
    : >"$fx/curl.log"; rm -f "$fx/dest/faketool"
    (
        PATH="$fx/bin:$PATH"
        SUDO=""
        info() { :; }; warn() { echo "WARN: $*"; }
        net_timeout() { shift; "$@"; }
        sha256_cmd() { echo "$fx_sha"; }
        install() { cp "$1" "$fx/dest/$(basename "$2")"; }
        # shellcheck disable=SC1091
        . "$fx/fn.sh"
        install_release_binary faketool "https://example.invalid/release.tar.gz" "$1" tool-x/faketool
    )
}
out="$(run_install "$good")"
[ -x "$fx/dest/faketool" ] || fail "a matching checksum must install the archive member (output: $out)"
out="$(run_install 0000000000000000000000000000000000000000000000000000000000000000)"
[ ! -e "$fx/dest/faketool" ] || fail "a checksum mismatch must install nothing"
printf '%s' "$out" | grep -q 'checksum verification failed' || fail "a checksum mismatch must say so (got: $out)"
printf '#!/bin/sh\nexit 0\n' >"$fx/bin/faketool"
chmod +x "$fx/bin/faketool"
out="$(run_install "$good")"
[ ! -s "$fx/curl.log" ] || fail "a tool already on PATH must not be downloaded again"
pass

# --- dot upgrade -------------------------------------------------------------------------------
grep -Fq "{{ range .catalog.packages }}{{ if hasKey . \"npm\" }}{{ .npm }} {{ end }}{{ end }}" "$repo_root/scripts/update_ai_tools.sh" ||
    fail "update_ai_tools.sh must update the catalog's npm globals"
grep -Fq "{{ range .catalog.packages }}{{ if hasKey . \"npm\" }}{{ .npm }} {{ end }}{{ end }}" "$repo_root/scripts/update_ai_tools.ps1" ||
    fail "update_ai_tools.ps1 must update the catalog's npm globals"
# the Linux note names what is installed and cannot be upgraded - lychee and vale among them -
# and nothing that is absent (WSL has no desktop apps; it used to list Docker Desktop there)
awk '/^unmanaged_present\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$repo_root/scripts/dotupgrade.sh" >"$fx/unmanaged.sh"
grep -q '^unmanaged_present() {' "$fx/unmanaged.sh" || fail "dotupgrade.sh: unmanaged_present() not found"
mkdir -p "$fx/ubin" "$fx/uhome"
for b in lychee vale delta; do printf '#!/bin/sh\n' >"$fx/ubin/$b"; chmod +x "$fx/ubin/$b"; done
printf '#!/bin/sh\nexit 1\n' >"$fx/ubin/dpkg"; chmod +x "$fx/ubin/dpkg"
sed_bin="$(command -v sed)"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$sed_bin" >"$fx/ubin/sed"; chmod +x "$fx/ubin/sed"
# PATH is the fake folder only: a CI runner has a real google-chrome in /usr/bin
note="$(HOME="$fx/uhome" PATH="$fx/ubin" "$BASH" -c '. "$1"; unmanaged_present' _ "$fx/unmanaged.sh")"
[ "$note" = "delta, lychee, vale" ] || fail "the Linux note must name exactly what is installed (got: $note)"
pass

finish
