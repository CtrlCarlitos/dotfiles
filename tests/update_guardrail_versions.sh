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
        if [ "$expected" != 'v0.18.0-dev' ]; then
            ! grep -Fq 'v0.18.0-dev' "$directory/$file" ||
                fail "$file still contained the previous guardrail version"
        fi
    done
}

snapshot_guardrail_files() {
    local directory="$1"
    mkdir -p "$directory/original"
    for file in \
        run_onchange_install_packages.sh.tmpl \
        run_onchange_install_packages.ps1.tmpl \
        scripts/update_ai_tools.sh \
        scripts/update_ai_tools.ps1; do
        cp "$directory/$file" "$directory/original/${file//\//_}"
    done
}

assert_guardrail_files_unchanged() {
    local directory="$1"
    for file in \
        run_onchange_install_packages.sh.tmpl \
        run_onchange_install_packages.ps1.tmpl \
        scripts/update_ai_tools.sh \
        scripts/update_ai_tools.ps1; do
        cmp -s "$directory/$file" "$directory/original/${file//\//_}" ||
            fail "$file changed despite a no-op guardrail update"
    done
}

complete_repo="$tmp/complete"
prepare_repo "$complete_repo"
write_fake_curl "$complete_repo"
(
    cd "$complete_repo"
    PATH="$complete_repo/bin:$PATH" GUARDRAIL_FIXTURE=complete bash scripts/update-versions.sh
)
assert_guardrail_version "$complete_repo" 'v1.2.3'

incomplete_repo="$tmp/incomplete"
prepare_repo "$incomplete_repo"
write_fake_curl "$incomplete_repo"
snapshot_guardrail_files "$incomplete_repo"
(
    cd "$incomplete_repo"
    PATH="$incomplete_repo/bin:$PATH" GUARDRAIL_FIXTURE=incomplete bash scripts/update-versions.sh
)
assert_guardrail_files_unchanged "$incomplete_repo"

no_release_repo="$tmp/no-release"
prepare_repo "$no_release_repo"
write_fake_curl "$no_release_repo"
snapshot_guardrail_files "$no_release_repo"
(
    cd "$no_release_repo"
    PATH="$no_release_repo/bin:$PATH" GUARDRAIL_FIXTURE=none bash scripts/update-versions.sh
)
assert_guardrail_files_unchanged "$no_release_repo"

malformed_repo="$tmp/malformed"
prepare_repo "$malformed_repo"
write_fake_curl "$malformed_repo"
snapshot_guardrail_files "$malformed_repo"
(
    cd "$malformed_repo"
    PATH="$malformed_repo/bin:$PATH" GUARDRAIL_FIXTURE=malformed bash scripts/update-versions.sh
)
assert_guardrail_files_unchanged "$malformed_repo"

no_jq_repo="$tmp/no-jq"
prepare_repo "$no_jq_repo"
write_fake_curl "$no_jq_repo"
snapshot_guardrail_files "$no_jq_repo"
ln -s "$(command -v bash)" "$no_jq_repo/bin/bash"
ln -s "$(command -v grep)" "$no_jq_repo/bin/grep"
ln -s "$(command -v head)" "$no_jq_repo/bin/head"
(
    cd "$no_jq_repo"
    PATH="$no_jq_repo/bin" GUARDRAIL_FIXTURE=complete /bin/bash scripts/update-versions.sh
)
assert_guardrail_files_unchanged "$no_jq_repo"

printf 'PASS: stable agent-guardrails releases update all pins; no release is a no-op\n'
