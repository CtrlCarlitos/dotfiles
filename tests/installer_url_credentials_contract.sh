#!/usr/bin/env bash
set -euo pipefail

# No installer may put a credential in a URL.
#
# Both installers used to bootstrap a private repo with
# `git clone "https://${PAT}@github.com/CtrlCarlitos/dotfiles.git"`. Git
# persists a clone URL verbatim as remote.origin.url, so the bootstrap token
# stayed in .git/config - mode 644, world-readable - for as long as the
# checkout lived. A real machine carried a classic PAT there for weeks:
# `git remote -v` printed it on demand, it reached an agent transcript, and
# the token-as-username form is not even a working push credential. The repo's
# own docs/backup-restore.md already forbade it ("do not embed a PAT in a
# clone URL: it can persist in shell history, process listings, Git remote
# configuration, and logs") - the code just disagreed with the docs.
#
# So this pins the rule itself rather than the one shape it took:
#   1. no `scheme://...@host` userinfo in either installer;
#   2. no PAT/token variable referenced at all (the repo is public - chezmoi
#      clones it unauthenticated, so there is nothing to authenticate with);
#   3. `git clone -c/--config` is never used to pass a credential, because
#      clone-time -c is WRITTEN INTO the new repo's config. Only `git -c ...`
#      before the subcommand is one-shot.
#   4. the docs rule stays in place, so the next person finds the reason.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

sh_installer="$repo_root/install.sh"
ps1_installer="$repo_root/install.ps1"

for f in "$sh_installer" "$ps1_installer"; do
    [ -f "$f" ] || fail "missing installer: $f"
done

# 1. Userinfo in a URL. Matches https://TOKEN@host, https://user:pw@host and
#    the interpolated forms (${PAT}@, $($env:PAT)@) in one shape. Deliberately
#    not limited to github.com: any host is just as wrong.
for f in "$sh_installer" "$ps1_installer"; do
    if grep -nE '[a-z][a-z0-9+.-]*://[^/"'"'"' ]*@' "$f" >/dev/null 2>&1; then
        fail "$(basename "$f"): a credential in a URL - $(grep -nE '[a-z][a-z0-9+.-]*://[^/"'"'"' ]*@' "$f" | head -3 | sed 's/gh[pousr]_[A-Za-z0-9]*/gh?_REDACTED/g')"
    else
        pass
    fi
done

# 2. No token variable at all. PATH and *_PAT pattern variables are excluded
#    with word boundaries, so this catches $PAT/${PAT}/$env:PAT and the common
#    token spellings without tripping over unrelated names.
for f in "$sh_installer" "$ps1_installer"; do
    hits="$(grep -nE '\$(\{)?(env:)?(PAT|GITHUB_TOKEN|GH_TOKEN|GITHUB_PAT)\b' "$f" || true)"
    if [ -n "$hits" ]; then
        fail "$(basename "$f"): references a token variable; the repo is public and needs none - $(printf '%s' "$hits" | head -3)"
    else
        pass
    fi
done

# 3. A credential must never ride on clone-time -c/--config: that value is
#    written into the cloned repo's .git/config, which is the original bug in
#    a new costume. `git -c ... clone` (one-shot, before the subcommand) is
#    fine and is what the comments point to.
for f in "$sh_installer" "$ps1_installer"; do
    if grep -nE 'clone[^|&;]*(-c|--config)[^|&;]*credential' "$f" >/dev/null 2>&1; then
        fail "$(basename "$f"): credential config passed at clone time persists into the new repo - use 'git -c ... clone' instead"
    else
        pass
    fi
done

# 4. The documented rule must survive, so a future reader finds the why.
require "$repo_root/docs/backup-restore.md" 'Do not embed a PAT in a clone URL'

# Both installers must still have a working unauthenticated bootstrap - this
# contract must not be satisfiable by deleting the clone entirely.
require "$sh_installer" 'chezmoi init --apply --branch main CtrlCarlitos/dotfiles'
require "$ps1_installer" 'chezmoi init --apply --branch main CtrlCarlitos/dotfiles'

finish
