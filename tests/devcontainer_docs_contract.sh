#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
guide="$repo_root/docs/devcontainer.md"
ci_workflow="$repo_root/.github/workflows/ci.yml"

# Resolve a real Python: on Windows `python3` on PATH is usually the Microsoft
# Store stub, which prints an ad and exits non-zero, so probe before using it.
PY_BIN=""
for c in python3 python "py -3"; do
    if $c -c "" >/dev/null 2>&1; then PY_BIN="$c"; break; fi
done
[ -n "$PY_BIN" ] || { printf 'SKIP: no working Python interpreter (tried python3, python, py -3)\n'; exit 0; }

$PY_BIN - "$guide" <<'PY'
import json
import re
import sys
from pathlib import Path

guide = Path(sys.argv[1]).read_text(encoding="utf-8")  # Windows defaults to cp1252
flat_guide = re.sub(r"\s+", " ", guide)

def section(start, end):
    try:
        return guide.split(start, 1)[1].split(end, 1)[0]
    except IndexError:
        raise SystemExit(f"FAIL: missing section {start!r}")

base = section("### 1. Add Features", "### 2. Add Dotfiles")
base_example = re.search(r"```json\n(.*?)\n```", base, re.DOTALL)
if not base_example:
    raise SystemExit("FAIL: base feature JSON example missing")
try:
    base_features = json.loads(base_example.group(1))["features"]
except (json.JSONDecodeError, KeyError) as error:
    raise SystemExit(f"FAIL: invalid base feature JSON: {error}")
if any("nerd-font" in key for key in base_features):
    raise SystemExit("FAIL: base feature example must not recommend nerd-font")

complete = section("### 3. Complete Example", "### 4. Agent-workstation")
complete_example = re.search(r"```json\n(.*?)\n```", complete, re.DOTALL)
if not complete_example:
    raise SystemExit("FAIL: complete example JSON missing")
try:
    complete_features = json.loads(complete_example.group(1))["features"]
except (json.JSONDecodeError, KeyError) as error:
    raise SystemExit(f"FAIL: invalid complete example JSON: {error}")
for disallowed in ("codex", "curated-skills", "guardrail", "playwright"):
    if any(disallowed in key for key in complete_features):
        raise SystemExit(f"FAIL: complete example must remain lightweight ({disallowed})")

profile = section("### 4. Agent-workstation profile (optional)", "### 5. OpenCode")
match = re.search(r"```json\n(.*?)\n```", profile, re.DOTALL)
if not match:
    raise SystemExit("FAIL: agent-workstation JSON example missing")
try:
    features = json.loads(match.group(1))["features"]
except (json.JSONDecodeError, KeyError) as error:
    raise SystemExit(f"FAIL: invalid agent-workstation JSON: {error}")

for feature in (
    "codex:1",
    "curated-skills:1",
    "guardrail:1",
    "playwright:1",
):
    if not any(key.endswith(feature) for key in features):
        raise SystemExit(f"FAIL: agent-workstation profile missing {feature}")

if "has no devcontainer feature" not in profile:
    raise SystemExit("FAIL: agent-workstation profile must disclose act parity gap")

security = section("### 5. OpenCode server safety", "### 6. Persist")
security = re.sub(r"\s+", " ", security)
for phrase in (
    "OPENCODE_SERVER_PASSWORD",
    "0.0.0.0",
    "container runtime",
    "runtime environment",
    "secret mechanism",
):
    if phrase not in security:
        raise SystemExit(f"FAIL: OpenCode security guidance missing {phrase!r}")

persistence = section("### 6. Persist", "### What happens")
persistence_text = re.sub(r"\s+", " ", persistence)
persistence_example = re.search(r"```json\n(.*?)\n```", persistence, re.DOTALL)
if not persistence_example:
    raise SystemExit("FAIL: persistence JSON example missing")
try:
    mounts = json.loads(persistence_example.group(1))["mounts"]
except (json.JSONDecodeError, KeyError) as error:
    raise SystemExit(f"FAIL: invalid persistence JSON: {error}")
for path in (
    "/home/vscode/.claude",
    "/home/vscode/.codex",
    "/home/vscode/.config/opencode",
):
    if not any(path in mount for mount in mounts):
        raise SystemExit(f"FAIL: persistence example missing {path}")

if any("/home/vscode/.local/share/opencode" in mount for mount in mounts):
    raise SystemExit("FAIL: OpenCode data path must not be a default persistence mount")
if "optional user-managed data path" not in persistence_text:
    raise SystemExit("FAIL: OpenCode data path must be documented as optional")

if any(".claude.json" in mount and "type=volume" in mount for mount in mounts):
    raise SystemExit("FAIL: .claude.json must not be mounted as a named volume")
if "named volumes are directories" not in persistence_text or "bind mount" not in persistence_text:
    raise SystemExit("FAIL: Claude file persistence guidance missing")

for phrase in ("Debian/Ubuntu", "Linux x86_64", "does not affect VS Code"):
    if phrase not in flat_guide:
        raise SystemExit(f"FAIL: guide missing {phrase!r}")
PY

grep -Fq -- 'bash tests/devcontainer_docs_contract.sh' "$ci_workflow" || {
    printf 'FAIL: ci.yml: devcontainer documentation contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: devcontainer documentation contract\n'
