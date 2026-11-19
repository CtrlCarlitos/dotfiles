#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

export TESTS_FAILFAST=1

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/modify_dot_gitconfig.tmpl"
managed_template="$repo_root/.chezmoitemplates/gitconfig-managed"
config="$repo_root/tests/fixtures/chezmoi/accounts-single.toml"

[ -f "$template" ] || fail "modify_dot_gitconfig.tmpl is missing"
[ -f "$managed_template" ] || fail "gitconfig-managed template is missing"
[ ! -e "$repo_root/dot_gitconfig.tmpl" ] || fail "dot_gitconfig.tmpl would still fully own ~/.gitconfig"
pass
pass
pass

command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed; executable gitconfig merge checks skipped"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/input" <<'GITCONFIG'
[user]
    name = Student User
    email = student@example.test
[credential]
    helper =

    helper = "/usr/bin/gh" auth git-credential
[credential "https://gist.github.com"]
    helper =
    helper = "/usr/bin/gh" auth git-credential
[credential "https://github.com"]
    helper =
    helper = "/usr/bin/gh" auth git-credential
[credential "https://github.com/some-org"]
    helper = manager-core
[student]
    editor = nano
GITCONFIG

extract_credentials() {
    awk '
        function section_header(line) {
            return line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/
        }
        function credential_header(line) {
            return line ~ /^[[:space:]]*\[credential([[:space:]]+"[^"]*")?\][[:space:]]*$/
        }
        section_header($0) { keep = credential_header($0) }
        keep { print }
    ' "$1"
}

render_merge() {
    chezmoi execute-template --config "$config" --source "$repo_root" \
        --with-stdin --file "$template" <"$1" >"$2"
}

render_merge "$tmp/input" "$tmp/output"
chezmoi execute-template --config "$config" --source "$repo_root" \
    --file "$managed_template" >"$tmp/baseline"
cat >"$tmp/include-tail" <<'GITCONFIG'
[include]
    path = ~/.gitconfig.local
GITCONFIG
tail -n 2 "$tmp/baseline" >"$tmp/baseline-tail"
cmp -s "$tmp/include-tail" "$tmp/baseline-tail" ||
    fail "managed ~/.gitconfig.local include is not the baseline's final section"
pass
extract_credentials "$tmp/input" >"$tmp/credentials"
cat "$tmp/baseline" "$tmp/credentials" >"$tmp/expected"
cmp -s "$tmp/expected" "$tmp/output" || {
    diff -u "$tmp/expected" "$tmp/output" >&2 || true
    fail "rendered gitconfig is not exactly the managed baseline followed by preserved credential sections"
}
pass

git config --file "$tmp/output" --list >/dev/null || fail "rendered gitconfig does not parse"
pass

[ "$(git config --file "$tmp/output" user.name)" = "CI User" ] ||
    fail "machine-local user.name overrode the shared account baseline"
[ "$(git config --file "$tmp/output" user.email)" = "ci@test.local" ] ||
    fail "machine-local user.email overrode the shared account baseline"
pass
pass

if git config --file "$tmp/output" --get student.editor >/dev/null 2>&1; then
    fail "unrelated [student] section survived; customization belongs in ~/.gitconfig.local"
fi
pass

[ "$(git config --file "$tmp/output" --get-all include.path | grep -Fxc '~/.gitconfig.local')" -eq 1 ] ||
    fail "~/.gitconfig.local include must appear exactly once"
pass

render_merge "$tmp/output" "$tmp/output-second"
cmp -s "$tmp/output" "$tmp/output-second" || {
    diff -u "$tmp/output" "$tmp/output-second" >&2 || true
    fail "second gitconfig render is not byte-identical"
}
pass

chezmoi managed --config "$config" --source "$repo_root" >"$tmp/managed"
grep -Fxq '.gitconfig' "$tmp/managed" || fail ".gitconfig is not managed"
if grep -Fxq '.gitconfig.local' "$tmp/managed"; then
    fail ".gitconfig.local must never be managed"
fi
pass
pass

finish
