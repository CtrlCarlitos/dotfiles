#!/usr/bin/env bash
set -euo pipefail

# Regenerates the per-program package table in docs/tool-parity.md (#105).
#
# Since #101 the package universe has one source, .chezmoidata/packages.yaml:
# the installers render from it, migrate-to-choco reads it at runtime, and
# tests/package_catalog_contract.sh enforces both. The per-program table in
# docs/tool-parity.md was the last hand-maintained copy, and it drifted. This
# script renders the catalog into that table, between HTML-comment markers, so
# the doc stays a plain file readable on GitHub while the table itself is
# machine-owned; tests/docs_contracts.sh fails when the committed section
# differs from a fresh render.
#
#   bash scripts/gen-tool-parity.sh [DOC]   (default: docs/tool-parity.md)
#
# Like the tests: bash drives, chezmoi renders the YAML catalog to JSON, and
# python3 (no PyYAML - CI does not carry it) builds the markdown. Idempotent:
# run it twice, get the same file. Cells:
#
#   `name`      the catalog's name for that manager
#   procedure   the record's note documents a by-procedure install for that
#               manager (repo + key, .deb/.dmg download) - no plain name
#   —           the catalog names no package for that manager
#
# Prose stays OUTSIDE the markers; the generator only ever rewrites the span
# between them and never seeds commentary from the notes.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
doc="${1:-$repo_root/docs/tool-parity.md}"
catalog="$repo_root/.chezmoidata/packages.yaml"

[ -f "$doc" ] || { echo "gen-tool-parity: doc not found: $doc" >&2; exit 1; }
[ -f "$catalog" ] || { echo "gen-tool-parity: catalog not found: $catalog" >&2; exit 1; }
command -v chezmoi >/dev/null 2>&1 || { echo "gen-tool-parity: chezmoi not installed" >&2; exit 1; }
PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' 2>/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "gen-tool-parity: no python3/python" >&2; exit 1; }

# An empty config: the host's own chezmoi.toml must not shape the render
# (same rule as tests/lib.sh's render helper).
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/empty.toml"
printf '{{ .catalog.packages | toJson }}' > "$tmp/catalog.json.tmpl"
chezmoi execute-template --config "$tmp/empty.toml" --source "$repo_root" \
    --file "$tmp/catalog.json.tmpl" > "$tmp/catalog.json"

"$PY" - "$tmp/catalog.json" "$doc" <<'PYEOF'
import io, json, re, sys

catalog_path, doc_path = sys.argv[1], sys.argv[2]
BEGIN = re.compile(r'<!--\s*tool-parity:packages-begin\b[^>]*-->')
END = re.compile(r'<!--\s*tool-parity:packages-end\b[^>]*-->')

cat = json.load(io.open(catalog_path, encoding="utf-8"))

# Managers whose install a record's note documents as a procedure. Labels look
# like "apt:" / "choco:" / "brew/apt:" at the start of a sentence or after a
# semicolon; the span from one label to the next must say "procedure". A bare
# mention ("never choco", "migrate-to-choco") is not a label.
LABEL = re.compile(
    r'(?:^|(?<=;)|(?<=\.\s))\s*((?:apt|brew|cask|choco)(?:/(?:apt|brew|cask|choco))*)\s*:')
def procedures(note):
    out = set()
    marks = list(LABEL.finditer(note))
    for i, m in enumerate(marks):
        span = note[m.end(): marks[i + 1].start() if i + 1 < len(marks) else len(note)]
        if re.search(r'\bprocedure\b', span, re.I):
            out.update(m.group(1).split('/'))
    return out

def cell(r, manager, proc):
    if manager in r:
        return "`%s`" % r[manager]
    if manager in proc:
        return "procedure"
    return "\u2014"

lines = [
    "| Tool | Group | apt (Linux/WSL) | brew | cask (macOS) | choco (Windows) | Notes |",
    "| :--- | :--- | :--- | :--- | :--- | :--- | :--- |",
]
for r in cat:
    note = r.get("note", "")
    proc = procedures(note)
    lines.append("| `%s` | %s | %s | %s | %s | %s | %s |" % (
        r["id"], r.get("group", ""),
        cell(r, "apt", proc), cell(r, "brew", proc),
        cell(r, "cask", proc), cell(r, "choco", proc),
        note.replace("|", "\\|"),
    ))
table = "\n".join(lines)

doc = io.open(doc_path, encoding="utf-8", newline="").read()
begin, end = BEGIN.search(doc), END.search(doc)
if not begin or not end or begin.end() > end.start():
    sys.stderr.write("gen-tool-parity: %s has no tool-parity:packages begin/end markers\n" % doc_path)
    raise SystemExit(2)

out = doc[:begin.end()] + "\n" + table + "\n" + doc[end.start():]
io.open(doc_path, "w", encoding="utf-8", newline="").write(out)
print("  %s: %d tool rows regenerated from %s" % (doc_path, len(cat), catalog_path))
PYEOF
