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
# migrate-to-choco reads it at runtime. This test keeps that true four ways:
#
#   1. SHAPE     every record has an id, a group the config actually prompts
#                for, and at least one manager; ids and per-manager names are
#                unique; migrate metadata is well-formed.
#   2. NO COPY   no consumer carries a name of its own: the .ps1 has no
#                `$packages += @(` literal, install_brew has no literal `brew
#                install <names>`, migrate has no `$Universe = @(` list.
#   3. RENDERS   the twin this platform renders emits exactly the catalog's
#                names for its manager - none lost, none invented.
#   4. RUNTIME   the expression migrate-to-choco evaluates yields the catalog's
#                choco names minus those marked migrate: false.
#
# Bash renders, Python parses. Python never shells out to bash: on Windows the
# first bash.exe on PATH can be System32's WSL launcher, which cannot see C:/.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
catalog="$repo_root/.chezmoidata/packages.yaml"
ps_t="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_t="$repo_root/run_onchange_install_packages.sh.tmpl"
migrate="$repo_root/scripts/migrate-to-choco.ps1"
failures=0
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

[ -f "$catalog" ] || { printf 'FAIL: %s missing\n' "$catalog" >&2; exit 1; }
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
command -v chezmoi >/dev/null 2>&1 || { printf 'SKIP: chezmoi not installed (static checks only)\n'; exit 0; }
PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' 2>/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || { printf 'SKIP: no python (static checks only)\n'; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
render() { chezmoi execute-template --source "$repo_root" "$@"; }

render '{{ .catalog.packages | toJson }}' > "$tmp/catalog.json" || fail "catalog does not render (YAML broken?)"
render '{{ range .catalog.packages }}{{ if and (hasKey . "choco") (not (and (hasKey . "migrate") (not .migrate))) }}{{ .choco }}{{ "\n" }}{{ end }}{{ end }}' \
    > "$tmp/migrate-universe.txt" || fail "the migrate-to-choco universe expression does not render"
render --file "$ps_t" > "$tmp/ps1.rendered" 2>/dev/null || true
render --file "$sh_t" > "$tmp/sh.rendered" 2>/dev/null || true
grep -oE 'promptBoolOnce \. "packages\.[a-z_]+"' "$repo_root/.chezmoi.toml.tmpl" | sed -E 's/.*"packages\.([a-z_]+)"/\1/' > "$tmp/groups.txt"

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
    if not mgrs: err(where + ": names no manager (apt/brew/cask/choco)")
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

# 3. the rendered twin emits exactly the catalog's names
ps1 = io.open(tmp + "/ps1.rendered", encoding="utf-8", newline="").read()
if "$packages +=" in ps1:
    got = re.findall(r'^\$packages \+= "([^"]+)"', ps1, re.M)
    # rendering is gated by this machine's group toggles, so compare only the
    # groups that rendered anything: within a rendered group nothing may be
    # missing or extra
    by_group = {}
    for r in cat:
        if "choco" in r: by_group.setdefault(r["group"], []).append(r["choco"])
    rendered_groups = {g for g, names in by_group.items() if any(n in got for n in names)}
    want = [n for g in by_group if g in rendered_groups for n in by_group[g]]
    if sorted(want) != sorted(got):
        err("ps1 render: choco names differ from the catalog - missing=%s extra=%s"
            % (sorted(set(want) - set(got)), sorted(set(got) - set(want))))
    else:
        print("  rendered .ps1: %d choco names, %d groups, all from the catalog" % (len(got), len(rendered_groups)))

sh = io.open(tmp + "/sh.rendered", encoding="utf-8").read()
# install_brew's body is macOS-gated, so on a Linux render it is absent and a
# stray `brew install sevenzip` in a helper must not be mistaken for it. The
# cask loop only exists inside install_brew, so it is the marker.
formulas, casks = set(), set()
for m in re.finditer(r'^\s*brew install (?!--cask)([^|\n]+)', sh, re.M):
    formulas |= set(m.group(1).split())
for m in re.finditer(r'^\s*brew install --cask ([^|\n]+)', sh, re.M):
    casks |= set(m.group(1).split())
m = re.search(r'for cask in ([^;\n]+); do', sh)
if m: casks |= set(m.group(1).split())
# Formula lines render on every Unix platform (install_brew is defined
# everywhere, called only on macOS); the dev_desktop cask loop is inside a
# darwin gate, so casks are asserted only where that loop rendered.
if formulas:
    lost = set(brew) - formulas
    if lost: err("sh render: catalog brew formulas never rendered: %s" % sorted(lost))
    else: print("  rendered .sh: every catalog brew formula (%d) appears in install_brew" % len(brew))
if m:
    lost = set(cask) - casks
    if lost: err("sh render: catalog casks never rendered: %s" % sorted(lost))
    else: print("  rendered .sh: every catalog cask (%d) appears in install_brew" % len(cask))
# The bug this catches: a fragment emitting its own trailing newline splits
# `for pkg in a b c` from `; do` - a syntax error only a Unix render shows.
# A line ending in a backslash is a deliberate shell continuation (the zoxide
# install does this), not a split - hence the lookbehind.
if re.search(r'^(for \w+ in [^\n]*|\s*brew install [^\n]*|\s*\$SUDO apt install -y [^\n]*)(?<!\\)\n\s*(; do|\|\|)', sh, re.M):
    err("sh render: a package list is split from its `; do` / `||` by a newline - a fragment is emitting its trailing newline")

# 4. migrate universe
uni = open(tmp + "/migrate-universe.txt").read().split()
want = [r["choco"] for r in cat if "choco" in r and r.get("migrate", True) is not False]
if sorted(uni) != sorted(want):
    err("migrate universe expression: missing=%s extra=%s" % (sorted(set(want)-set(uni)), sorted(set(uni)-set(want))))
excluded = [r["choco"] for r in cat if r.get("migrate") is False]
print("  catalog: %d tools, %d choco / %d brew / %d cask / %d apt names; migrate universe %d (excluded: %s)"
      % (len(cat), len(choco), len(brew), len(cask), sum(1 for r in cat if "apt" in r), len(uni), ", ".join(excluded) or "none"))
sys.exit(1 if bad else 0)
PYEOF

if [ "$failures" -gt 0 ]; then
    printf '\nFAIL: package catalog (%d problem(s))\n' "$failures" >&2
    exit 1
fi
printf 'PASS: package names live only in .chezmoidata/packages.yaml; installers and migrate-to-choco render or read it\n'
