#!/usr/bin/env bash
set -euo pipefail

# Structural contracts for the documentation.
#
# tests/docs_consistency.sh asserts that specific sentences exist. This one
# asserts the docs are structurally sound, which is the failure mode actually
# observed: docs/windows.md shipped five user-facing "TODO: Document ..."
# placeholders, claimed "no dp alias is defined for PowerShell yet" when the
# function existed, referenced install_fonts (renamed to the `fonts` group),
# and two docs linked to a README anchor that no longer existed. Every one of
# those is machine-checkable and none of them failed anything.
#
# Deliberately NOT checked: behavioural claims about third-party tools. The
# worst doc error found so far - recommending Ctrl+C as the universal
# clear-the-box chord when it is the one chord agy intercepts - was
# well-formed, internally consistent and wrong. No linter catches that; see
# issue #85 for the version-pinning idea that partially mitigates it.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

PY_BIN=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)' 2>/dev/null; then
        PY_BIN="$c"; break
    fi
done
[ -n "$PY_BIN" ] || skip "no working Python interpreter (tried python3, python)"

"$PY_BIN" - "$repo_root" <<'PYEOF'
import io, os, re, sys

root = sys.argv[1]
problems = []

def rel(p):
    return p.replace(os.sep, "/")

def read(path):
    with io.open(os.path.join(root, path), encoding="utf-8") as fh:
        return fh.read()

docs = ["README.md"] + sorted(
    os.path.join("docs", f) for f in os.listdir(os.path.join(root, "docs"))
    if f.endswith(".md")
)

HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)
FENCE = re.compile(r"```.*?```", re.S)

def visible(text):
    """Prose a reader actually sees: no HTML comments, no fenced code."""
    return FENCE.sub("", HTML_COMMENT.sub("", text))

def slug(heading):
    """GitHub's heading -> anchor rule."""
    s = heading.strip().lower()
    s = re.sub(r"`([^`]*)`", r"\1", s)          # drop code ticks, keep content
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)  # link text only
    s = re.sub(r"[^\w\s-]", "", s)              # emoji/punctuation out, spaces kept
    # No second strip: GitHub trims first, THEN removes the emoji, so the space
    # it left behind becomes a leading hyphen ("## 🚀 Install" -> "-install").
    return s.replace(" ", "-")

ANCHOR_TAG = re.compile(r"<a\s[^>]*(?:id|name)=[\"']([^\"']+)[\"']", re.I)

def anchors(text):
    seen, out = {}, set(ANCHOR_TAG.findall(text))
    for line in text.splitlines():
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if not m:
            continue
        a = slug(m.group(2))
        n = seen.get(a, 0)
        seen[a] = n + 1
        out.add(a if n == 0 else "%s-%d" % (a, n))
    return out

# ---------------------------------------------------------------- 1. TODOs
# In an HTML comment a TODO is a maintainer's note the reader never sees.
# In visible prose it is an unkept promise, which is what shipped before.
for d in docs:
    for i, line in enumerate(visible(read(d)).splitlines(), 1):
        if re.search(r"\b(TODO|FIXME|XXX)\b", line):
            problems.append("%s:%d: visible %s in user-facing prose: %s"
                            % (rel(d), i, re.search(r"\b(TODO|FIXME|XXX)\b", line).group(1), line.strip()[:70]))

# ------------------------------------------------- 2. links and anchors
anchor_cache = {}
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")

for d in docs:
    text = read(d)
    own = anchors(text)
    for target in LINK.findall(visible(text)):
        if re.match(r"^(https?:|mailto:|#!)", target):
            continue
        path, _, frag = target.partition("#")
        frag = frag.strip()

        if not path:                                    # same-file anchor
            if frag and frag not in own:
                problems.append("%s: link to #%s - no such heading in this file" % (rel(d), frag))
            continue

        resolved = os.path.normpath(os.path.join(os.path.dirname(d), path))
        if not os.path.exists(os.path.join(root, resolved)):
            problems.append("%s: link to %s - file does not exist" % (rel(d), target))
            continue

        if frag and resolved.endswith(".md"):
            if resolved not in anchor_cache:
                anchor_cache[resolved] = anchors(read(resolved))
            if frag not in anchor_cache[resolved]:
                problems.append("%s: link to %s - %s has no such heading" % (rel(d), target, rel(resolved)))

# --------------------------------------------- 3. package groups agree
cfg = read(".chezmoi.toml.tmpl")
canonical = set(re.findall(r'promptBoolOnce \. "packages\.([a-z_]+)"', cfg))
if not canonical:
    problems.append(".chezmoi.toml.tmpl: no promptBoolOnce package groups found - parser is stale")

pg = read("docs/package-groups.md")
documented = set(re.findall(r"^\|\s*`([a-z_]+)`", pg, re.M))
PRESETS = {"minimal", "standard", "full", "custom"}

for g in sorted(canonical - documented):
    problems.append("docs/package-groups.md: group '%s' exists in .chezmoi.toml.tmpl but is undocumented" % g)
for g in sorted(documented - canonical - PRESETS):
    problems.append("docs/package-groups.md: documents '%s', which is not a promptBoolOnce group (renamed or removed?)" % g)

# ------------------------------- 4. documented settings really are set
# The install_fonts class: prose naming a setting the installers never write.
# The tiers now live in .chezmoidata.yaml and are rendered by both twins
# (#83), so "is this setting actually written?" must look there too.
installers = (read("run_onchange_install_packages.sh.tmpl")
              + read("run_onchange_install_packages.ps1.tmpl")
              + read(".chezmoidata.yaml"))
SETTING = re.compile(r"`((?:terminal\.integrated|remote\.SSH)\.[A-Za-z.]+)`")
# Settings the docs REFERENCE but deliberately do not set. Each needs a reason:
# the check exists to catch prose claiming we configure something we never
# touch, not to ban naming a third-party default.
REFERENCED_NOT_SET = {
    # VS Code's own default (inherited); cited to explain why a split terminal
    # opens in the current folder. We rely on it, we do not write it.
    "terminal.integrated.splitCwd",
}
for d in docs:
    for s in set(SETTING.findall(read(d))) - REFERENCED_NOT_SET:
        if s not in installers:
            problems.append("%s: documents setting `%s`, which neither installer writes" % (rel(d), s))

if problems:
    for p in problems:
        sys.stderr.write("  %s\n" % p)
    sys.stderr.write("\nFAIL: %d documentation problem(s)\n" % len(problems))
    raise SystemExit(1)

print("  checked %d docs: no visible TODOs, links and anchors resolve," % len(docs))
print("  %d package groups agree with .chezmoi.toml.tmpl, documented settings exist" % len(canonical))
PYEOF

finish
