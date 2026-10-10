#!/usr/bin/env bash
# shellcheck disable=SC2031,SC2034  # tmp is only read in the subshells that run the extracted block; npm_sudo is the block's
set -euo pipefail

# Codex MCP registration contract: `serena setup codex` must run AFTER the
# Codex CLI install in BOTH installer twins. The registration used to live in the serena section, which runs
# before the install: on a machine where codex is absent until that very run
# (fresh setup, or a deliberate removal + reinstall) the early call skipped
# and codex stayed MCP-less forever (observed live 2026-09-29, codex 0.159.0
# reinstalled by the same run that skipped its registration).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"

. "$repo_root/tests/lib.sh"

order_check() { # $1 = file, $2 = install marker, $3 = twin label
    grep -Fq 'serena setup codex' "$1" || fail "$1: serena setup codex missing"
    # Graft was dropped (2026-10-09): nothing registers it for Codex any more.
    ! grep -Fq 'codex mcp add graft' "$1" || fail "$1: graft must no longer be registered for codex"
    local count install_line setup_line
    count=$(grep -cF 'serena setup codex' "$1")
    [ "$count" -eq 1 ] || fail "$3: serena setup codex must appear on exactly one line (the early skip is the bug); got $count"
    install_line=$(grep -nF "$2" "$1" | head -1 | cut -d: -f1)
    setup_line=$(grep -nF 'serena setup codex' "$1" | head -1 | cut -d: -f1)
    [ -n "$install_line" ] || fail "$3: install marker '$2' not found"
    [ "$setup_line" -gt "$install_line" ] ||
        fail "$3: serena setup codex (line $setup_line) must come after the Codex CLI install (line $install_line)"
}

order_check "$ps1_tmpl" 'Installing Codex CLI' 'ps1 twin'
order_check "$sh_tmpl" 'Installing Codex CLI...' 'sh twin'

# The steady-state run says what it did. "Installing Codex CLI..." printed on every run,
# including the ones that installed nothing (a `dot upgrade` a minute later upgraded codex,
# 2026-10-09), so the install-if-missing skip now has a line of its own - the agent-browser
# wording, in both twins.
skip_line='Codex CLI is installed - skipping the npm install (dot upgrade updates it).'
require "$sh_tmpl" "$skip_line"
require "$ps1_tmpl" "$skip_line"

# Executed (sh): the rendered block with a stub npm and a stub codex on PATH.
command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed (render needed for the executed check)'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
render_to "$tmp/sh.sh" sh '{"chatgpt_cli":true}'
awk '/^    if command -v npm &>\/dev\/null; then$/{buf=""; f=1} f{buf=buf $0 "\n"} f && /^    fi$/{f=0; if (buf ~ /Codex CLI/) printf "%s", buf}' "$tmp/sh.sh" >"$tmp/block.sh"
grep -Fq 'Installing Codex CLI' "$tmp/block.sh" || { fail "sh twin: the Codex install block was not found in the render"; finish; }
mkdir -p "$tmp/with-codex" "$tmp/no-codex"
for d in with-codex no-codex; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"${NPM_LOG:?}"\nexit 0\n' >"$tmp/$d/npm"
    printf '#!/bin/sh\necho "%s/npm"\n' "$tmp/$d" >"$tmp/$d/which"
    chmod +x "$tmp/$d/npm" "$tmp/$d/which"
done
printf '#!/bin/sh\nexit 0\n' >"$tmp/with-codex/codex"
chmod +x "$tmp/with-codex/codex"
codex_run() { # $1 = PATH for the block; prints its output
    ( trap - EXIT; . "$repo_root/scripts/lib/agent-skills.sh"; export NPM_LOG="$tmp/npm.log"; npm_sudo=""
        PATH="$1"; . "$tmp/block.sh" ) 2>&1
}
: >"$tmp/npm.log"
out="$(codex_run "$tmp/with-codex")"
printf '%s\n' "$out" | grep -Fq "$skip_line" || fail "sh twin: an installed, runnable codex must print the skip line (got: $out)"
if printf '%s\n' "$out" | grep -Fq 'Installing Codex CLI'; then fail "sh twin: must not say Installing when it installs nothing (got: $out)"; else pass; fi
if grep -Fq 'install -g' "$tmp/npm.log"; then fail "sh twin: an installed codex must not be reinstalled by dot up"; else pass; fi
: >"$tmp/npm.log"
out="$(codex_run "$tmp/no-codex")"
printf '%s\n' "$out" | grep -Fq 'Installing Codex CLI...' || fail "sh twin: a missing codex must say Installing (got: $out)"
grep -Fq 'install -g' "$tmp/npm.log" || fail "sh twin: a missing codex must be installed through npm -g"
pass
# A codex that exists but cannot start (npm skipped its platform binary - tests/codex_platform_binary_contract.sh)
# is reinstalled, not skipped.
mkdir -p "$tmp/broken-codex"
cp "$tmp/no-codex/npm" "$tmp/no-codex/which" "$tmp/broken-codex/"
printf '#!/bin/sh\necho "%s/npm"\n' "$tmp/broken-codex" >"$tmp/broken-codex/which"
printf '#!/bin/sh\nexit 1\n' >"$tmp/broken-codex/codex"
chmod +x "$tmp/broken-codex/codex" "$tmp/broken-codex/which"
: >"$tmp/npm.log"
out="$(codex_run "$tmp/broken-codex")"
if printf '%s\n' "$out" | grep -Fq "$skip_line"; then fail "sh twin: a codex that cannot start must not be skipped (got: $out)"; else pass; fi
grep -Fq 'install -g' "$tmp/npm.log" || fail "sh twin: a codex that cannot start must be reinstalled"
pass

finish
