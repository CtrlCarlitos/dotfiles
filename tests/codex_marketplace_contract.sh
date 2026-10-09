#!/usr/bin/env bash
set -euo pipefail

# The Codex plugin marketplace name is resolved at RUNTIME, never hardcoded.
#
# All four consumers used to pass `superpowers@openai-curated-remote`, which
# does not exist on the installed codex. The two install paths ended in
#   Error: plugin `superpowers` was not found in marketplace `openai-curated-remote`
# and the two update paths printed "Superpowers not installed for Codex" with
# the real error swallowed by a redirect - a misdiagnosis, since the plugin was
# installed and the add was failing on a nonexistent marketplace.
#
# Correcting the literal would not have held: the name is genuinely volatile.
# It resolved to `openai-curated` one morning and `openai-api-curated` the same
# evening. So the rule is the resolution, not any particular value - codex
# itself (`codex plugin list`, one `<plugin>@<marketplace>` row per available
# plugin) is the only source. The helpers are
# codex_superpowers_marketplace (scripts/lib/agent-skills.sh) and
# Get-CodexSuperpowersMarketplace (scripts/lib/ps-skills.ps1).
#
# Both helpers are EXECUTED here against the same stub codex, so the twins
# cannot drift in behaviour either - the same premise as
# tests/guardrail_console_filter_contract.sh.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

sh_lib="$repo_root/scripts/lib/agent-skills.sh"
ps_lib="$repo_root/scripts/lib/ps-skills.ps1"
consumers=(
    "$repo_root/run_onchange_install_packages.sh.tmpl"
    "$repo_root/run_onchange_install_packages.ps1.tmpl"
    "$repo_root/scripts/update_ai_tools.sh"
    "$repo_root/scripts/update_ai_tools.ps1"
)

# 1. No `codex plugin add` may name a literal marketplace: the argument has to
#    be a variable the helper filled in. Scoped to the codex call on purpose -
#    `superpowers@superpowers-marketplace` (Claude Code's own marketplace) and
#    `superpowers@git+https://...` (the OpenCode npm spec) are correct literals
#    elsewhere in these same files, and only Codex's name is the volatile one.
#    Prose keeps the dead name on purpose, as the record of why this exists; a
#    marketplace name in a comment cannot execute, so unlike a credential shape
#    there is nothing for it to hide.
for f in "$sh_lib" "$ps_lib" "${consumers[@]}"; do
    [ -f "$f" ] || fail "missing consumer: $f"
    hits="$(grep -nE 'codex[[:space:]]+plugin[[:space:]]+add.*superpowers@[A-Za-z0-9_-]' "$f" || true)"
    if [ -n "$hits" ]; then
        fail "$(basename "$f"): \`codex plugin add\` names a literal marketplace - resolve it at runtime: $(printf '%s' "$hits" | head -2)"
    else
        pass
    fi
done

# 2. Every consumer must actually call its language's helper, so the contract
#    cannot be satisfied by deleting the install step.
for f in "${consumers[@]}"; do
    case "$f" in
        *.ps1|*.ps1.tmpl) want='Get-CodexSuperpowersMarketplace' ;;
        *)                want='codex_superpowers_marketplace' ;;
    esac
    if grep -Fq "$want" "$f"; then pass; else fail "$(basename "$f"): must resolve the marketplace via $want"; fi
done

# 3. Executed parity: both helpers, same stub codex, same answer.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
make_stub() { # $1 = the superpowers row to print (empty for "no such plugin")
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then\n'
        printf '  printf %%s\\\\n "PLUGIN STATUS VERSION PATH"\n'
        printf '  printf %%s\\\\n "github@test-marketplace not installed"\n'
        [ -n "$1" ] && printf '  printf %%s\\\\n "%s"\n' "$1"
        printf '  exit 0\nfi\nexit 0\n'
    } >"$tmp/bin/codex"
    chmod +x "$tmp/bin/codex"
    # Native Windows pwsh resolves a bare command through its own extension list (.ps1 among
    # them, independent of $env:PATHEXT) - an extensionless POSIX stub is invisible to that
    # resolution, so bare `codex` falls straight through this PATH entry to any real,
    # globally-installed codex.ps1 further down PATH instead of this stub (found live: a real
    # codex on PATH hijacked the "fake" marketplace answer, so the PowerShell twin was actually
    # exercising production Codex, not the stub). Mirror the same fake rows in a .ps1 sibling so
    # native Windows pwsh shadows the real one too; bash never sees this file, it still matches
    # the extensionless "codex" by exact name.
    {
        printf 'if ($args[0] -eq "plugin" -and $args[1] -eq "list") {\n'
        printf '    "PLUGIN STATUS VERSION PATH"\n'
        printf '    "github@test-marketplace not installed"\n'
        [ -n "$1" ] && printf '    "%s"\n' "$1"
        printf '}\n'
    } >"$tmp/bin/codex.ps1"
}

sh_answer() { PATH="$tmp/bin:$PATH" bash -c '. "$1"; codex_superpowers_marketplace' _ "$sh_lib"; }
# pwsh needs a Windows-style path to dot-source - a POSIX one ("/c/Users/...") embedded in a
# -Command string fails to resolve, and the 2>/dev/null below used to swallow that failure
# silently, so this looked like a marketplace-parsing bug instead of a path format one.
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
ps_lib_win="$(winpath "$ps_lib")"
ps_answer() { PATH="$tmp/bin:$PATH" pwsh -NoProfile -Command ". '$ps_lib_win'; \$m = Get-CodexSuperpowersMarketplace; if (\$m) { Write-Output \$m }" 2>/dev/null | tr -d '\r'; }

make_stub 'superpowers@test-marketplace not installed'
sh_got="$(sh_answer || true)"
[ "$sh_got" = "test-marketplace" ] || fail "shell helper: expected test-marketplace, got '$sh_got'"
pass

# An absent superpowers row must yield nothing - callers treat empty as a skip,
# never as a marketplace named "".
make_stub ''
sh_empty="$(sh_answer || true)"
[ -z "$sh_empty" ] || fail "shell helper: a codex with no superpowers plugin must return nothing, got '$sh_empty'"
pass

if command -v pwsh >/dev/null 2>&1; then
    make_stub 'superpowers@test-marketplace not installed'
    ps_got="$(ps_answer || true)"
    [ "$ps_got" = "test-marketplace" ] || fail "PowerShell helper: expected test-marketplace, got '$ps_got'"
    [ "$ps_got" = "$sh_got" ] || fail "twins disagree: shell '$sh_got' vs PowerShell '$ps_got'"
    pass

    make_stub ''
    ps_empty="$(ps_answer || true)"
    [ -z "$ps_empty" ] || fail "PowerShell helper: a codex with no superpowers plugin must return nothing, got '$ps_empty'"
    pass
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

finish
