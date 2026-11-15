#!/usr/bin/env bash
set -euo pipefail

# `provider` is optional in [[data.accounts]] (default github): the identities
# templates guard it with hasKey where they derive the alias. Two later uses
# ({{ .provider }} in the agent inventory) did not, so an account without
# `provider` failed the render with `map has no entry for key "provider"` -
# found only because tests/ssh_acl_contract.sh renders such an account, and its
# executed block runs on Windows hosts only, never in CI. Both twins (invariant
# #10) are rendered here on every OS with the OS forced through --override-data.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed'
empty_config="$(mktemp -d)/empty.toml"
: > "$empty_config"

accounts='"accounts":[
  {"name":"Test User","email":"t@example.com","username":"test","key":"id_test"},
  {"name":"Other","email":"o@example.com","username":"other","provider":"gitlab","key":"id_other"}]'

# ssh_hosts identities must land in both generators' declared agent-key lists
# (issue #477): the vscode_hosts selector (IdentityFile <identity>.pub +
# IdentitiesOnly) only works when the agent holds the matching private key, and
# nothing else loads host keys. Two hosts share id_host (dedup asserted); the
# third has no identity (contributes nothing).
ssh_hosts='"ssh_hosts":[
  {"name":"web","hostname":"web.example.com","identity":"id_host"},
  {"name":"bioptic","hostname":"bio.example.com","identity":"id_host"},
  {"name":"nokey","hostname":"n.example.com"}]'

render() { # $1 = template, $2 = os
    CI=1 chezmoi execute-template --config "$empty_config" --source "$repo_root" \
        --override-data "{\"chezmoi\":{\"os\":\"$2\",\"kernel\":{\"osrelease\":\"6.8.0-generic\"}},$accounts,$ssh_hosts}" \
        < "$repo_root/$1" 2>&1
}

sh_out="$(render run_onchange_generate_identities.sh.tmpl linux)" || { fail "sh twin did not render: $sh_out"; sh_out=''; }
if [ -n "$sh_out" ]; then
    printf '%s\n' "$sh_out" | grep -Fq 'agent github-test: configured for id_test' ||
        fail 'sh twin: an account without provider must default to github (agent github-test)'
    printf '%s\n' "$sh_out" | grep -Fq 'agent gitlab-other: configured for id_other' ||
        fail 'sh twin: an explicit provider must be kept (agent gitlab-other)'
    printf '%s\n' "$sh_out" | grep -Fq '"id_host"' ||
        fail 'sh twin: the ssh_hosts identity must be in the declared key list'
    printf '%s\n' "$sh_out" | grep -Fq '_ssh_seen' ||
        fail 'sh twin: hosts sharing a key name must be deduped by the seen guard'
    pass
fi

ps1_out="$(render run_onchange_generate_identities.ps1.tmpl windows)" || { fail "ps1 twin did not render: $ps1_out"; ps1_out=''; }
if [ -n "$ps1_out" ]; then
    printf '%s\n' "$ps1_out" | tr -d '\r' | grep -Fq "\$identityEmails['github-test'] = 't@example.com'" ||
        fail "ps1 twin: an account without provider must default to github (github-test)"
    printf '%s\n' "$ps1_out" | tr -d '\r' | grep -Fq "\$identityEmails['gitlab-other'] = 'o@example.com'" ||
        fail "ps1 twin: an explicit provider must be kept (gitlab-other)"
    printf '%s\n' "$ps1_out" | tr -d '\r' | grep -Fq "'id_host'" ||
        fail "ps1 twin: the ssh_hosts identity must be in \$declaredKeys"
    printf '%s\n' "$ps1_out" | tr -d '\r' | grep -Fq 'Select-Object -Unique' ||
        fail 'ps1 twin: hosts sharing a key name must be deduped (Select-Object -Unique)'
    pass
fi

finish
