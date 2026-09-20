#!/usr/bin/env bash
set -euo pipefail

# VS Code global-extensions contract: the curated list lives in
# .chezmoidata.yaml (single source of truth), rendered into BOTH installers,
# installed idempotently, gated by vscode_settings. The operator explicitly
# VETOED two extensions during curation - they must never return. SSH hosts:
# machine-local [[data.ssh_hosts]] in chezmoi.toml renders through
# private_dot_ssh/private_config.tmpl with a comment field so the config is
# self-documenting.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
data="$repo_root/.chezmoidata.yaml"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
ssh_tmpl="$repo_root/private_dot_ssh/private_config.tmpl"
config_tmpl="$repo_root/.chezmoi.toml.tmpl"
docs="$repo_root/docs/secrets.md"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'vscode:' "$data" || fail ".chezmoidata.yaml: no vscode.extensions block"
grep -Fq 'EditorConfig.EditorConfig' "$data" || fail "data: EditorConfig missing"
grep -Fq 'ms-azuretools.vscode-docker' "$data" || fail "data: docker extension missing"
grep -Fq 'ms-azuretools.vscode-containers' "$data" || fail "data: containers extension missing"
grep -Fq 'rahulraghunathb.excel-lite' "$data" || fail "data: excel-lite missing (replaced edit-csv)"
grep -Fq 'extensions_windows:' "$data" || fail "data: no Windows-only list (remote-wsl)"

# Operator veto, contract-enforced: these must never return.
! grep -Fq 'eamodio.gitlens' "$data" || fail "data: gitlens is VETOED by the operator"
! grep -Fq 'Gruntfuggly.todo-tree' "$data" || fail "data: todo-tree is VETOED by the operator"

for f in "$sh_installer" "$ps1_installer"; do
    grep -Fq -- '--install-extension' "$f" || fail "$f: no extension install step"
done

# SSH: template renders [[data.ssh_hosts]] with the self-documenting comment.
grep -Fq 'ssh_hosts' "$ssh_tmpl" || fail "ssh template: no ssh_hosts rendering"
grep -Fq 'comment' "$ssh_tmpl" || fail "ssh template: no comment field support"
grep -Fq 'ProxyJump' "$ssh_tmpl" || fail "ssh template: no proxy field support"

# Two generated aliases must remain visibly separate in the rendered config.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/chezmoi.toml"
rendered=$(chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
    --override-data '{"chezmoi":{"os":"linux"},"accounts":[],"ssh_hosts":[{"name":"first","hostname":"first.example"},{"name":"second","hostname":"second.example"}]}' \
    <"$ssh_tmpl")
expected=$'Host first\n    HostName first.example\n\nHost second\n    HostName second.example'
[[ "$rendered" == *"$expected"* ]] ||
    fail "ssh template: generated aliases need one blank separator"

# Secrets pattern documented.
grep -Fqi 'ssh_hosts' "$docs" || fail "docs/secrets.md: ssh_hosts not documented"
grep -Fqi 'never' "$docs" || fail "docs/secrets.md: git-never-sees-it caveat missing"

# Machine-local drift: overrides live in [data.vscode_overrides] (NOT
# [data.vscode] - chezmoi does not deep-merge same-named tables; the config
# table would be wholesale-shadowed. Confirmed live.). Both installers must
# read that key for extensions AND settings.
for f in "$sh_installer" "$ps1_installer"; do
    grep -Fq 'vscode_overrides' "$f" || fail "$f: no vscode_overrides merge"
    grep -Fq 'exclude_settings' "$f" || fail "$f: no settings exclusion support"
    grep -Fq 'extra_settings' "$f" || fail "$f: no extra-settings support"
done
grep -Fqi 'vscode_overrides' "$repo_root/docs/vscode.md" || fail "docs/vscode.md: overrides not documented"

# Config-template order is semantic in TOML and mirrors the operator-facing
# flow: dev_desktop, its VS Code gate, overrides, accounts, then SSH hosts.
dev_desktop_line=$(grep -n 'dev_desktop = ' "$config_tmpl" | head -n1 | cut -d: -f1)
settings_line=$(grep -n 'vscode_settings = ' "$config_tmpl" | head -n1 | cut -d: -f1)
overrides_line=$(grep -n '{{/\* vscode_overrides:' "$config_tmpl" | cut -d: -f1)
accounts_line=$(grep -n '^\[\[data\.accounts\]\]$' "$config_tmpl" | head -n1 | cut -d: -f1)
ssh_hosts_line=$(grep -n '{{/\* ssh_hosts:' "$config_tmpl" | cut -d: -f1)
(( dev_desktop_line < settings_line && settings_line < overrides_line && overrides_line < accounts_line && accounts_line < ssh_hosts_line )) || fail "config template: machine-local blocks are out of order"
for package_key in remote_access remote_access_server guardrail; do
    package_line=$(grep -n "    $package_key = " "$config_tmpl" | head -n1 | cut -d: -f1)
    (( package_line < overrides_line )) || fail "config template: $package_key must stay in [data.packages]"
done

# JSON object syntax is not TOML inline-table syntax (`:` vs `=`). Map values
# in extra_settings therefore require a TOML serializer, not toJson.
! grep -Fq '{{ $v | toJson }}' "$config_tmpl" || fail "config template: extra_settings maps emit invalid TOML JSON"
grep -Fq 'replace "[vscode_overrides" "[data.vscode_overrides"' "$config_tmpl" || fail "config template: override serializer must not redefine [data]"

# Generated config documents active machine-local blocks, not only empty ones.
grep -Fq 'VS Code Machine-Local Overrides' "$config_tmpl" || fail "config template: active VS Code overrides lack documentation"
grep -Fq 'SSH Host Aliases' "$config_tmpl" || fail "config template: active SSH hosts lack documentation"

# The gate belongs to [data.packages], alongside dev_desktop, in both installers.
for f in "$sh_installer" "$ps1_installer"; do
    grep -Fq 'hasKey .packages "vscode_settings"' "$f" || fail "$f: vscode_settings must be read from packages"
done

# Settings/extensions are independent of font installation. On Windows, the
# fonts gate therefore applies only to the Windows Terminal mutation, before
# the shared VS Code management block.
grep -Fq $'{{- if $fonts }}\nif ($wtSettings)' "$ps1_installer" ||
    fail "$ps1_installer: fonts gate must start at Windows Terminal settings"
grep -Fq $'}\n{{- end }}\n\n# User-level global settings' "$ps1_installer" ||
    fail "$ps1_installer: fonts gate must end before VS Code management"

# First-run devcontainers have no [data.packages] table. The guard must check
# for that table before reading its VS Code gate. The end-to-end devcontainer
# CI job also initializes this template on every pull request.
grep -Fq 'if and (hasKey . "packages") (hasKey .packages "vscode_settings")' "$config_tmpl" ||
    fail "config template: vscode_settings must guard a missing packages table"
if command -v chezmoi >/dev/null; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" CI=true DEVCONTAINER=true \
        chezmoi init --source="$repo_root" >/dev/null ||
        fail "config template: first-run devcontainer initialization failed"
    grep -Fq 'email = "devcontainer@local"' "$tmp/config/chezmoi/chezmoi.toml" ||
        fail "config template: first-run devcontainer identity missing"
fi

grep -Fq -- 'bash tests/vscode_ssh_contract.sh' "$repo_root/.github/workflows/ci.yml" || {
    printf 'FAIL: ci.yml: vscode/ssh contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: VS Code extensions + ssh_hosts contracts\n'
