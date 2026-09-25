#!/usr/bin/env bash
set -euo pipefail

# dot CLI contract: `dot` is the single command family. `dot up` NEVER
# upgrades (install-if-missing only; upgrades are `dot upgrade`'s sole
# domain). No back-compat aliases: dotup/dp are gone. `dot up` also must
# exit 0 on the normal unchanged-config path (#116) - asserted by EXECUTING
# the arm with a stub chezmoi at the bottom, not just grepping it.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_profile="$repo_root/Documents/PowerShell/Microsoft.PowerShell_profile.ps1"
ps1_profile5="$repo_root/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"
zsh_aliases="$repo_root/dot_aliases.zsh"
up_ps1="$repo_root/scripts/dotupgrade.ps1"
up_sh="$repo_root/scripts/dotupgrade.sh"
ai_ps1="$repo_root/scripts/update_ai_tools.ps1"
ai_sh="$repo_root/scripts/update_ai_tools.sh"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"

. "$repo_root/tests/lib.sh"

# 1. Dispatcher present in all three shell entry points.
for f in "$ps1_profile" "$ps1_profile5"; do
    grep -Fq 'function dot {' "$f" || fail "$f: no dot dispatcher"
done
grep -Fq 'dot()' "$zsh_aliases" || fail "$zsh_aliases: no dot dispatcher"

# 2. No back-compat: the dotup alias is GONE everywhere. (dp stays - it is
#    the unrelated devprofile switcher, not a dotfiles-family alias.)
for f in "$ps1_profile" "$ps1_profile5" "$zsh_aliases"; do
    ! grep -Eq '\bdotup\b' "$f" ||
        fail "$f: dotup back-compat alias must be removed"
done

# 3. dot up sequence: update --apply, then init, then conditional apply.
#    init never pulls - update owns the fetch - so update runs FIRST.
grep -Fq 'chezmoi update --apply' "$ps1_profile" || fail "$ps1_profile: dot up must update --apply"
grep -Fq 'chezmoi init' "$ps1_profile" || fail "$ps1_profile: dot up must re-init config after pull"
grep -Fq 'chezmoi init' "$zsh_aliases" || fail "$zsh_aliases: dot up must re-init config after pull"

# 4. dot upgrade twins exist with gates, sweep, devcontainer guard.
for f in "$up_ps1" "$up_sh"; do
    [ -f "$f" ] || fail "$f: dotupgrade script missing"
done
grep -Fq 'choco upgrade all' "$up_ps1" || fail "$up_ps1: no choco sweep"
grep -Fq 'Get-Process opencode, claude, codex, agy, serena' "$up_ps1" ||
    fail "$up_ps1: no live-session scan"
grep -Fq 'pgrep -x' "$up_sh" || fail "$up_sh: no live-session scan (pgrep)"
grep -Fq 'brew upgrade' "$up_sh" || fail "$up_sh: no macOS sweep"
grep -Fq 'apt-get upgrade' "$up_sh" || fail "$up_sh: no apt sweep"

# Full sweep premise: on Windows, winget-managed apps (Build Tools, ChatGPT
# Work/Codex msstore, Win-CodexBar) upgrade alongside choco - `winget
# upgrade --all`, same premise as `choco upgrade all`. Linux/mac: brew and
# apt ARE full sweeps of their universe, but the installers also place
# direct-download artifacts (GitHub .debs/dmg/tarball) that no manager
# owns - the run must NAME them so the operator sees the residual gap.
grep -Fq 'winget upgrade --all' "$up_ps1" ||
    fail "$up_ps1: no winget sweep (Build Tools / ChatGPT Work / Win-CodexBar)"
grep -Fq 'outside package managers' "$up_sh" ||
    fail "$up_sh: no outside-package-managers report (direct-download artifacts)"
grep -Fq 'DEVCONTAINER' "$up_sh" || fail "$up_sh: no devcontainer guard"
grep -Fq 'DOTUPGRADE_DEFER' "$up_ps1" || fail "$up_ps1: no defer-list export"
grep -Fq 'DOTUPGRADE_DEFER' "$up_sh" || fail "$up_sh: no defer-list export"

# 5. The AI section honors the defer list around dir-recreating upgrades.
grep -Fq 'DOTUPGRADE_DEFER' "$ai_ps1" || fail "$ai_ps1: no defer hooks"
grep -Fq 'DOTUPGRADE_DEFER' "$ai_sh" || fail "$ai_sh: no defer hooks"

# 6. Installers NEVER upgrade: the upgrade steps added 2026-09-20 are gone.
! grep -Fq '@openai/codex@latest' "$ps1_installer" ||
    fail "$ps1_installer: must not upgrade codex (dot upgrade owns it)"
! grep -Fq '@openai/codex@latest' "$sh_installer" ||
    fail "$sh_installer: must not upgrade codex (dot upgrade owns it)"
! grep -Fq 'uv tool upgrade serena-agent' "$ps1_installer" ||
    fail "$ps1_installer: must not upgrade serena (dot upgrade owns it)"
! grep -Fq 'uv tool upgrade serena-agent' "$sh_installer" ||
    fail "$sh_installer: must not upgrade serena (dot upgrade owns it)"
! grep -Fq 'Upgrading graft' "$ps1_installer" ||
    fail "$ps1_installer: must not upgrade graft (dot upgrade owns it)"
! grep -Fq 'Upgrading graft' "$sh_installer" ||
    fail "$sh_installer: must not upgrade graft (dot upgrade owns it)"

# The dot family runs these scripts from the SOURCE repo, resolved from
# DOTFILES_DIR (exported by dot_zshrc) with the chezmoi source path as the
# fallback - never a hardcoded $HOME layout (#116).
ignore="$repo_root/.chezmoiignore"
grep -Fq 'scripts/**' "$ignore" || fail "$ignore: scripts/** must not be deployed to \$HOME"
grep -Fq 'tests/**' "$ignore" || fail "$ignore: tests/** must not be deployed to \$HOME"
for f in "$ps1_profile" "$ps1_profile5"; do
    grep -Fq '.local\share\chezmoi\scripts' "$f" || fail "$f: dot must run scripts from the source repo"
done
grep -Fq 'repo_scripts="${DOTFILES_DIR:-$(chezmoi source-path)}/scripts"' "$zsh_aliases" ||
    fail "$zsh_aliases: dot must resolve scripts from DOTFILES_DIR or the chezmoi source path"

# 7. `dot up` exits 0 on the normal path - EXECUTED, not grepped (#116): the
#    old tail, `[ "$before" != "$after" ] && chezmoi apply`, made the function
#    return 1 whenever `chezmoi init` rewrote nothing, so `dot up && ...`
#    chains broke. The arm is extracted from dot_aliases.zsh and run against
#    a stub chezmoi (no update, no network, no real config touched).
dot_tmp="$(mktemp -d)"
trap 'rm -rf "$dot_tmp"' EXIT

run_dot_up() { # $1 = scratch dir, $2 = "yes" (init rewrites config) | "no"
    local scratch="$1" rewrite="$2"
    local bin="$scratch/bin"
    rm -rf "$bin" "$scratch/applied"
    mkdir -p "$bin" "$scratch/home/.config/chezmoi" "$scratch/source"
    printf 'seed = "v1"\n' >"$scratch/home/.config/chezmoi/chezmoi.toml"
    cat >"$bin/chezmoi" <<EOF
#!/usr/bin/env bash
case "\$1" in
    update) : ;;
    init) [ "$rewrite" = yes ] && printf 'seed = "v2"\n' >"\$HOME/.config/chezmoi/chezmoi.toml" ;;
    apply) : >"$scratch/applied" ;;
    source-path) echo "$scratch/source" ;;
esac
exit 0
EOF
    chmod +x "$bin/chezmoi"
    (
        export PATH="$bin:$PATH" HOME="$scratch/home"
        cd "$scratch"
        eval "$(awk '/^dot\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$zsh_aliases")"
        dot up
    )
}

# a. init rewrites the config: apply must fire, and the exit code is 0.
run_dot_up "$dot_tmp" yes >/dev/null 2>&1 || fail "dot up must exit 0 when init rewrites the config"
[ -f "$dot_tmp/applied" ] || fail "dot up must apply when the config hash changed"
pass
# b. init changes nothing (the normal path, and the #116 bug): still exit 0.
run_dot_up "$dot_tmp" no >/dev/null 2>&1 ||
    fail "dot up must exit 0 when the config is unchanged (the #116 regression)"
[ ! -f "$dot_tmp/applied" ] || fail "dot up must not apply when the config hash is unchanged"
pass

finish
