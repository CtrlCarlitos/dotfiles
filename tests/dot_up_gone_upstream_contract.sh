#!/usr/bin/env bash
set -euo pipefail

# `dot up` runs `chezmoi update --apply=false`, which is just `git pull` on the source repo.
# When the current branch's remote branch was merged (often squashed, as this repo's own PRs
# are) and GitHub auto-deletes it, git pull has nothing to merge and fails with its raw "no such
# ref was fetched" error - exit 1, no hint of what happened or how to fix it (lived 2026-10-11:
# `feat/mobile-dev`'s PR #352 squash-merged, `dot up` died on the stale branch with that message).
# fetch.prune (on by default) already marks the branch [gone] by the time that fetch completes,
# so `dot up` can recognize it and name the fix instead of handing back chezmoi's bare git error.
#
# All three dispatchers (invariant #10) are EXECUTED against a REAL git fixture - a bare remote,
# a branch deleted upstream and pruned - with only `chezmoi` stubbed. The git calls this fix
# makes are real, not grepped for.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v git >/dev/null 2>&1 || skip "git not installed"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# make_fixture DIR GONE - a bare remote plus a working repo at DIR. GONE=1: checked out on
# "feature", whose remote branch is deleted and pruned (triggers the diagnostic). GONE=0:
# checked out on "main", a normal up-to-date branch (must NOT trigger it).
make_fixture() {
    local dir="$1" gone="$2" remote="$1.remote.git"
    rm -rf "$dir" "$remote"
    git init --quiet --bare "$remote"
    git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
    git init --quiet "$dir"
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name Test
    git -C "$dir" checkout --quiet -b main
    git -C "$dir" commit --quiet --allow-empty -m init
    git -C "$dir" remote add origin "$remote"
    git -C "$dir" push --quiet -u origin main
    git -C "$dir" remote set-head origin -a >/dev/null
    if [ "$gone" = 1 ]; then
        git -C "$dir" checkout --quiet -b feature
        git -C "$dir" commit --quiet --allow-empty -m feature
        git -C "$dir" push --quiet -u origin feature
        git -C "$dir" push --quiet origin --delete feature
        git -C "$dir" fetch --quiet --prune origin
    fi
}

# --- zsh dot(), evaluated under bash ---------------------------------------------------------
zsh_aliases="$repo_root/dot_aliases.zsh"
awk '/^dot\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$zsh_aliases" >"$tmp/dot.zsh.fn"
[ -s "$tmp/dot.zsh.fn" ] || fail "could not extract dot() from $zsh_aliases"

run_zsh_up() { # $1 = source dir; stub chezmoi fails only on `update`
    local src="$1" bin="$tmp/bin"
    rm -rf "$bin"; mkdir -p "$bin"
    cat >"$bin/chezmoi" <<'EOF'
#!/usr/bin/env bash
[ "$1" = source-path ] && { echo "/does/not/matter"; exit 0; }
[ "$1" = update ] && exit 1
exit 0
EOF
    chmod +x "$bin/chezmoi"
    ( export PATH="$bin:$PATH" DOTFILES_DIR="$src"
      eval "$(cat "$tmp/dot.zsh.fn")"
      dot up; printf 'rc=%s\n' "$?" ) 2>&1
}

make_fixture "$tmp/zsh-gone" 1
out="$(run_zsh_up "$tmp/zsh-gone")"
[[ $out == *'rc=0'* ]] && fail "zsh: dot up must fail (chezmoi update is stubbed to fail) (got: ${out:0:200})"
[[ $out == *'feature'* ]] || fail "zsh: must name the branch ('feature') (got: ${out:0:300})"
[[ $out == *'gone'* ]] || fail "zsh: must say the upstream is gone (got: ${out:0:300})"
[[ $out == *'checkout main'* ]] || fail "zsh: must name the fix (checkout main) (got: ${out:0:300})"
[[ $out == *'branch -D feature'* ]] || fail "zsh: must name the branch cleanup (branch -D feature) (got: ${out:0:300})"
pass

make_fixture "$tmp/zsh-notgone" 0
out="$(run_zsh_up "$tmp/zsh-notgone")"
[[ $out != *'gone'* ]] || fail "zsh: must not print the gone-upstream diagnostic when the branch is not gone (got: ${out:0:300})"
pass

# --- the two PowerShell profiles, under pwsh -------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    for profile in Documents/PowerShell Documents/WindowsPowerShell; do
        file="$repo_root/$profile/Microsoft.PowerShell_profile.ps1"
        tr -d '\r' <"$file" >"$tmp/profile.ps1"
        awk '/^function dot \{/{f=1} f{print} f && /^\}$/{exit}' "$tmp/profile.ps1" >"$tmp/dot.ps1"
        [ -s "$tmp/dot.ps1" ] || { fail "could not extract the dot function from $profile"; continue; }

        run_ps_up() { # $1 = USERPROFILE-style home dir containing .local\share\chezmoi
            # $HOME (the automatic variable the real profile code reads) is derived from
            # USERPROFILE once at process startup - setting it mid-script is too late.
            {
                printf '%s\n' 'function chezmoi { if ($args[0] -eq "update") { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 } }'
                cat "$tmp/dot.ps1"
                printf '%s\n' '$global:LASTEXITCODE = 0' 'dot up *>&1 | Out-String | Write-Output' 'Write-Output "rc=$global:LASTEXITCODE"'
            } >"$tmp/run-dot.ps1"
            USERPROFILE="$(winpath "$1")" pwsh -NoProfile -File "$(winpath "$tmp/run-dot.ps1")" 2>&1
        }

        home_gone="$tmp/ps-home-gone-$(basename "$profile")"
        mkdir -p "$home_gone"
        make_fixture "$home_gone/.local/share/chezmoi" 1
        out="$(run_ps_up "$home_gone")"
        [[ $out == *'rc=0'* ]] && fail "$profile: dot up must fail (chezmoi update is stubbed to fail) (got: ${out:0:200})"
        [[ $out == *'feature'* ]] || fail "$profile: must name the branch ('feature') (got: ${out:0:300})"
        [[ $out == *'gone'* ]] || fail "$profile: must say the upstream is gone (got: ${out:0:300})"
        [[ $out == *'checkout main'* ]] || fail "$profile: must name the fix (checkout main) (got: ${out:0:300})"
        [[ $out == *'branch -D feature'* ]] || fail "$profile: must name the branch cleanup (branch -D feature) (got: ${out:0:300})"
        pass

        home_notgone="$tmp/ps-home-notgone-$(basename "$profile")"
        mkdir -p "$home_notgone"
        make_fixture "$home_notgone/.local/share/chezmoi" 0
        out="$(run_ps_up "$home_notgone")"
        [[ $out != *'gone'* ]] || fail "$profile: must not print the gone-upstream diagnostic when the branch is not gone (got: ${out:0:300})"
        pass
    done
else
    printf 'SKIP (PowerShell profiles only): pwsh not installed\n'
fi

finish
