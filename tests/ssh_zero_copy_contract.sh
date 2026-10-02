#!/usr/bin/env bash
# Rendered routing must use stable per-identity sockets with no WSL key files.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/empty.toml"
data='{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8-microsoft"}},"accounts":[{"name":"Fixture","email":"a@example.test","username":"fixture","provider":"github","key":"id_git","auth_fingerprint":"SHA256:auth","signing_fingerprint":"SHA256:sign"}],"ssh_hosts":[{"name":"server1","hostname":"one.example.test","identity":"id_server","identity_fingerprint":"SHA256:host"},{"name":"server2","hostname":"two.example.test","identity":"id_server","identity_fingerprint":"SHA256:host"}]}'
export SSH_AGENT_RELAY_DIR="$tmp/state"
chezmoi execute-template --config "$tmp/empty.toml" --source "$root" --override-data "$data" < "$root/private_dot_ssh/private_config.tmpl" > "$tmp/config"
if grep -q 'IdentityFile ~/.ssh/' "$tmp/config"; then echo 'FAIL: WSL local identity requirement'; exit 1; fi
for alias in github-fixture server1 server2; do
    ssh -G -F "$tmp/config" "$alias" > "$tmp/$alias"
    grep -q '^identityfile none$' "$tmp/$alias"
    grep -q '^identitiesonly no$' "$tmp/$alias"
done
host1="$(awk '$1 == "identityagent" {print $2}' "$tmp/server1")"
host2="$(awk '$1 == "identityagent" {print $2}' "$tmp/server2")"
[ "$host1" = "$host2" ]
grep -Fq "identityagent $tmp/state/github-fixture.agent" "$tmp/github-fixture"
chezmoi execute-template --config "$tmp/empty.toml" --source "$root" --override-data "$data" < "$root/dot_local/bin/executable_ssh-agent-relay.tmpl" > "$tmp/relay"
[ "$(grep -c 'RELAY_ALIASES+=("host-' "$tmp/relay")" -eq 1 ]
conflict="$(printf '%s' "$data" | jq '.ssh_hosts[1].identity_fingerprint="SHA256:other"')"
if chezmoi execute-template --config "$tmp/empty.toml" --source "$root" --override-data "$conflict" < "$root/dot_local/bin/executable_ssh-agent-relay.tmpl" > /dev/null 2>&1; then
    echo 'FAIL: conflicting host identity mapping accepted'; exit 1
fi
echo 'PASS: WSL routes by filtered socket, shares same-identity hosts, rejects conflicting mappings'
