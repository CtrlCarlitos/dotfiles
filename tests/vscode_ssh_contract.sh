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

grep -Fq -- 'bash tests/vscode_ssh_contract.sh' "$repo_root/.github/workflows/ci.yml" || {
    printf 'FAIL: ci.yml: vscode/ssh contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: VS Code extensions + ssh_hosts contracts\n'
