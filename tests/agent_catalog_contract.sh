#!/usr/bin/env bash
set -euo pipefail

# The agent catalog is the only place agent-toolkit DATA may live.
#
# The logic that installs and wires Serena, Graft, Codex and the curated skills
# is procedure in two languages and stays in the installers. The values inside
# it are what drift, and they had multiplied: the MCP server table was written
# six times (four in the .sh alone - its agent_toolkit block exists once under
# install_apt and once under install_brew, byte for byte), the graft
# allow-scripts list three times, the Codex package and the skills agent list
# four times each. .chezmoidata/agents.yaml is now the one copy.
#
#   1. SHAPE     each MCP server has a command and args; the allow-scripts list
#                names graft itself plus tree-sitter grammars only; the skills
#                agent list is non-empty; the codex package is scoped.
#   2. NO COPY   no consumer carries a value of its own: no literal
#                start-mcp-server, tree-sitter allow-list, @openai/codex or
#                agent array in either installer template or either updater.
#   3. RENDERS   both twins, rendered with an empty --config and
#                --override-data (every group on, OS forced), emit exactly the
#                catalog's values - the MCP table in both shapes, the
#                allow-scripts string, the codex package, the agent list.
#   4. RUNTIME   the updaters read the catalog through chezmoi execute-template,
#                and the expressions they use evaluate to the catalog's values.
#
# Bash renders, Python parses; Python never shells out to bash (on Windows the
# first bash.exe on PATH can be System32's WSL launcher).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cat_file="$repo_root/.chezmoidata/agents.yaml"
ps_t="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_t="$repo_root/run_onchange_install_packages.sh.tmpl"
up_sh="$repo_root/scripts/update_ai_tools.sh"
up_ps="$repo_root/scripts/update_ai_tools.ps1"

. "$repo_root/tests/lib.sh"

[ -f "$cat_file" ] || { fail "$cat_file missing"; exit 1; }
for f in ps-list mcp-servers-ps1; do
    [ -f "$repo_root/.chezmoitemplates/$f" ] || fail ".chezmoitemplates/$f missing"
done

# ------------------------------------------------- 2. no consumer keeps a copy
no_literal() { # $1=file $2=fixed string $3=what it is
    if grep -Fq -- "$2" "$1"; then fail "$(basename -- "$1"): literal '$2' is back - $3 comes from .chezmoidata/agents.yaml"; fi
}
for f in "$ps_t" "$sh_t" "$up_sh" "$up_ps"; do
    no_literal "$f" 'start-mcp-server' 'the MCP server table'
    no_literal "$f" 'allow-scripts=@nanonets/graft,tree-sitter' 'the graft allow-scripts list'
    no_literal "$f" '@openai/codex' 'the codex package name'
    no_literal "$f" "@('claude-code', 'opencode', 'codex')" 'the skills agent list'
    no_literal "$f" 'AGENTS=(claude-code opencode codex)' 'the skills agent list'
done
for f in "$ps_t" "$sh_t"; do
    grep -Fq '.agents.mcp' "$f" || fail "$(basename -- "$f"): no longer renders the MCP table from the catalog"
    grep -Fq '.agents.npm.graft_allow_scripts' "$f" || fail "$(basename -- "$f"): no longer renders the graft allow-scripts list"
    grep -Fq '.agents.npm.codex' "$f" || fail "$(basename -- "$f"): no longer renders the codex package"
    grep -Fq '.agents.skills.agents' "$f" || fail "$(basename -- "$f"): no longer renders the skills agent list"
done
for f in "$up_sh" "$up_ps"; do
    grep -Fq "execute-template '{{ .agents.npm.codex }}'" "$f" || fail "$(basename -- "$f"): does not read the codex package at runtime"
    grep -Fq '.agents.skills.agents' "$f" || fail "$(basename -- "$f"): does not read the skills agent list at runtime"
done

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
# render) + this repo as source.
grep -oE 'promptBoolOnce \. "packages\.[a-z_]+"' "$repo_root/.chezmoi.toml.tmpl" \
    | sed -E 's/.*"packages\.([a-z_]+)"/\1/' > "$tmp/groups.txt"
all_on="{$(sed -E 's/.*/"&":true/' "$tmp/groups.txt" | paste -sd, -)}"

render '{{ .agents | toJson }}' > "$tmp/agents.json" || fail "agent catalog does not render (YAML broken?)"
# 4. the exact expressions the updaters evaluate at runtime
render '{{ .agents.npm.codex }}' > "$tmp/codex.txt" || fail "updater expression for the codex package does not render"
render '{{ join " " .agents.skills.agents }}' > "$tmp/agents-sp.txt" || fail "updater expression for the agent list (sh) does not render"
render '{{ join "," .agents.skills.agents }}' > "$tmp/agents-comma.txt" || fail "updater expression for the agent list (ps1) does not render"
# 3. both twins
render --override-data "{\"chezmoi\":{\"os\":\"windows\"},\"packages\":$all_on}" --file "$ps_t" > "$tmp/ps1.rendered" 2>"$tmp/e1" ||
    fail "the .ps1 twin does not render: $(head -c 300 "$tmp/e1")"
render --override-data "{\"chezmoi\":{\"os\":\"linux\",\"kernel\":{\"osrelease\":\"6.8-generic\"}},\"packages\":$all_on}" --file "$sh_t" > "$tmp/sh.rendered" 2>"$tmp/e2" ||
    fail "the .sh twin does not render: $(head -c 300 "$tmp/e2")"

"$PY" - "$tmp" <<'PYEOF' || fail "agent catalog checks failed (see above)"
import json, re, sys, io
tmp = sys.argv[1]
bad = 0
def err(m):
    global bad; bad += 1; print("  " + m, file=sys.stderr)
def read(n): return io.open("%s/%s" % (tmp, n), encoding="utf-8", newline="").read()

a = json.load(open(tmp + "/agents.json", encoding="utf-8"))

# 1. shape
mcp = a.get("mcp", {})
if not mcp: err("agents.mcp is empty")
for name, srv in mcp.items():
    if not isinstance(srv.get("command"), str) or not srv["command"]: err("mcp.%s: command must be a non-empty string" % name)
    if not isinstance(srv.get("args"), list) or not srv["args"]: err("mcp.%s: args must be a non-empty list" % name)
for s in ("serena", "graft"):
    if s not in mcp: err("mcp.%s missing - both installers register it" % s)
allow = a.get("npm", {}).get("graft_allow_scripts", [])
if "@nanonets/graft" not in allow: err("npm.graft_allow_scripts must include @nanonets/graft itself")
for pkg in allow:
    if pkg != "@nanonets/graft" and "tree-sitter" not in pkg: err("npm.graft_allow_scripts: %r is not a tree-sitter package" % pkg)
codex = a.get("npm", {}).get("codex", "")
if not codex.startswith("@openai/"): err("npm.codex must be the scoped @openai package, got %r" % codex)
agents = a.get("skills", {}).get("agents", [])
if not agents: err("skills.agents is empty")
if "antigravity" in agents: err("skills.agents must not include antigravity (no skills CLI adapter; it gets copies)")

# 4. runtime expressions
if read("codex.txt").strip() != codex: err("updater codex expression != catalog")
if read("agents-sp.txt").strip().split() != agents: err("updater agent-list expression (sh) != catalog")
if read("agents-comma.txt").strip().split(",") != agents: err("updater agent-list expression (ps1) != catalog")

# 3. renders
allow_str = "--allow-scripts=" + ",".join(allow)
ps1 = read("ps1.rendered")
sh = read("sh.rendered")

if allow_str not in ps1: err("ps1 render: graft allow-scripts string not rendered verbatim")
# #124 hoisted the shared agent-toolkit sections out of install_apt/install_brew
# into one install_agent_toolkit, so the string renders ONCE now (was 2).
if sh.count(allow_str) != 1: err("sh render: graft allow-scripts string expected once (shared toolkit), found %d" % sh.count(allow_str))
if ("npm install -g %s " % codex) not in ps1: err("ps1 render: codex install line not rendered")
# #124: the sh Codex install is shared now and runs through the run-once
# $NPM_BIN/$npm_sudo pair, so pin the package name + install verb instead of
# the literal "npm install -g" prefix.
if ("install -g %s " % codex) not in sh: err("sh render: codex install line not rendered")
ps_list = ", ".join("'%s'" % x for x in agents)
if ps1.count("$skAgents = @(%s)" % ps_list) < 1: err("ps1 render: skills agent list not rendered")
if ("AGENTS=(%s)" % " ".join(agents)) not in sh: err("sh render: skills agent list not rendered")

# MCP: the ps1 gets a $mcpCatalog hashtable; both consumers reference it
m = re.search(r"\$mcpCatalog = @\{(.*?)\n\}", ps1, re.S)
if not m: err("ps1 render: $mcpCatalog not rendered")
else:
    body = m.group(1)
    for name, srv in mcp.items():
        want = "%s = @{ command = '%s'; args = @(%s) }" % (name, srv["command"], ", ".join("'%s'" % x for x in srv["args"]))
        if want not in body: err("ps1 render: $mcpCatalog lacks %s as %s" % (name, want))
    for ref in ("$mcpCatalog.serena.command", "$mcpCatalog.graft.args"):
        if ref not in ps1: err("ps1 render: OpenCode/agy wiring does not consume %s" % ref)
# the sh embeds the table as JSON inside its python heredocs. #124: the two
# registration blocks live in the shared install_agent_toolkit now, so the
# table renders twice (opencode + agy), not four times (was 2 blocks x
# apt/brew). Anchor on the `srv in` loop/comprehension: the VS Code tiers
# (phase B) are also json.loads(r"""{...}""") blocks and must not be counted.
sh_json = json.dumps(mcp, separators=(",", ":"), sort_keys=True)
found = [json.loads(x) for x in re.findall(r'srv in json\.loads\(r"""(\{.*?\})"""\)', sh)]
if len(found) != 2: err("sh render: expected the MCP table embedded 2 times (shared toolkit), found %d" % len(found))
for d in found:
    if json.dumps(d, separators=(",", ":"), sort_keys=True) != sh_json: err("sh render: an embedded MCP table differs from the catalog")

print("  catalog: %d MCP servers, %d allow-scripts entries, codex=%s, agents=%s" % (len(mcp), len(allow), codex, ",".join(agents)))
print("  rendered .ps1: $mcpCatalog + 4 consumers, allow-scripts, codex, %d agent-list sites" % ps1.count("$skAgents = @("))
print("  rendered .sh : MCP table x4, allow-scripts x2, codex, AGENTS - all from the catalog")
sys.exit(1 if bad else 0)
PYEOF

finish
