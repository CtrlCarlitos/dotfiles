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

# 3. dot up sequence: pull WITHOUT applying, then init, then ONE apply. init never
#    pulls - update owns the fetch - so update runs FIRST; applying inside update
#    (before init) ran the installers twice whenever the config template changed.
#    The zsh arm is executed in 7; the PowerShell profiles are checked for the order.
for prof in "$ps1_profile" "$repo_root/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"; do
    awk '/chezmoi update --apply=false/{a=NR} /^ *chezmoi init\r?$/{b=NR} /^ *chezmoi apply\r?$/{c=NR} END{exit !(a && b && c && a<b && b<c)}' "$prof" ||
        fail "$prof: dot up must run chezmoi update --apply=false, then chezmoi init, then chezmoi apply"
    if grep -Eq 'chezmoi update --apply( |\r?$)' "$prof"; then fail "$prof: dot up must not apply inside chezmoi update"; fi
done

# 3b. dot up refreshes the LIVE session: zsh drops its PATH-listing cache
#     (HASH_LIST_ALL hides installs made after the shell started - observed
#     live 2026-09-29: `codex` "not found" in a session that predated its
#     install), and the PowerShell twins re-read the registry PATH. A full
#     profile reload is deliberately NOT attempted (double-loaded hooks).
grep -Fq 'rehash' "$zsh_aliases" || fail "$zsh_aliases: dot up must rehash (zsh hides post-start installs)"
for f in "$ps1_profile" "$ps1_profile5"; do
    grep -Fq 'New installs land in the registry PATH' "$f" ||
        fail "$f: dot up must re-read the registry PATH"
done

# 4. dot upgrade twins exist with gates, sweep, devcontainer guard.
for f in "$up_ps1" "$up_sh"; do
    [ -f "$f" ] || fail "$f: dotupgrade script missing"
done
grep -Fq 'choco upgrade all' "$up_ps1" || fail "$up_ps1: no choco sweep"
# The scan is path-aware (Codex's app-server daemon and Claude Desktop are not sessions);
# tests/dotupgrade_live_sessions_contract.sh executes it. Here: it is still wired in.
grep -Fq 'Get-LiveAgentProcess -Name opencode, claude, codex, agy, serena' "$up_ps1" ||
    fail "$up_ps1: no live-session scan"
grep -Fq 'pgrep -x' "$up_sh" || fail "$up_sh: no live-session scan (pgrep)"
grep -Fq 'brew upgrade' "$up_sh" || fail "$up_sh: no macOS sweep"
grep -Fq 'sudo apt-get "${apt_q[@]}" upgrade -y' "$up_sh" || fail "$up_sh: no apt sweep"

# `dot up` never upgrades: the installers it runs may refresh an index and install what is
# missing, but must carry no package sweep (the Linux one ran `apt upgrade -y` until 2026-10-05,
# upgrading the whole box on a plain `dot up`).
for installer in run_onchange_install_packages.sh.tmpl run_onchange_install_packages.ps1.tmpl; do
    # Commands only (a line that STARTS with the tool, optionally behind $SUDO or &): prose in
    # an info/Write-Host message that merely names `choco upgrade all` is not a sweep.
    if grep -Eq '^[[:space:]]*((\$SUDO|sudo)[[:space:]]+|&[[:space:]]+)?(apt|apt-get)[[:space:]]+(dist-)?upgrade|^[[:space:]]*(brew|choco|winget)(\.exe)?[[:space:]]+upgrade|^[[:space:]]*((\$SUDO|sudo)[[:space:]]+)?(dnf[[:space:]]+(up|upgrade)|pacman[[:space:]]+-Su)' "$repo_root/$installer"; then
        fail "$installer: dot up must not run a package upgrade sweep (that is dot upgrade)"
    fi
done

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

# 7. `dot up`, EXECUTED (#116: a tail that returned 1 on the normal path broke
#    every `dot up && ...` chain). The arm is extracted from dot_aliases.zsh and
#    run against a stub chezmoi that logs its calls (no network, no real config):
#    pull without applying, init, exactly one apply - whether or not init rewrote
#    the config - and nothing applied when a step before it fails.
dot_tmp="$(mktemp -d)"
trap 'rm -rf "$dot_tmp"' EXIT

run_dot_up() { # $1 = scratch dir, $2 = "yes" (init rewrites config) | "no", $3 = failing subcommand
    local scratch="$1" rewrite="$2" failing="${3:-}"
    local bin="$scratch/bin"
    rm -rf "$bin" "$scratch/calls"
    mkdir -p "$bin" "$scratch/home/.config/chezmoi" "$scratch/source"
    printf 'seed = "v1"\n' >"$scratch/home/.config/chezmoi/chezmoi.toml"
    cat >"$bin/chezmoi" <<EOF
#!/usr/bin/env bash
[ "\$1" = source-path ] && { echo "$scratch/source"; exit 0; }
echo "\$*" >>"$scratch/calls"
[ "\$1" = init ] && [ "$rewrite" = yes ] && printf 'seed = "v2"\n' >"\$HOME/.config/chezmoi/chezmoi.toml"
[ "\$1" = "$failing" ] && exit 1
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

want_calls="$(printf 'update --apply=false\ninit\napply')"
# a. init rewrites the config: one apply, after init, exit 0.
run_dot_up "$dot_tmp" yes >/dev/null 2>&1 || fail "dot up must exit 0 when init rewrites the config"
[ "$(cat "$dot_tmp/calls")" = "$want_calls" ] || fail "dot up must pull, init, then apply once (got: $(tr '\n' ';' <"$dot_tmp/calls"))"
pass
# b. init changes nothing (the normal path, and the #116 bug): the same, exit 0.
run_dot_up "$dot_tmp" no >/dev/null 2>&1 ||
    fail "dot up must exit 0 when the config is unchanged (the #116 regression)"
[ "$(cat "$dot_tmp/calls")" = "$want_calls" ] || fail "dot up must pull, init, then apply once (got: $(tr '\n' ';' <"$dot_tmp/calls"))"
pass
# c. a failed pull or init applies nothing and returns non-zero.
for step in update init; do
    if run_dot_up "$dot_tmp" no "$step" >/dev/null 2>&1; then fail "dot up must return non-zero when chezmoi $step fails"; fi
    if grep -qx apply "$dot_tmp/calls"; then fail "dot up must not apply after chezmoi $step failed"; fi
done
pass

# 8. dot remote arm: wired into all three dispatchers (#165). Both twins
#    landed (scripts/remote-access.sh, scripts/remote-access.ps1) and carry
#    their own suites (tests/remote_access.sh, tests/remote_access.ps1);
#    the profiles here assert the delegation strings, and the twins'
#    behavior is pinned by those suites, not by this file.
[ -f "$repo_root/scripts/remote-access.sh" ] || fail "scripts/remote-access.sh missing"
grep -Fq 'remote)  shift; bash "$repo_scripts/remote-access.sh" "$@" ;;' "$zsh_aliases" ||
    fail "$zsh_aliases: no dot remote arm"
help_output="$(
    export DOTFILES_DIR="$dot_tmp/source"
    eval "$(awk '/^dot\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$zsh_aliases")"
    dot help
)"
printf '%s\n' "$help_output" | python3 -c 'import sys,re; text=sys.stdin.read(); rows=[re.match(r"^  dot \S+\s{2,}(\S.*)$", line) for line in text.splitlines() if line.startswith("  dot ")]; assert rows and all(rows); assert len({row.start(1) for row in rows}) == 1; assert "dot remote" in text and "remote-access setup/status/fix" in text' || fail 'dot help descriptions must align and include remote'
for f in "$ps1_profile" "$ps1_profile5"; do
    grep -Fq "'remote' { & (Join-Path \$repoScripts 'remote-access.ps1') @rest }" "$f" ||
        fail "$f: no dot remote arm"
    grep -Fq 'remote-access.ps1' "$f" || fail "$f: no remote-access.ps1 reference"
    # PowerShell help alignment is executed in dot_doctor_windows.ps1.
done

finish
