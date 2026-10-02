#!/usr/bin/env bash
# Real agent-backed Git signing with a keyless HOME; no network or real keys.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
agent_pid=''
trap '[ -z "$agent_pid" ] || kill "$agent_pid"; rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME/.local/bin" "$HOME/.local/lib" "$tmp/keys" "$tmp/project"
export PATH="$HOME/.local/bin:$PATH"
eval "$(ssh-agent -s)" >/dev/null
agent_pid="$SSH_AGENT_PID"
export TEST_AGENT_SOCK="$SSH_AUTH_SOCK"
ssh-keygen -q -t ed25519 -N '' -C 'test@example.test-sign' -f "$tmp/keys/sign"
ssh-add "$tmp/keys/sign" 2>/dev/null
cp "$repo_root/dot_local/bin/executable_git-agent" "$HOME/.local/bin/git-agent"
cp "$repo_root/dot_local/bin/executable_ssh-agent-key" "$HOME/.local/bin/ssh-agent-key"
cp "$repo_root/dot_local/lib/ssh_agent_key.py" "$HOME/.local/lib/ssh_agent_key.py"
chmod +x "$HOME/.local/bin/git-agent" "$HOME/.local/bin/ssh-agent-key"
cat > "$HOME/.local/bin/ssh-agent-relay" <<'EOF'
#!/usr/bin/env bash
[ "$1" = use ] && [ "$2" = github-fixture ] || exit 1
printf 'export SSH_AUTH_SOCK=%q\n' "$TEST_AGENT_SOCK"
EOF
chmod +x "$HOME/.local/bin/ssh-agent-relay"
: > "$tmp/empty.toml"
data="$(jq -n --arg home "$HOME" '{chezmoi:{os:"linux",homeDir:$home,kernel:{osrelease:"6.8-microsoft"}},accounts:[{name:"Fixture",email:"test@example.test",username:"fixture",provider:"github",key:"id_fixture",signingKey:"id_fixture_sign",dirs:[]}]}')"
fingerprint="$(ssh-keygen -E sha256 -lf "$tmp/keys/sign.pub" | awk '{print $2}')"
data="$(printf '%s' "$data" | jq --arg fp "$fingerprint" '.accounts[0].auth_fingerprint=$fp | .accounts[0].signing_fingerprint=$fp')"
chezmoi execute-template --config "$tmp/empty.toml" --source "$repo_root" --override-data "$data" \
    < "$repo_root/run_onchange_generate_identities.sh.tmpl" > "$tmp/generate"
bash "$tmp/generate"
chezmoi execute-template --config "$tmp/empty.toml" --source "$repo_root" --override-data "$data" \
    < "$repo_root/dot_gitconfig.tmpl" > "$HOME/.gitconfig"
# An unrelated ambient agent must not influence signing.
export SSH_AUTH_SOCK="$tmp/nonexistent"
git -C "$tmp/project" init -q
git -C "$tmp/project" -c core.hooksPath=/dev/null commit -q --allow-empty -m fixture
git -C "$tmp/project" verify-commit HEAD
if find "$HOME/.ssh" -name '*.pub' -o -name 'id_*' | grep -q .; then
    echo 'FAIL: generated local key files' >&2; exit 1
fi
# Duplicate comments must not change the fingerprint-selected identity.
ssh-keygen -q -t ed25519 -N '' -C 'test@example.test-sign' -f "$tmp/keys/duplicate"
SSH_AUTH_SOCK="$TEST_AGENT_SOCK" ssh-add "$tmp/keys/duplicate" 2>/dev/null
"$HOME/.local/bin/git-agent-github-fixture" key >/dev/null
SSH_AUTH_SOCK="$TEST_AGENT_SOCK" ssh-add -d "$tmp/keys/sign.pub" 2>/dev/null
if "$HOME/.local/bin/git-agent-github-fixture" key; then
    echo 'FAIL: missing fingerprint fell back to another key' >&2; exit 1
fi
echo 'PASS: WSL signs/verifies without local keys, ignores comment collisions, rejects missing fingerprints'
