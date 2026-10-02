#!/usr/bin/env bash
set -euo pipefail

# Which machine-local tables .chezmoi.toml.tmpl emits where. Each table is only
# re-emitted when this machine's config already carries it, so the gates decide
# what `chezmoi init` keeps:
#   ssh_hosts      everywhere except WSL (hosts are declared on the Windows side)
#   remote_access  everywhere except WSL (Windows owns it; WSL's sshd is reached
#                  through the Windows portproxy)
#   interpreters.ps1  windows and macOS only
# The OS is forced through --override-data so the verdict does not depend on
# the runner. WSL = linux with "microsoft" in kernel.osrelease.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmpl="$repo_root/.chezmoi.toml.tmpl"
empty_config="$(mktemp -d)/empty.toml"
: > "$empty_config"
command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

render_init() { # $1 = --override-data JSON
    CI=1 chezmoi execute-template --init --config "$empty_config" --source "$repo_root" \
        --override-data "$1" < "$tmpl"
}

tables='"ssh_hosts":[{"name":"jump","hostname":"10.0.0.5"}],"remote_access":{"enabled":true}'
win="{\"chezmoi\":{\"os\":\"windows\"},$tables}"
mac="{\"chezmoi\":{\"os\":\"darwin\"},$tables}"
lin="{\"chezmoi\":{\"os\":\"linux\",\"kernel\":{\"osrelease\":\"6.8.0-generic\"}},$tables}"
wsl="{\"chezmoi\":{\"os\":\"linux\",\"kernel\":{\"osrelease\":\"5.15.0-microsoft-standard-WSL2\"}},$tables}"

# live OUT NAME: is there an uncommented [NAME] or [[NAME]] header in OUT?
live() {
    local escaped="${2//./\.}"
    printf '%s\n' "$1" | grep -Eq "^[[:space:]]*\[+${escaped}\]+\$"
}
# want/refuse LABEL OUT NAME: assert (and tally) that a header is / is not emitted.
want() { if live "$2" "$3"; then pass; else fail "$1: [$3] must be emitted"; fi; }
refuse() { if live "$2" "$3"; then fail "$1: [$3] must not be emitted"; else pass; fi; }

for name in win mac lin; do
    out="$(render_init "${!name}")"
    want "$name" "$out" data.ssh_hosts
    want "$name" "$out" data.remote_access
done

wsl_out="$(render_init "$wsl")"
refuse wsl "$wsl_out" data.ssh_hosts
refuse wsl "$wsl_out" data.remote_access
if printf '%s\n' "$wsl_out" | grep -Fq 'Remote Access ('; then
    fail 'wsl: the remote_access section (comments included) must be omitted'
else
    pass
fi

# interpreters.ps1: windows -> powershell, darwin -> pwsh, linux/wsl -> none.
want windows "$(render_init "$win")" interpreters.ps1
want darwin "$(render_init "$mac")" interpreters.ps1
refuse linux "$(render_init "$lin")" interpreters.ps1
refuse wsl "$wsl_out" interpreters.ps1

finish
