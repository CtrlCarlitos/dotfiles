#!/usr/bin/env bash
set -euo pipefail

# Home-scope contract: what may land in $HOME.
#
# chezmoi applies everything in the source dir that .chezmoiignore doesn't
# exclude, so repo-only files leak into $HOME silently. Confirmed live: 29 CI
# test files in ~/tests, a stale ~/scripts (no dotupgrade.ps1, so `dot upgrade`
# and the home copy disagreed), ~/AGENTS.md, ~/graft, ~/guardrail.toml, and on
# Windows 15 MB of ~/.oh-my-zsh + ~/.tmux that no Windows shell can use.
# Everything here is referenced at its SOURCE path or not at all.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ignore="$repo_root/.chezmoiignore"

. "$repo_root/tests/lib.sh"

# Repo-only, every OS.
for p in 'tests/**' 'scripts/**' 'AGENTS.md' 'graft/**' 'guardrail.toml' 'devcontainer/**' 'docs/**' 'bin/**'; do
    grep -Fq "$p" "$ignore" || fail ".chezmoiignore: '$p' must never be applied to \$HOME"
done

# Unix-only trees: no zsh or tmux runs on Windows (WSL has its own home).
for p in '.oh-my-zsh/**' '.tmux/**'; do
    grep -Fq "$p" "$ignore" || fail ".chezmoiignore: '$p' must be excluded on Windows"
done

if command -v chezmoi >/dev/null; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    : >"$tmp/chezmoi.toml"
    render_ignore() {  # $1 = os, $2 = kernel osrelease (lib.sh's render is the no-override default)
        chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
            --override-data "{\"chezmoi\":{\"os\":\"$1\",\"kernel\":{\"osrelease\":\"$2\"},\"homeDir\":\"/nonexistent\"}}" \
            <"$ignore"
    }
    win=$(render_ignore windows '')
    for p in 'tests/**' 'scripts/**' 'AGENTS.md' 'graft/**' 'guardrail.toml' '.oh-my-zsh/**' '.tmux/**'; do
        printf '%s\n' "$win" | grep -Fxq "$p" || fail "windows: '$p' is not excluded"
    done
    # The zsh/tmux plugin trees are the point of the externals on Unix: keep them.
    lin=$(render_ignore linux '6.8.0-generic')
    for p in '.oh-my-zsh/**' '.tmux/**'; do
        ! printf '%s\n' "$lin" | grep -Fxq "$p" || fail "linux: '$p' must NOT be excluded (oh-my-zsh/tmux live there)"
    done
    for p in 'tests/**' 'scripts/**' 'AGENTS.md' 'graft/**'; do
        printf '%s\n' "$lin" | grep -Fxq "$p" || fail "linux: '$p' is not excluded"
    done
fi

# Devcontainers must not get SSH config or per-account gitconfigs. .chezmoiignore
# matches TARGET paths: the rules read `private_dot_ssh/**` / `dot_gitconfig-*`
# (source paths) until 2026-09-22 and silently matched nothing.
# Devcontainers keep ~/.ssh/config: it is generated host aliases, not key
# material, and .gitconfig's insteadOf rewrites resolve through it. Keys arrive
# via a forwarded agent socket. Guard against re-adding a source-path rule,
# which silently matches nothing (.chezmoiignore matches TARGET paths).
rules_only() { grep -vE '^[[:space:]]*#' "$ignore"; }   # comments mention the old patterns
! rules_only | grep -Fq 'private_dot_ssh/' || fail ".chezmoiignore: private_dot_ssh/ is a source path and matches nothing (use .ssh/)"
! rules_only | grep -Fq 'dot_gitconfig-' || fail ".chezmoiignore: dot_gitconfig- is a source path and matches nothing (use .gitconfig-)"
if command -v chezmoi >/dev/null; then
    DEVCONTAINER=true chezmoi execute-template --source "$repo_root" <"$ignore" | grep -Fxq '.ssh/**' &&
        fail "devcontainer render: ~/.ssh/config must stay managed (aliases; keys come from the forwarded agent)"
fi

finish
