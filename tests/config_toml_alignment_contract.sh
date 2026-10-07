#!/usr/bin/env bash
set -euo pipefail

# TOML alignment rule: in every block of two or more consecutive `key = value`
# lines, the "=" signs share one column (a block ends at a [table] header, a
# comment or a blank line; a single line can be anything). chezmoi.toml is
# rewritten by `chezmoi init` on every `dot up`, so for it the rule is held where
# it is produced:
#   1. every TOML file in the repo (git ls-files *.toml): .chezmoiexternal.toml,
#      starship.toml, .gitleaks.toml, the VS Code settings seed, the documented
#      example, the CI config fixtures...;
#   2. .chezmoi.toml.tmpl rendered from a fixture carrying every key it emits
#      (accounts with every fingerprint field, SSH hosts with every optional key,
#      VS Code settings and overrides with nested values) - every block aligned,
#      and the data comes back unchanged;
#   3. .chezmoitemplates/toml-align, which aligns the sections toToml writes,
#      executed on a sample.
# Commented example lines (# key = value) are documentation and not checked.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

command -v python3 >/dev/null 2>&1 || skip "python3 not installed"

cat >"$tmp/check.py" <<'PYEOF'
import re, sys
kv = re.compile(r'^(\s*(?:"[^"]*"|[A-Za-z0-9_.-]+))\s*=(?:\s|$)')
bad = []
for path in sys.argv[1:]:
    lines = open(path, encoding="utf-8").read().replace("\r\n", "\n").split("\n")
    block = []
    def flush():
        if len(block) > 1 and len({col for _, col, _ in block}) > 1:
            bad.append("%s:%d-%d: '=' not aligned:\n%s" % (path, block[0][0], block[-1][0],
                       "\n".join("    " + text for _, _, text in block)))
        block.clear()
    for n, line in enumerate(lines, 1):
        m = kv.match(line)
        if m:
            block.append((n, line.index("=", len(m.group(1))), line[:110]))
        else:
            flush()
    flush()
print("\n".join(bad))
PYEOF

# --- 1. every TOML file in the repo ---------------------------------------------------
mapfile -t toml_files < <(git -C "$repo_root" ls-files '*.toml' '*.toml.example' | sed "s|^|$repo_root/|")
[ "${#toml_files[@]}" -ge 10 ] || fail "expected at least 10 TOML files in the repo, found ${#toml_files[@]} (git ls-files broken?)"
out="$(python3 "$tmp/check.py" "${toml_files[@]}")"
[ -z "$out" ] || fail "$out"
pass

if ! command -v chezmoi >/dev/null 2>&1; then
    printf 'note: chezmoi not installed - render checks skipped\n'
    finish
    exit 0
fi

# --- 2. the rendered config template --------------------------------------------------
cat >"$tmp/fixture.toml" <<'EOF'
[data.packages]
  core = true
  vscode_settings = true

[data.vscode.settings]
  junk = ["**/node_modules/**"]
  unset = ["remote.SSH.configFile"]
  [data.vscode.settings.forced]
    "editor.fontFamily" = "MesloLGS Nerd Font Mono"
    "terminal.integrated.fontFamily" = "MesloLGS Nerd Font Mono"
  [data.vscode.settings.defaults]
    "files.eol" = "\n"
    "editor.rulers" = [80, 120]
    "[python]" = { "editor.tabSize" = 4, "editor.formatOnSave" = true }

[data.vscode_overrides]
  extra_extensions = ["hashicorp.terraform"]
  exclude_settings = ["editor.minimap.enabled"]
  [data.vscode_overrides.extra_settings]
    "editor.fontSize" = 15
    "editor.codeActionsOnSave" = { "source.fixAll.eslint" = "explicit" }

[[data.accounts]]
  name = "Full Account"
  email = "full@example.com"
  username = "full"
  provider = "github"
  key = "id_full"
  signingKey = "id_full_sign"
  agent_key_comments = ["full@example.com"]
  auth_fingerprint = "SHA256:aaaa"
  signing_fingerprint = "SHA256:bbbb"
  agent_signing_key_comment = "full@example.com-sign"
  organizations = ["full-org"]
  dirs = ["projects/full"]

[[data.accounts]]
  name = "Lower Signing"
  email = "lower@example.com"
  username = "lower"
  provider = "gitlab"
  key = "id_lower"
  signingkey = "id_lower_sign"
  auth_fingerprint = "SHA256:cccc"
  dirs = ["projects/lower"]

[[data.accounts]]
  name = "Minimal"
  email = "min@example.com"
  username = "min"
  provider = "github"
  key = ""
  dirs = []

[[data.ssh_hosts]]
  name = "full-host"
  hostname = "10.0.0.5"
  user = "me"
  port = 2222
  identity = "id_full"
  identity_fingerprint = "SHA256:dddd"
  proxy = "bastion"
  comment = "Every key"
  os = "linux"
  tmux = "main"

[[data.ssh_hosts]]
  name = "bare-host"
  hostname = "bare.example.com"
  tmux = true
EOF
render_cfg() { # $1 = config file, $2 = chezmoi os override
    CI=1 chezmoi execute-template --init --config "$1" --source "$repo_root" \
        --override-data "{\"chezmoi\":$2}" <"$repo_root/.chezmoi.toml.tmpl"
}
for os_json in '{"os":"windows"}' '{"os":"linux","kernel":{"osrelease":"6.8.0-generic"}}'; do
    render_cfg "$tmp/fixture.toml" "$os_json" >"$tmp/rendered.toml" || fail "the config template did not render ($os_json)"
    out="$(python3 "$tmp/check.py" "$tmp/rendered.toml")"
    [ -z "$out" ] || fail "rendered chezmoi.toml ($os_json): $out"
    # alignment must not change a value: the data the fixture carries comes back unchanged
    python3 - "$tmp/fixture.toml" "$tmp/rendered.toml" <<'PYEOF' || fail "rendering changed the data ($os_json)"
import sys, tomllib
a = tomllib.load(open(sys.argv[1], "rb"))["data"]
b = tomllib.load(open(sys.argv[2], "rb"))["data"]
diff = [k for k in ("accounts", "ssh_hosts", "vscode", "vscode_overrides") if a.get(k) != b.get(k)]
if diff:
    for k in diff:
        print("  %s:\n    fixture  %r\n    rendered %r" % (k, a.get(k), b.get(k)))
    sys.exit(1)
PYEOF
done
# the fingerprint lines are aligned with the rest of their block (the report that started this)
grep -Eq '^  signing_fingerprint       = "SHA256:bbbb"$' "$tmp/rendered.toml" ||
    fail "account fingerprints must share the account's \"=\" column (got: $(grep -m1 'signing_fingerprint' "$tmp/rendered.toml"))"
grep -Eq '^  identity_fingerprint = "SHA256:dddd"$' "$tmp/rendered.toml" ||
    fail "identity_fingerprint must share the host's \"=\" column"
grep -Eq '^  name                 = "full-host"$' "$tmp/rendered.toml" ||
    fail "a host with identity_fingerprint must pad its other keys to that column"
pass

# --- 3. toml-align, executed --------------------------------------------------------
# (the fixture spells out the defaults the template fills in - provider, key - so the
# data comparison above only sees what alignment could have changed)
sample="$(printf '[t]\n  a = 1\n  long_key = "x = y"\n# c = 3\n  b=2\n  bb  = [1, 2]\n\n[u]\n  only = true')"
# a Go raw string (backquotes) carries the sample's quotes and newlines as they are
got="$(chezmoi execute-template --config "$tmp/fixture.toml" --source "$repo_root" "{{ includeTemplate \"toml-align\" \`$sample\` }}")"
want="$(printf '[t]\n  a        = 1\n  long_key = "x = y"\n# c = 3\n  b  = 2\n  bb = [1, 2]\n\n[u]\n  only = true')"
[ "$got" = "$want" ] || fail "toml-align: got
$got
want
$want"
pass

finish
