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

cat >"$tmp/credential-free-input" <<'GITCONFIG'
[user]
    name = Student User
    email = student@example.test
[student]
    editor = nano
[include]
    path = ~/.gitconfig.student
GITCONFIG
render_merge "$tmp/credential-free-input" "$tmp/credential-free-output"
cmp -s "$tmp/baseline" "$tmp/credential-free-output" || {
    diff -u "$tmp/baseline" "$tmp/credential-free-output" >&2 || true
    fail "credential-free input did not render exactly the managed baseline"
}
pass

cat >"$tmp/credentials" <<'GITCONFIG'
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
GITCONFIG
cat "$tmp/baseline" "$tmp/credentials" >"$tmp/expected"
cmp -s "$tmp/expected" "$tmp/output" || {
    diff -u "$tmp/expected" "$tmp/output" >&2 || true
    fail "rendered gitconfig is not exactly the managed baseline followed by preserved credential sections"
}
pass

# Git accepts case-insensitive section names, quoted subsections containing `]`
# or escaped quotes, and trailing comments. Literal expected output keeps this
# oracle independent from the production section classifier.
cat >"$tmp/edge-input" <<'GITCONFIG'
[user]
    name = Student User
[Credential] # case and trailing comment
    helper = case-helper
[credential "https://[2001:db8::1]/path"] ; closing bracket inside subsection
    helper = ipv6-helper
[credential "https://example.test/a\"b"] # escaped quote in subsection
    helper = quote-helper
[credential "https://keep-before-boundary.test"]
    helper = boundary-helper

[student] # commented non-credential boundary
    editor = nano
GITCONFIG
git config --file "$tmp/edge-input" --list >/dev/null || fail "edge fixture is not valid Git config"
pass
cat >"$tmp/edge-credentials" <<'GITCONFIG'
[Credential] # case and trailing comment
    helper = case-helper
[credential "https://[2001:db8::1]/path"] ; closing bracket inside subsection
    helper = ipv6-helper
[credential "https://example.test/a\"b"] # escaped quote in subsection
    helper = quote-helper
[credential "https://keep-before-boundary.test"]
    helper = boundary-helper

GITCONFIG
cat "$tmp/baseline" "$tmp/edge-credentials" >"$tmp/edge-expected"
render_merge "$tmp/edge-input" "$tmp/edge-output"
cmp -s "$tmp/edge-expected" "$tmp/edge-output" || {
    diff -u "$tmp/edge-expected" "$tmp/edge-output" >&2 || true
    fail "Git-valid credential headers were not preserved exactly or a commented non-credential section survived"
}
pass

# Native chezmoi execution must not require awk (Git for Windows does not put
# usr/bin/awk.exe on PowerShell's PATH) or send the whole config to a process.
mkdir "$tmp/no-awk-bin"
cat >"$tmp/no-awk-bin/awk" <<'SH'
#!/bin/sh
exit 97
SH
chmod +x "$tmp/no-awk-bin/awk"
if ! PATH="$tmp/no-awk-bin:$PATH" render_merge "$tmp/edge-input" "$tmp/no-awk-output"; then
    fail "modify template invokes external awk"
fi
cmp -s "$tmp/edge-expected" "$tmp/no-awk-output" || fail "render changed when awk was unavailable"
forbid "$template" 'output '
pass
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
