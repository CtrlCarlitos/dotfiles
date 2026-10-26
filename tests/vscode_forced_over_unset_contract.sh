#!/usr/bin/env bash
set -euo pipefail

# A key that is both FORCED and still listed in UNSET must end up SET, never
# removed. This happens for real on any machine whose chezmoi.toml predates a
# key's move into the forced tier - remote.SSH.configFile moved there
# (docs/vscode.md), but an existing machine's `unset = ["remote.SSH.configFile"]`
# survives `chezmoi init` verbatim (it writes an existing table back as-is).
# Both twins previously applied FORCED then UNSET as two independent,
# order-dependent loops with no cross-check, so the forced value was written
# and then immediately deleted again - every single `dot up`, forever, until
# an operator deleted the stale line by hand. Confirmed live on LAB-DOT-WIN-HOM
# (2026-10-24): "VS Code settings: 2 change(s) - remote.SSH.configFile
# (forced), remote.SSH.configFile (unset)" on every run.
#
# This extracts the REAL merge code from both rendered twins (not a
# reimplementation) and runs it against a fixture settings.json where a test
# key sits in both FORCED and UNSET, asserting the key survives.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps_t="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_t="$repo_root/run_onchange_install_packages.sh.tmpl"

. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

: >"$tmp/empty.toml"
chezmoi execute-template --config "$tmp/empty.toml" --source "$repo_root" \
    --override-data '{"chezmoi":{"os":"windows"},"packages":{}}' \
    <"$ps_t" | tr -d '\r' >"$tmp/rendered.ps1"
chezmoi execute-template --config "$tmp/empty.toml" --source "$repo_root" \
    --override-data '{"chezmoi":{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}},"packages":{}}' \
    <"$sh_t" >"$tmp/rendered.sh"

# ---------------------------------------------------------------- Python (.sh twin)
if command -v python3 >/dev/null 2>&1; then
    start=$(grep -n "python3 - \"\$settings\" <<'PYEOF'" "$tmp/rendered.sh" | head -1 | cut -d: -f1)
    [ -n "$start" ] || fail "sh twin: could not find the VS Code settings python heredoc"
    end=$(awk -v s="$start" 'NR>s && /^PYEOF$/{print NR; exit}' "$tmp/rendered.sh")
    [ -n "$end" ] || fail "sh twin: could not find the end of the VS Code settings python heredoc"
    sed -n "$((start + 1)),$((end - 1))p" "$tmp/rendered.sh" >"$tmp/merge.py"
    # Fixture: the same key in both FORCED and UNSET.
    python3 - "$tmp/merge.py" <<'FIXUP'
import re, sys
p = sys.argv[1]
text = open(p, encoding="utf-8").read()
text = re.sub(r'^FORCED = json\.loads.*$', 'FORCED = {"test.overlapKey": "forcedValue"}', text, flags=re.M)
text = re.sub(r'^UNSET = json\.loads.*$', 'UNSET = ["test.overlapKey"]', text, flags=re.M)
open(p, "w", encoding="utf-8").write(text)
FIXUP
    echo '{}' >"$tmp/settings.sh.json"
    python3 "$tmp/merge.py" "$tmp/settings.sh.json" >/dev/null 2>&1 || fail "sh twin: the extracted merge script errored"
    got="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('test.overlapKey', '<missing>'))" "$tmp/settings.sh.json")"
    [ "$got" = "forcedValue" ] ||
        fail "sh twin: a key in both forced and unset ended up '$got', not forced - unset is winning over forced"
    pass
else
    printf 'note: python3 not installed - sh twin check skipped\n'
fi

# ------------------------------------------------------------- PowerShell (.ps1 twin)
if command -v pwsh >/dev/null 2>&1; then
    elseif_line=$(grep -n '^} elseif (-not (Test-Path \$vscodeSettings)) {$' "$tmp/rendered.ps1" | head -1 | cut -d: -f1)
    [ -n "$elseif_line" ] || fail "ps1 twin: could not find the VS Code settings elseif branch"
    else_line=$(awk -v s="$elseif_line" 'NR>s && /^\} else \{$/{print NR; exit}' "$tmp/rendered.ps1")
    [ -n "$else_line" ] || fail "ps1 twin: could not find the matching else branch"
    try_line=$(awk -v s="$else_line" 'NR>s && /^    try \{$/{print NR; exit}' "$tmp/rendered.ps1")
    catch_line=$(awk -v s="$try_line" 'NR>s && /^    \} catch \{$/{print NR; exit}' "$tmp/rendered.ps1")
    end_line=$(awk -v s="$catch_line" 'NR>s && /^\}$/{print NR; exit}' "$tmp/rendered.ps1")
    [ -n "$try_line" ] && [ -n "$catch_line" ] && [ -n "$end_line" ] ||
        fail "ps1 twin: could not bound the try/catch merge block"
    sed -n "${try_line},$((end_line - 1))p" "$tmp/rendered.ps1" >"$tmp/merge_block.ps1"
    # The forced-wins-over-unset guard lives earlier in the script (with the
    # exclude_settings filtering), not inside the try/catch block above - it
    # must run against $vsForced/$vsUnset before the merge, same as live.
    precede_line=$(grep -n '^foreach (\$k in \$vsForced.Keys) { \[void\]\$vsUnset.Remove(\$k) }$' "$tmp/rendered.ps1" | head -1 | cut -d: -f1)
    [ -n "$precede_line" ] && sed -n "${precede_line}p" "$tmp/rendered.ps1" >"$tmp/precede.ps1" || : >"$tmp/precede.ps1"

    {
        awk '/^function ConvertTo-SortedJson/,/^}$/' "$tmp/rendered.ps1"
        awk '/^function ConvertFrom-JsonC/,/^}$/' "$tmp/rendered.ps1"
    } >"$tmp/helpers.ps1"
    [ -s "$tmp/helpers.ps1" ] || fail "ps1 twin: could not extract ConvertFrom-JsonC/ConvertTo-SortedJson"

    echo '{}' >"$tmp/settings.ps1.json"
    {
        printf '$vscodeSettings = %s\n' "'$(wp "$tmp/settings.ps1.json")'"
        printf "%s\n" '$vsForced = @{ "test.overlapKey" = "forcedValue" }'
        printf "%s\n" '$vsDefaults = [ordered]@{}'
        printf "%s\n" '$vsMerges = @{}'
        printf "%s\n" '$vsUnset = [System.Collections.Generic.List[string]]@("test.overlapKey")'
        cat "$tmp/helpers.ps1"
        cat "$tmp/precede.ps1"
        cat "$tmp/merge_block.ps1"
    } >"$tmp/harness.ps1"

    out="$(pwsh -NoProfile -File "$(wp "$tmp/harness.ps1")" 2>&1)" || fail "ps1 twin: harness errored: $out"
    got="$(pwsh -NoProfile -Command "(Get-Content -Raw '$(wp "$tmp/settings.ps1.json")' | ConvertFrom-Json).'test.overlapKey'" 2>&1)"
    [ "$got" = "forcedValue" ] ||
        fail "ps1 twin: a key in both forced and unset ended up '$got', not forced - unset is winning over forced"
    pass
else
    printf 'note: pwsh not installed - ps1 twin check skipped\n'
fi

finish
