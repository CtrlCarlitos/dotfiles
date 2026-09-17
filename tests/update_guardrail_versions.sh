#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

prepare_repo() {
    local destination="$1"
    mkdir -p "$destination/scripts"
    cp "$repo_root/scripts/update-versions.sh" "$destination/scripts/"
    cp "$repo_root/.chezmoi-version" "$destination/"
    cp "$repo_root/run_onchange_install_packages.sh.tmpl" "$destination/"
    cp "$repo_root/run_onchange_install_packages.ps1.tmpl" "$destination/"
    cp "$repo_root/scripts/update_ai_tools.sh" "$destination/scripts/"
    cp "$repo_root/scripts/update_ai_tools.ps1" "$destination/scripts/"
}

write_fake_curl() {
    local fixture="$1"
    mkdir -p "$fixture/bin"
    cat > "$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url="${!#}"
printf '%s\n' "$url" >> "${CURL_LOG:-/dev/null}"
case "$url" in
    *twpayne/chezmoi/releases/latest)
        printf '%s\n' '{"tag_name": "v2.99.0"}'
        ;;
    *CtrlCarlitos/agent-guardrails/releases/latest)
        case "${GUARDRAIL_FIXTURE:?}" in
            complete)
                cat <<'JSON'
{"tag_name":"v1.2.3","draft":false,"prerelease":false,"assets":[{"name":"guardrail_linux_amd64"},{"name":"guardrail_linux_arm64"},{"name":"guardrail_darwin_amd64"},{"name":"guardrail_darwin_arm64"},{"name":"guardrail_windows_amd64.exe"},{"name":"guardrail_windows_arm64.exe"},{"name":"SHA256SUMS"}]}
JSON
                ;;
            incomplete)
                cat <<'JSON'
{"tag_name":"v1.2.3","draft":false,"prerelease":false,"assets":[{"name":"guardrail_linux_amd64"},{"name":"SHA256SUMS"}]}
JSON
                ;;
            malformed)
                cat <<'JSON'
{"tag_name":"v1.2.3-dev","draft":false,"prerelease":false,"assets":[{"name":"guardrail_linux_amd64"},{"name":"guardrail_linux_arm64"},{"name":"guardrail_darwin_amd64"},{"name":"guardrail_darwin_arm64"},{"name":"guardrail_windows_amd64.exe"},{"name":"guardrail_windows_arm64.exe"},{"name":"SHA256SUMS"}]}
JSON
                ;;
            none)
                exit 22
                ;;
        esac
        ;;
    *)
        :
        ;;
esac
EOF
    chmod +x "$fixture/bin/curl"
}

assert_guardrail_version() {
    local directory="$1" expected="$2"
    for file in \
        run_onchange_install_packages.sh.tmpl \
        run_onchange_install_packages.ps1.tmpl \
        scripts/update_ai_tools.sh \
        scripts/update_ai_tools.ps1; do
        grep -Fq "$expected" "$directory/$file" ||
            fail "$file did not contain $expected"
    done
}

pin_repo="$tmp/pin"
prepare_repo "$pin_repo"
write_fake_curl "$pin_repo"
(
    cd "$pin_repo"
    PATH="$pin_repo/bin:$PATH" GUARDRAIL_FIXTURE=complete CURL_LOG="$pin_repo/curl.log" bash scripts/update-versions.sh
)
assert_guardrail_version "$pin_repo" 'v0.19.6-dev'
! grep -Fq 'CtrlCarlitos/agent-guardrails/releases/latest' "$pin_repo/curl.log" ||
    fail 'version updater requested the unpinned agent-guardrails latest release'

printf 'PASS: pinned agent-guardrails release is not auto-updated\n'
