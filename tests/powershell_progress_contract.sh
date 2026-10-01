#!/usr/bin/env bash
set -euo pipefail

# PowerShell download-progress contract: Windows PowerShell 5.1 redraws the
# Invoke-WebRequest / Expand-Archive progress bar for every received chunk,
# which throttles big downloads to a crawl (measured live 2026-09-30: the
# 161 MB Chrome MSI ran at ~6 MB/min on a link doing ~8 MB/s). The fix is
# `$ProgressPreference = 'SilentlyContinue'`, but the variable is per
# session: Start-Job jobs and child powershell processes do not inherit it, so
# each launch site has to set it again. This pins all three layers.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

silent='$ProgressPreference = '"'"'SilentlyContinue'"'"

# 1. Every Windows script that downloads sets it at its own top level.
#    (tests/ excluded: harness code, not a shipped download path.)
checked=0
while IFS= read -r f; do
    case "$f" in tests/*) continue ;; esac
    path="$repo_root/$f"
    [ -f "$path" ] || continue
    if grep -Eq 'Invoke-WebRequest|Invoke-RestMethod|(^|[^A-Za-z-])irm ' "$path"; then
        checked=$((checked + 1))
        if grep -Fq "$silent" "$path"; then pass; else
            fail "$f: downloads (Invoke-WebRequest / irm) but never sets $silent"
        fi
    fi
done < <(git -C "$repo_root" ls-files -- '*.ps1' '*.ps1.tmpl')
if [ "$checked" -ge 3 ]; then pass; else
    fail "expected to find at least 3 downloading PowerShell scripts, found $checked (pattern drifted?)"
fi

# 2. Invoke-WithTimeout runs its Action in Start-Job (a fresh process): the
#    session variable does not reach it, so the job gets an init script.
tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
if grep -E 'Start-Job' "$tmpl" | grep -Fq -- '-InitializationScript'; then pass; else
    fail "run_onchange_install_packages.ps1.tmpl: Start-Job must pass -InitializationScript"
fi
if grep -E 'Start-Job' "$tmpl" | grep -Fq 'ProgressPreference'; then pass; else
    fail "run_onchange_install_packages.ps1.tmpl: the Start-Job init script must set ProgressPreference"
fi

# 3. Child `powershell -c "irm ... | iex"` installers are separate processes:
#    the preference must be set inside the command string (backtick-escaped
#    so the parent does not expand it).
for f in run_onchange_install_packages.ps1.tmpl scripts/update_ai_tools.ps1; do
    # Any child powershell whose -c/-Command starts straight with irm is unprefixed.
    if grep -nE 'powershell[^|]*(-c|-Command) "irm ' "$repo_root/$f" >/dev/null; then
        fail "$f: a child powershell runs 'irm ... | iex' without setting ProgressPreference first"
    else
        pass
    fi
    n="$(grep -cE 'powershell[^|]*(-c|-Command) "`\$ProgressPreference = '"'"'SilentlyContinue'"'"'; irm ' "$repo_root/$f" || true)"
    if [ "$n" -ge 1 ]; then pass; else
        fail "$f: no prefixed 'irm | iex' child installer found (pattern drifted?)"
    fi
done

finish
