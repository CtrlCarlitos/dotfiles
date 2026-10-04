#!/usr/bin/env bash
set -euo pipefail

# Windows python3 parity: the official Python installer (choco `python`) ships
# python.exe and the `py` launcher, never python3. POSIX has python3, so the
# repo's scripts and tests assume it. Windows gets two tiny shims in
# ~/.local/bin that forward to `python`: a bash one for Git Bash and a .cmd for
# cmd/PowerShell. They are Windows-only (every other OS has a real python3 and a
# shim would shadow it). The doctor's python3 check: tests/dotfiles_doctor.ps1.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

sh_shim="$repo_root/dot_local/bin/executable_python3"
cmd_shim="$repo_root/dot_local/bin/python3.cmd"

[ -f "$sh_shim" ] || fail "$sh_shim missing"
[ -f "$cmd_shim" ] || fail "$cmd_shim missing"

if [ -f "$sh_shim" ]; then
    head -n1 "$sh_shim" | grep -Fxq '#!/usr/bin/env bash' || fail 'bash shim must start with #!/usr/bin/env bash'
    require "$sh_shim" 'exec python "$@"'
    # Forwarding to python3 would recurse into the shim itself.
    if grep -v '^#' "$sh_shim" | grep -Fq 'python3'; then
        fail 'bash shim must forward to `python`, never python3 (it would call itself)'
    fi
fi
if [ -f "$cmd_shim" ]; then
    require "$cmd_shim" '@echo off'
    require "$cmd_shim" 'python %*'
    if grep -v -i '^rem' "$cmd_shim" | grep -Fq 'python3'; then
        fail 'cmd shim must forward to `python`, never python3 (it would call itself)'
    fi
fi

# Windows-only deployment, asserted by rendering .chezmoiignore with the OS
# forced (the verdict must not depend on the runner).
command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed'
empty_config="$(mktemp -d)/empty.toml"
: > "$empty_config"
ignored() { # $1 = os ; prints the rendered .chezmoiignore
    CI=1 chezmoi execute-template --config "$empty_config" --source "$repo_root" \
        --override-data "{\"chezmoi\":{\"os\":\"$1\",\"kernel\":{\"osrelease\":\"6.8.0-generic\"}}}" \
        < "$repo_root/.chezmoiignore"
}
for os in linux darwin; do
    out="$(ignored "$os")"
    for target in '.local/bin/python3' '.local/bin/python3.cmd'; do
        printf '%s\n' "$out" | grep -Fxq "$target" ||
            fail "$os: $target must be ignored (a real python3 exists; the shim would shadow it)"
    done
done
win="$(ignored windows)"
for target in '.local/bin/python3' '.local/bin/python3.cmd'; do
    if printf '%s\n' "$win" | grep -Fxq "$target"; then
        fail "windows: $target must be deployed, not ignored"
    fi
done

# The operator-facing explanation: why there is a shim, the stub that shadows it,
# the cure, and the doctor check that finds it.
doc="$repo_root/docs/windows.md"
require "$doc" 'python3 on Windows'
require "$doc" 'App execution aliases'
require "$doc" 'dotfiles-doctor.ps1" -Fix'
require "$doc" 'python3.cmd'

finish
