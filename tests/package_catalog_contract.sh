#!/usr/bin/env bash
set -euo pipefail

# The package catalog is the only place a package-manager name may live.
#
# Before #83 the Windows package universe existed three times - the .ps1
# installer's $packages lists, scripts/migrate-to-choco.ps1's $Universe, and
# the prose in docs/tool-parity.md - and the "kept in sync" contract between
# the first two was a grep for a comment marker. The mirror held 39 of the
# installer's 61 packages. Homebrew had its own curated lines, apt its own.
#
# Now .chezmoidata/packages.yaml is the catalog, the installers render their
# manager's names from it through .chezmoitemplates fragments, and
# migrate-to-choco reads it at runtime. This test keeps that true five ways:
#
#   1. SHAPE     every record has an id, a group the config actually prompts
#                for, and at least one manager (or a note documenting its
#                by-procedure install); ids and per-manager names are unique;
#                migrate metadata is well-formed.
#   2. NO COPY   no consumer carries a name of its own: the .ps1 has no
#                `$packages += @(` literal, install_brew has no literal `brew
#                install <names>`, migrate has no `$Universe = @(` list.
#   3. RENDERS   BOTH twins, rendered with every group on and the OS forced
#                through --override-data (the way remote_access_package_ownership
#                does), emit exactly the catalog's names for their managers.
#                An empty --config keeps the host's own chezmoi.toml out of it:
#                the first version read the host config, rendered whatever
#                groups the host had enabled, and failed on the CI lint runner,
#                which has none.
#   4. RUNTIME   the expression migrate-to-choco evaluates yields the catalog's
#                choco names minus those marked migrate: false.
#   5. NO BYPASS every literal `apt install -y <name>` in the rendered Linux
#                installer is produced by the catalog (#127) - no hardcoded
#                package name in install_apt.
#
# Bash renders, Python parses. Python never shells out to bash: on Windows the
# first bash.exe on PATH can be System32's WSL launcher, which cannot see C:/.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
catalog="$repo_root/.chezmoidata/packages.yaml"
ps_t="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_t="$repo_root/run_onchange_install_packages.sh.tmpl"
migrate="$repo_root/scripts/migrate-to-choco.ps1"

. "$repo_root/tests/lib.sh"

[ -f "$catalog" ] || { fail "$catalog missing"; exit 1; }
for f in choco-packages pkg-names; do
    [ -f "$repo_root/.chezmoitemplates/$f" ] || fail ".chezmoitemplates/$f missing - the installers render package names through it"
done

# ------------------------------------------------- 2. no consumer keeps a copy
# shellcheck disable=SC2016  # the $ signs are literal PowerShell, not expansions
if grep -qE '^\s*\$packages \+= @\(' "$ps_t"; then
    fail "run_onchange_install_packages.ps1.tmpl: a literal \$packages += @( ... ) list is back - render it with includeTemplate \"choco-packages\""
fi
grep -Fq 'includeTemplate "choco-packages"' "$ps_t" ||
    fail "run_onchange_install_packages.ps1.tmpl: no longer renders choco packages from the catalog"
if awk '/^install_brew\(\)/,/^}/' "$sh_t" | grep -qE '^\s*brew install (--cask )?[a-z]'; then
    fail "run_onchange_install_packages.sh.tmpl: install_brew has a literal package list - render it with includeTemplate \"pkg-names\""
fi
grep -Fq 'includeTemplate "pkg-names"' "$sh_t" ||
    fail "run_onchange_install_packages.sh.tmpl: no longer renders package names from the catalog"
# A literal list opens the array and continues on the next line: `@(` then
# end of line. The runtime path initialises `$Universe = @()` on one line,
# which a bare `@\(` would wrongly match.
# shellcheck disable=SC2016
if grep -qE '^\s*\$Universe\s*=\s*@\(\s*$' "$migrate"; then
    fail "scripts/migrate-to-choco.ps1: carries its own \$Universe list again - it must read the catalog at runtime"
fi
grep -Fq 'execute-template' "$migrate" ||
    fail "scripts/migrate-to-choco.ps1: does not read the catalog through chezmoi execute-template"

# --------------------------------------- 1, 3, 4 need chezmoi to render
command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed (static checks only)"
PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' 2>/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || skip "no python (static checks only)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# render is lib.sh's: empty config (the HOST's config must not shape the
# render - the first version read the host config and failed on CI) + repo source.

grep -oE 'promptBoolOnce \. "packages\.[a-z_]+"' "$repo_root/.chezmoi.toml.tmpl" \
    | sed -E 's/.*"packages\.([a-z_]+)"/\1/' > "$tmp/groups.txt"
# {"core":true,"modern_cli":true,...}: every group on, so every list renders.
all_on="{$(sed -E 's/.*/"&":true/' "$tmp/groups.txt" | paste -sd, -)}"

render '{{ .catalog.packages | toJson }}' > "$tmp/catalog.json" || fail "catalog does not render (YAML broken?)"
render '{{ range .catalog.packages }}{{ if and (hasKey . "choco") (not (and (hasKey . "migrate") (not .migrate))) }}{{ .choco }}{{ "\n" }}{{ end }}{{ end }}' \
    > "$tmp/migrate-universe.txt" || fail "the migrate-to-choco universe expression does not render"

# Both twins, every group on, OS forced. darwin for the .sh so install_brew's
# cask loop (darwin-gated) renders; linux again for the apt lines.
render --override-data "{\"chezmoi\":{\"os\":\"windows\"},\"packages\":$all_on}" --file "$ps_t" > "$tmp/ps1.rendered" 2>"$tmp/ps1.err" ||
    fail "the .ps1 twin does not render with os=windows and every group on: $(head -c 300 "$tmp/ps1.err")"
render --override-data "{\"chezmoi\":{\"os\":\"darwin\",\"kernel\":{\"osrelease\":\"24.0.0\"}},\"packages\":$all_on}" --file "$sh_t" > "$tmp/sh-darwin.rendered" 2>"$tmp/shd.err" ||
    fail "the .sh twin does not render with os=darwin and every group on: $(head -c 300 "$tmp/shd.err")"
# kernel.osrelease exists only on a Linux host; the template reads it for WSL
# detection, so a Windows or macOS host must supply one (a non-WSL value).
render --override-data "{\"chezmoi\":{\"os\":\"linux\",\"kernel\":{\"osrelease\":\"6.8-generic\"}},\"packages\":$all_on}" --file "$sh_t" > "$tmp/sh-linux.rendered" 2>"$tmp/shl.err" ||
    fail "the .sh twin does not render with os=linux and every group on: $(head -c 300 "$tmp/shl.err")"

"$PY" - "$tmp" <<'PYEOF' || fail "catalog checks failed (see above)"
import json, re, sys, io
tmp = sys.argv[1]
bad = 0
def err(m):
    global bad; bad += 1; print("  " + m, file=sys.stderr)

cat = json.load(open(tmp + "/catalog.json", encoding="utf-8"))
groups = set(open(tmp + "/groups.txt").read().split())
if not groups: err("no promptBoolOnce groups found - parser is stale")

# 1. shape
ids, seen = set(), {"apt": {}, "brew": {}, "cask": {}, "choco": {}}
for i, r in enumerate(cat):
    where = "record %d (%s)" % (i, r.get("id", "?"))
    if "id" not in r: err(where + ": no id"); continue
    if r["id"] in ids: err(where + ": duplicate id")
    ids.add(r["id"])
    if r.get("group") not in groups:
        err(where + ": group %r is not a promptBoolOnce group" % r.get("group"))
    mgrs = [m for m in seen if m in r]
    if not mgrs:
        # A tool no manager names (ScreenRec: vendor repo/.dmg/.exe procedures
        # on all three platforms) may omit manager keys, but its record must
        # then carry the note the catalog header promises.
        if not r.get("note"):
            err(where + ": names no manager (apt/brew/cask/choco) and has no note")
    for m in mgrs:
        if r[m] in seen[m]: err(where + ": %s name %r already used by %s" % (m, r[m], seen[m][r[m]]))
        seen[m][r[m]] = r["id"]
    if "migrate" in r and r["migrate"] is not False:
        err(where + ": migrate may only be false (omit it to allow migration)")
    if "migrate" in r and "migrate_reason" not in r:
        err(where + ": migrate: false needs a migrate_reason")
    if "migrate_reason" in r and "migrate" not in r:
        err(where + ": migrate_reason without migrate: false")
    if "migrate_risk" in r and "choco" not in r:
        err(where + ": migrate_risk on a tool with no choco package")
    if "migrate" in r and "migrate_risk" in r:
        err(where + ": both migrate: false and migrate_risk - pick one")

choco = [r["choco"] for r in cat if "choco" in r]
brew  = [r["brew"] for r in cat if "brew" in r]
cask  = [r["cask"] for r in cat if "cask" in r]
apt   = [r["apt"] for r in cat if "apt" in r]

def read(name):
    return io.open("%s/%s" % (tmp, name), encoding="utf-8", newline="").read()

# 3a. the .ps1, every group on: exactly the catalog's choco names, in order
ps1 = read("ps1.rendered")
got = re.findall(r'^\$packages \+= "([^"]+)"', ps1, re.M)
if got != choco:
    err("ps1 render: choco names differ from the catalog - missing=%s extra=%s (or out of order)"
        % (sorted(set(choco) - set(got)), sorted(set(got) - set(choco))))
else:
    print("  rendered .ps1 (os=windows, all groups): %d choco names, exactly the catalog, in catalog order" % len(got))

# 3b. the .sh on darwin: every formula and every cask
sh = read("sh-darwin.rendered")
formulas, casks = set(), set()
for m in re.finditer(r'^\s*brew install (?!--cask)([^|\n]+)', sh, re.M): formulas |= set(m.group(1).split())
for m in re.finditer(r'^\s*brew install --cask ([^|\n]+)', sh, re.M): casks |= set(m.group(1).split())
m = re.search(r'for cask in ([^;\n]+); do', sh)
if m: casks |= set(m.group(1).split())
else: err("sh render (darwin): the dev_desktop cask loop did not render")
lost = set(brew) - formulas
if lost: err("sh render (darwin): catalog brew formulas never rendered: %s" % sorted(lost))
lost = set(cask) - casks
if lost: err("sh render (darwin): catalog casks never rendered: %s" % sorted(lost))
if not (set(brew) - formulas) and not (set(cask) - casks):
    print("  rendered .sh (os=darwin, all groups): all %d formulas and %d casks present" % (len(brew), len(cask)))

# 3c. the .sh on linux: every apt name, and no list split from its `; do` / `||`
sh = read("sh-linux.rendered")
apts = set()
for m in re.finditer(r'^\s*\$SUDO apt install -y ([^|\n"$]+)', sh, re.M): apts |= set(m.group(1).split())
for m in re.finditer(r'for pkg in ([^;\n]+); do', sh): apts |= set(m.group(1).split())
lost = set(apt) - apts
if lost: err("sh render (linux): catalog apt names never rendered: %s" % sorted(lost))
else: print("  rendered .sh (os=linux, all groups): all %d apt names present" % len(apt))
# The bug this catches: a fragment emitting its own trailing newline splits
# `for pkg in a b c` from `; do`. A line ending in a backslash is a deliberate
# shell continuation (the zoxide install does this), not a split.
if re.search(r'^(for \w+ in [^\n]*|\s*brew install [^\n]*|\s*\$SUDO apt install -y [^\n]*)(?<!\\)\n\s*(; do|\|\|)', sh + read("sh-darwin.rendered"), re.M):
    err("sh render: a package list is split from its `; do` / `||` by a newline - a fragment is emitting its trailing newline")

# 3d. no literal apt install bypasses the catalog (#127): every literal name
# after `apt(-get) install -y` in the rendered Linux installer must be
# produced by the catalog - an `apt:` value, or a tool id whose record
# documents its by-procedure install (ghostty, neovim, screenrec, zoxide).
# The names below are base-image prerequisites (a keyring tool, an archive
# unpacker, the remote_access_server SSH server), not tools; they are
# deliberately not catalogued. Anything else appearing here means someone
# hardcoded a package name in install_apt again - add the apt: key/record to
# .chezmoidata/packages.yaml and render the line through "pkg-names".
PREREQ = {"gpg", "unzip", "openssh-server"}
produced = set(apt) | set(ids)
literal = set()
for m in re.finditer(r'apt(?:-get)? install -y ([^|\n;"\'$]+)', sh):
    for tok in m.group(1).split():
        if re.fullmatch(r'[a-z0-9][a-z0-9+.\-]*', tok):
            literal.add(tok)
stray = sorted(literal - produced - PREREQ)
if stray:
    err("sh render (linux): literal apt install name(s) %s not produced by the catalog - add apt: keys/records to .chezmoidata/packages.yaml and render through pkg-names" % stray)
else:
    print("  rendered .sh (os=linux): every literal apt install name is catalog-produced (%d distinct)" % len(literal))

# 4. migrate universe
uni = open(tmp + "/migrate-universe.txt").read().split()
want = [r["choco"] for r in cat if "choco" in r and r.get("migrate", True) is not False]
if sorted(uni) != sorted(want):
    err("migrate universe expression: missing=%s extra=%s" % (sorted(set(want)-set(uni)), sorted(set(uni)-set(want))))
excluded = [r["choco"] for r in cat if r.get("migrate") is False]
print("  catalog: %d tools, %d choco / %d brew / %d cask / %d apt names; migrate universe %d (excluded: %s)"
      % (len(cat), len(choco), len(brew), len(cask), len(apt), len(uni), ", ".join(excluded) or "none"))
sys.exit(1 if bad else 0)
PYEOF

finish
