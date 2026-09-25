#!/usr/bin/env bash
set -euo pipefail

# Contract coverage for the devprofile bash twin (dot_local/bin/executable_devprofile)
# and for the identity files run_onchange_generate_identities.sh.tmpl writes.
# These two are the code that touches private keys and git signing config, and
# neither had any test until #122.
#
# Everything runs against stubs: git is a tiny key/value store plus a
# configurable rev-parse, ssh-keygen writes marker files - no real keys are
# ever generated, and $HOME is a scratch dir, never the runner's own.
#
# Unix-only: POSIX file modes are asserted. The PowerShell twin has its own
# test (tests/devprofile_identity.ps1); CI runs this file on Linux.
case "${OSTYPE:-}" in
    msys*|cygwin*|win32) skip "devprofile_contract.sh is Unix-only (asserts POSIX modes)" ;;
esac

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

devprofile="$repo_root/dot_local/bin/executable_devprofile"
tmpl="$repo_root/run_onchange_generate_identities.sh.tmpl"
[ -f "$devprofile" ] || fail "missing $devprofile"
[ -f "$tmpl" ] || fail "missing $tmpl"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
home="$tmp/home"
mkdir -p "$bin" "$home/.config/chezmoi" "$home/.ssh"

# The accounts fixture. Modeled on tests/fixtures/chezmoi/accounts-multi.toml
# (alice + bob) but with a custom signingKey on bob: the declared-signing-key
# paths are exactly what the old `list` code never checked, so the fixture must
# carry one. Two syntaxes of the same data - the TOML that devprofile's own
# loader reads and the JSON the template render gets. Keep them in sync.
cat > "$home/.config/chezmoi/chezmoi.toml" <<'TOML'
[[data.accounts]]
  name = "Alice Personal"
  email = "alice@personal.com"
  username = "alice"
  provider = "github"
  key = "id_alice"
  dirs = ["projects/alice", ".dotfiles"]

[[data.accounts]]
  name = "Bob Work"
  email = "bob@work.com"
  username = "bob"
  provider = "github"
  key = "id_bob"
  signingKey = "id_bob_commit"
  dirs = ["projects/bobcorp"]
TOML
accounts_json='[
 {"username":"alice","name":"Alice Personal","email":"alice@personal.com","provider":"github","key":"id_alice","dirs":["projects/alice",".dotfiles"]},
 {"username":"bob","name":"Bob Work","email":"bob@work.com","provider":"github","key":"id_bob","signingKey":"id_bob_commit","dirs":["projects/bobcorp"]}
]'

# Fake keys: marker content only, deliberately wrong private modes - the
# rendered identity script is what must normalize them (600 / 644). Signing
# keys carry the "<email>-sign" comment convention devprofile init writes.
mk_fake_key() { # $1 = key name, $2 = comment
    printf 'STUB-PRIVATE-KEY %s\n' "$1" > "$home/.ssh/$1"
    printf 'ssh-ed25519 AAAAFAKE-%s %s\n' "$1" "$2" > "$home/.ssh/$1.pub"
    chmod 644 "$home/.ssh/$1"
}
mk_fake_key id_alice alice@personal.com
mk_fake_key id_bob bob@work.com
mk_fake_key id_bob_commit bob@work.com-sign

# allowed_signers pre-exists with a hand-carried line: the rendered script
# must merge around it, never rebuild from scratch.
printf 'legacy@old.example namespaces="git" ssh-rsa AAAALEGACY\n' > "$home/.ssh/allowed_signers"

#--- stubs -------------------------------------------------------------------
cat > "$bin/git" <<'EOF'
#!/bin/bash
# git stub: `config` is a kv store in $GIT_STUB_CONFIG; rev-parse reports a
# repo only when $GIT_STUB_REPO is set (its value doubles as --show-toplevel).
cfg="${GIT_STUB_CONFIG:?}"
case "${1:-}" in
    rev-parse)
        if [ -z "${GIT_STUB_REPO:-}" ]; then
            echo "fatal: not a git repository" >&2
            exit 1
        fi
        case "${2:-}" in
            --git-dir) printf '.git\n' ;;
            --show-toplevel) printf '%s\n' "$GIT_STUB_REPO" ;;
        esac
        exit 0
        ;;
    config)
        shift
        [ "${1:-}" = "--local" ] && shift
        if [ $# -ge 2 ]; then
            key="$1"; shift
            printf '%s=%s\n' "$key" "$*" >> "$cfg"
        else
            grep -F -- "$1=" "$cfg" 2>/dev/null | tail -n 1 | cut -d= -f2-
        fi
        exit 0
        ;;
esac
exit 0
EOF
cat > "$bin/ssh-keygen" <<'EOF'
#!/bin/bash
# ssh-keygen stub: writes marker key files for -f PATH and logs argv, so tests
# can assert which flags (-N in particular) devprofile passed.
out=""; comment=""; next=""
for arg in "$@"; do
    case "$next" in
        f) out="$arg"; next=""; continue ;;
        C) comment="$arg"; next=""; continue ;;
    esac
    case "$arg" in
        -f) next=f ;;
        -C) next=C ;;
    esac
done
printf '%s\n' "$*" >> "${SSH_KEYGEN_LOG:?}"
[ -n "$out" ] || exit 2
printf 'STUB-PRIVATE-KEY %s\n' "$out" > "$out"
printf 'ssh-ed25519 AAAAFAKE-%s %s\n' "$(basename "$out")" "$comment" > "$out.pub"
exit 0
EOF
chmod +x "$bin/git" "$bin/ssh-keygen"

# Shadow chezmoi so devprofile's data always comes from the fixture TOML.
# Without this, a host with a real chezmoi on PATH (including a Windows one
# reachable through a WSL interop PATH) answers `chezmoi data` with the HOST's
# accounts and the run stops being about the fixture.
printf '#!/bin/sh\nexit 1\n' > "$bin/chezmoi"
chmod +x "$bin/chezmoi"

run_dev() { # remaining args go to devprofile; output captured
    HOME="$home" PATH="$bin:$PATH" SSH_KEYGEN_LOG="$tmp/ssh-keygen.log" \
        bash "$devprofile" "$@"
}

assert_out() { # $1 = label, $2 = output, $3 = literal that must appear
    if grep -Fq -- "$3" <<<"$2"; then pass; else fail "$1: output missing '$3'"; fi
}
assert_mode() { # $1 = path, $2 = expected mode
    if [ ! -f "$1" ]; then
        fail "$1: missing, want mode $2"
        return
    fi
    local m
    m="$(stat -c '%a' "$1")"
    if [ "$m" = "$2" ]; then pass; else fail "$1: mode $m, want $2"; fi
}

#=============================================================================
# [1] The rendered identity script writes the gitconfig/signers payload.
#=============================================================================
# The skip must be decided BEFORE render(): a skip raised inside
# `render ... > "$rendered"` would land in the redirected file instead of the
# runner's output, and look like a silent pass.
if ! command -v chezmoi >/dev/null 2>&1; then
    skip "devprofile_contract.sh: rendering run_onchange_generate_identities requires chezmoi"
fi
rendered="$tmp/generate.sh"
render --override-data \
    '{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"accounts":'"$accounts_json"'}' \
    < "$tmpl" > "$rendered"
HOME="$home" bash "$rendered" > "$tmp/generate.log" 2>&1

gitconfig_alice="$home/.gitconfig-github-alice"
gitconfig_bob="$home/.gitconfig-github-bob"
[ -f "$gitconfig_alice" ] || fail "rendered script did not write .gitconfig-github-alice"
[ -f "$gitconfig_bob" ] || fail "rendered script did not write .gitconfig-github-bob"
require "$gitconfig_alice" 'signingkey = ~/.ssh/id_alice.pub'
require "$gitconfig_bob" 'signingkey = ~/.ssh/id_bob_commit.pub'   # custom signingKey wins over the auth key
require "$gitconfig_alice" 'gpgsign = true'
require "$gitconfig_alice" 'format = ssh'
require "$home/.ssh/allowed_signers" 'legacy@old.example namespaces="git" ssh-rsa AAAALEGACY'  # merge keeps hand-carried lines
require "$home/.ssh/allowed_signers" 'alice@personal.com namespaces="git" ssh-ed25519 AAAAFAKE-id_alice'
require "$home/.ssh/allowed_signers" 'bob@work.com namespaces="git" ssh-ed25519 AAAAFAKE-id_bob_commit'
if [ "$(grep -cF 'AAAAFAKE-id_alice' "$home/.ssh/allowed_signers")" = 1 ]; then
    pass
else
    fail "allowed_signers: alice signer duplicated (account loop and scan loop must collapse)"
fi
assert_mode "$home/.ssh/allowed_signers" 600
assert_mode "$home/.ssh/id_bob" 600          # normalized from the wrong 644 above
assert_mode "$home/.ssh/id_bob.pub" 644
require "$home/.ssh/agent-identities.zsh" 'id_bob_commit'
assert_mode "$home/.ssh/agent-identities.zsh" 600
if [ -d "$home/projects/bobcorp" ]; then pass; else fail "rendered script did not create the account dirs"; fi

#=============================================================================
# [2] devprofile list - accounts parse from the fixture TOML, custom signing
#     keys show as "in use" (they were invisible before: only ${k}_sign was
#     ever checked).
#=============================================================================
list_out="$(run_dev list)"
assert_out "list" "$list_out" "alice"
assert_out "list" "$list_out" "bob"
if grep -F 'id_bob_commit' <<<"$list_out" | grep -Fq 'in use'; then
    pass
else
    fail "list: custom signingKey id_bob_commit must show as 'in use'"
fi
if grep -F 'id_alice' <<<"$list_out" | grep -Fq 'in use'; then
    pass
else
    fail "list: account auth key id_alice must show as 'in use'"
fi

#=============================================================================
# [3] devprofile use <name> - repo-local config prefers the declared
#     signingKey and enables ssh signing.
#=============================================================================
repo_bob="$home/projects/bobcorp"
mkdir -p "$repo_bob/.git/hooks"
: > "$tmp/bob.cfg"
out="$(cd "$repo_bob" && GIT_STUB_CONFIG="$tmp/bob.cfg" GIT_STUB_REPO="$repo_bob" \
    HOME="$home" PATH="$bin:$PATH" bash "$devprofile" use bob)"
assert_out "use bob" "$out" "Configured identity for this repo: bob"
require "$tmp/bob.cfg" 'user.name=Bob Work'
require "$tmp/bob.cfg" 'user.email=bob@work.com'
require "$tmp/bob.cfg" "user.signingkey=$home/.ssh/id_bob_commit.pub"
require "$tmp/bob.cfg" 'commit.gpgsign=true'
require "$tmp/bob.cfg" 'gpg.format=ssh'
assert_out "use bob" "$out" "Signing"     # box shows the signing key row
# Asserts the literal display bytes devprofile prints (tilde is display convention).
# shellcheck disable=SC2088
assert_out "use bob" "$out" "~/.ssh/id_bob_commit"

#=============================================================================
# [4] devprofile verify - matching dirs mapping passes; a repo living under
#     another account's dirs is flagged.
#=============================================================================
out="$(cd "$repo_bob" && GIT_STUB_CONFIG="$tmp/bob.cfg" GIT_STUB_REPO="$repo_bob" \
    HOME="$home" PATH="$bin:$PATH" bash "$devprofile" verify)"
assert_out "verify ok" "$out" "Matches bob (dirs mapping)"
assert_out "verify ok" "$out" "All checks passed!"

repo_alice="$home/projects/alice"
mkdir -p "$repo_alice/.git/hooks"
cat > "$tmp/mismatch.cfg" <<'EOF'
user.name=Bob Work
user.email=bob@work.com
EOF
out="$(cd "$repo_alice" && GIT_STUB_CONFIG="$tmp/mismatch.cfg" GIT_STUB_REPO="$repo_alice" \
    HOME="$home" PATH="$bin:$PATH" bash "$devprofile" verify)"
# The verify box truncates its cells at 38 chars, so assert the stable prefix.
assert_out "verify mismatch" "$out" "Expected alice (alice@personal.com)"
assert_out "verify mismatch" "$out" "issue(s) found"

#=============================================================================
# [5] verify --install-hook - a displaced foreign pre-commit keeps firing
#     through the wrapper (the timestamped branch used to disable it).
#=============================================================================
# Case A: no pre-existing pre-commit.user -> foreign hook lands there and the
# wrapper runs it.
printf '#!/bin/sh\necho FOREIGN-A-FIRED\n' > "$repo_alice/.git/hooks/pre-commit"
chmod +x "$repo_alice/.git/hooks/pre-commit"
out="$(cd "$repo_alice" && GIT_STUB_CONFIG="$tmp/mismatch.cfg" GIT_STUB_REPO="$repo_alice" \
    HOME="$home" PATH="$bin:$PATH" bash "$devprofile" verify --install-hook)"
assert_out "install-hook A" "$out" "Pre-commit hook installed"
[ -f "$repo_alice/.git/hooks/pre-commit.user" ] || fail "case A: foreign hook not moved to pre-commit.user"
wrapper_out="$(cd "$repo_alice" && GIT_STUB_CONFIG="$tmp/mismatch.cfg" GIT_STUB_REPO="$repo_alice" \
    HOME="$home" PATH="$bin:$PATH" sh .git/hooks/pre-commit)"
assert_out "case A wrapper" "$wrapper_out" "Committing as: Bob Work <bob@work.com>"
assert_out "case A wrapper" "$wrapper_out" "FOREIGN-A-FIRED"

# Case B: pre-commit.user already taken -> foreign hook lands on
# pre-commit.user.<ts> and the wrapper must run BOTH user hooks. This is the
# regression: the wrapper used to know only $user_hook, so the timestamped
# hook silently stopped firing.
printf '#!/bin/sh\necho USER-B-FIRED\n' > "$repo_bob/.git/hooks/pre-commit.user"
printf '#!/bin/sh\necho FOREIGN-B-FIRED\n' > "$repo_bob/.git/hooks/pre-commit"
chmod +x "$repo_bob/.git/hooks/pre-commit.user" "$repo_bob/.git/hooks/pre-commit"
out="$(cd "$repo_bob" && GIT_STUB_CONFIG="$tmp/bob.cfg" GIT_STUB_REPO="$repo_bob" \
    HOME="$home" PATH="$bin:$PATH" bash "$devprofile" verify --install-hook)"
assert_out "install-hook B" "$out" "Existing pre-commit moved"
moved="$(find "$repo_bob/.git/hooks" -name 'pre-commit.user.*' -type f | head -n 1)"
[ -n "$moved" ] || fail "case B: foreign hook not moved to a timestamped pre-commit.user"
require "$moved" 'FOREIGN-B-FIRED'
wrapper_out="$(cd "$repo_bob" && GIT_STUB_CONFIG="$tmp/bob.cfg" GIT_STUB_REPO="$repo_bob" \
    HOME="$home" PATH="$bin:$PATH" sh .git/hooks/pre-commit)"
assert_out "case B wrapper" "$wrapper_out" "USER-B-FIRED"
assert_out "case B wrapper" "$wrapper_out" "FOREIGN-B-FIRED"

#=============================================================================
# [6] devprofile init - colors go through printf (echo printed the ${CYAN}
#     escape literally), and explicit flags beat DEVPROFILE_PASSPHRASE.
#=============================================================================
: > "$tmp/ssh-keygen.log"
out="$(HOME="$home" PATH="$bin:$PATH" SSH_KEYGEN_LOG="$tmp/ssh-keygen.log" DEVPROFILE_PASSPHRASE=1 \
    bash "$devprofile" init newuser new@user.example --no-passphrase)"
# The color variables hold single-quoted backslash sequences, so an echo of
# "${CYAN}..." prints the literal characters \033[0;36m - this is the #122 bug.
# printf renders them as a real ESC byte; assert exactly that.
esc=$'\033'
if grep -Fq "${esc}[0;36m" <<<"$out"; then
    pass
else
    fail "init: 'Authentication key' heading must render cyan via printf"
fi
if grep -Fq '\033[0;36m' <<<"$out"; then
    fail "init: color escape printed literally (echo instead of printf)"
else
    pass
fi
if grep -Fq '\033[0;33m' <<<"$out"; then
    fail "init: second color escape printed literally (echo instead of printf)"
else
    pass
fi
assert_out "init output" "$out" "Authentication key"
assert_out "init output" "$out" "Signing key"
if grep -Fq -- '-N' "$tmp/ssh-keygen.log"; then
    pass
else
    fail "init: --no-passphrase must win over DEVPROFILE_PASSPHRASE=1 (ssh-keygen needs -N)"
fi
if grep -Fq -- '-C new@user.example-sign' "$tmp/ssh-keygen.log"; then
    pass
else
    fail "init: signing key comment must be <email>-sign (allowed_signers scans rely on it)"
fi

: > "$tmp/ssh-keygen.log"
HOME="$home" PATH="$bin:$PATH" SSH_KEYGEN_LOG="$tmp/ssh-keygen.log" DEVPROFILE_PASSPHRASE=0 \
    bash "$devprofile" init flagwin flag@win.example --passphrase >/dev/null
if grep -Fq -- '-N' "$tmp/ssh-keygen.log"; then
    fail "init: --passphrase must win over DEVPROFILE_PASSPHRASE=0 (ssh-keygen must not get -N)"
else
    pass
fi

: > "$tmp/ssh-keygen.log"
HOME="$home" PATH="$bin:$PATH" SSH_KEYGEN_LOG="$tmp/ssh-keygen.log" DEVPROFILE_PASSPHRASE=0 \
    bash "$devprofile" init envwin env@win.example >/dev/null
if grep -Fq -- '-N' "$tmp/ssh-keygen.log"; then
    pass
else
    fail "init: DEVPROFILE_PASSPHRASE=0 must still apply when no flag is given (ssh-keygen needs -N)"
fi

#=============================================================================
# [7] help prints nothing version-y; the dead VERSION variable is gone.
#=============================================================================
help_out="$(run_dev help)"
if grep -Eqi 'version|2\.0\.0' <<<"$help_out"; then
    fail "help output must not mention a version"
else
    pass
fi
if grep -Fq 'VERSION="' "$devprofile"; then
    fail "the dead VERSION variable must not come back"
else
    pass
fi

finish
