#!/usr/bin/env bash
set -euo pipefail

# One source for every CI job's chezmoi.toml.
#
# The workflows used to carry nine hand-written fixtures that were supposed to
# be equivalent and were not: the Unix single-account one lacked username and
# provider, the Windows one had them, and a template bug therefore failed on
# two platforms and passed on the third. The platform was irrelevant; the
# fixtures differed. This test makes that class impossible three ways:
#
#   1. The fixture files are well-formed and each keeps the property it exists
#      for (single = fully described; minimal = ONLY name and email; the package
#      knobs carry exactly the groups .chezmoi.toml.tmpl prompts for).
#   2. Every workflow composes from them - no inline [[data.accounts]] or
#      [data.packages] anywhere, so a fixture cannot exist outside this set.
#   3. Values that jobs assert on (alice/bob, "Minimal User") are the values in
#      the fixture, so renaming one side without the other fails here first.
#
# Bash composes; Python only parses. Python must never be the one to invoke
# `bash`: on Windows the first bash.exe on PATH is often System32's WSL
# launcher, which cannot see a C:/ path at all. This script is already running
# under the right bash, so it composes into a temp dir and hands Python files.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fx="$repo_root/tests/fixtures/chezmoi"
ci="$repo_root/.github/workflows/ci.yml"
full="$repo_root/.github/workflows/full-install-test.yml"
failures=0
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import tomllib' 2>/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || { printf 'SKIP: no python with tomllib (3.11+)\n'; exit 0; }

for f in accounts-single accounts-multi accounts-minimal packages-on packages-off; do
    [ -f "$fx/$f.toml" ] || fail "missing fixture $f.toml"
done
[ -f "$fx/compose.sh" ] || fail "missing compose.sh"
[ "$failures" -eq 0 ] || { printf '\nFAIL: CI fixtures (%d problem(s))\n' "$failures" >&2; exit 1; }

# ---------------------------------------------------------------- 1. fixtures
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for acc in single multi minimal; do
    for pkg in on off; do
        bash "$fx/compose.sh" "$acc" "$pkg" > "$tmp/$acc-$pkg.toml" ||
            fail "compose.sh $acc $pkg exited non-zero"
    done
done
bash "$fx/compose.sh" minimal on --source-dir 'D:\a\dotfiles\dotfiles' > "$tmp/with-source-dir.toml" ||
    fail "compose.sh with --source-dir exited non-zero"

"$PY" - "$repo_root" "$tmp" <<'PYEOF' || fail "fixture shape checks failed (see above)"
import re, sys, tomllib
root, tmp = sys.argv[1], sys.argv[2]
bad = 0
def err(m):
    global bad; bad += 1; print("  " + m, file=sys.stderr)

def load(name):
    try:
        with open("%s/%s.toml" % (tmp, name), "rb") as fh:
            return tomllib.load(fh)
    except Exception as e:
        err("%s: invalid TOML: %s" % (name, e)); return None

cfg = open(root + "/.chezmoi.toml.tmpl", encoding="utf-8").read()
groups = set(re.findall(r'promptBoolOnce \. "packages\.([a-z_]+)"', cfg))
if not groups:
    err(".chezmoi.toml.tmpl: no promptBoolOnce groups found - parser is stale")

docs = {}
for acc in ("single", "multi", "minimal"):
    for pkg in ("on", "off"):
        d = load("%s-%s" % (acc, pkg))
        if d is None: continue
        docs[(acc, pkg)] = d
        have = set(d["data"]["packages"])
        if have != groups:
            err("packages-%s: keys differ from .chezmoi.toml.tmpl: missing=%s extra=%s"
                % (pkg, sorted(groups - have), sorted(have - groups)))

d = load("with-source-dir")
if d is not None and d.get("sourceDir") != r"D:\a\dotfiles\dotfiles":
    err("--source-dir did not survive as a TOML literal string: %r" % d.get("sourceDir"))

def accounts(acc):
    d = docs.get((acc, "off"))
    return None if d is None else d["data"]["accounts"]

single = accounts("single")
if single is not None and (len(single) != 1 or not {"username", "provider"} <= set(single[0])):
    err("accounts-single must carry username AND provider - their absence was the original drift")

minimal = accounts("minimal")
if minimal is not None and (len(minimal) != 1 or set(minimal[0]) != {"name", "email"}):
    err("accounts-minimal must contain ONLY name and email (it proves optional keys can be absent); has %s"
        % sorted(minimal[0]))

multi = accounts("multi")
if multi is not None and [a.get("username") for a in multi] != ["alice", "bob"]:
    err("accounts-multi must be alice then bob - integration-test asserts on those names")

on = docs.get(("minimal", "on"))
if on is not None:
    p = on["data"]["packages"]
    for k in ("remote_access_server", "guardrail"):
        if p.get(k) is not False:
            err("packages-on: %s must stay false (see the comment in the file)" % k)
    if not all(v is True for k, v in p.items() if k not in ("remote_access_server", "guardrail")):
        err("packages-on: every other group must be true")
off = docs.get(("minimal", "off"))
if off is not None and any(v is not False for v in off["data"]["packages"].values()):
    err("packages-off: every group must be false")

sys.exit(1 if bad else 0)
PYEOF

# ------------------------------------------------ 2. no fixture outside the set
for wf in "$ci" "$full"; do
    if grep -qE '\[\[data\.accounts\]\]|\[data\.packages\]' "$wf"; then
        fail "$(basename -- "$wf"): carries an inline chezmoi.toml fixture - compose it from tests/fixtures/chezmoi instead"
    fi
done

# Every composer call names fixtures that exist. An array, not a pipe into
# `while read`: a pipe runs the loop in a subshell, where fail() cannot
# increment $failures - the message would print and the test would still pass.
mapfile -t calls < <(grep -hoE 'compose\.sh +[a-z]+ +[a-z]+' "$ci" "$full")
for call in "${calls[@]}"; do
    read -r _ acc pkg <<<"$call"
    [ -f "$fx/accounts-$acc.toml" ] || fail "workflow composes accounts-$acc, which does not exist"
    [ -f "$fx/packages-$pkg.toml" ] || fail "workflow composes packages-$pkg, which does not exist"
done
[ "${#calls[@]}" -ge 9 ] || fail "expected at least 9 composer calls across both workflows, found ${#calls[@]}"

# ---------------------------------- 3. asserted values live in the fixtures
# Each is "the workflow asserts X" AND "the fixture provides X"; if either side
# is renamed alone, this fails before CI does.
tied() { # $1=what the job asserts  $2=fixture file  $3=what it must contain  $4=message
    if grep -Fq -- "$1" "$ci" && ! grep -Fq -- "$3" "$fx/$2"; then fail "$4"; fi
}
tied 'github-alice'               accounts-multi.toml   'username = "alice"'    "integration-test asserts on github-alice but accounts-multi no longer defines alice"
tied 'IdentityFile ~/.ssh/id_bob' accounts-multi.toml   'key = "id_bob"'        "integration-test asserts on id_bob but accounts-multi no longer sets it"
tied 'name = "Minimal User"'      accounts-minimal.toml 'name = "Minimal User"' 'minimal-config-test asserts on "Minimal User" but accounts-minimal no longer uses that name'

if [ "$failures" -gt 0 ]; then
    printf '\nFAIL: CI fixtures (%d problem(s))\n' "$failures" >&2
    exit 1
fi
printf 'PASS: every CI chezmoi.toml composes from one fixture set, and each shape keeps its purpose\n'
