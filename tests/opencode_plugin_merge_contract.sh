#!/usr/bin/env bash
set -euo pipefail

# The Windows installer adds the Superpowers plugin spec to opencode.json with
# Add-OpenCodePluginSpec (scripts/lib/ps-skills.ps1). On a fresh Windows VM
# (2026-10-23) Serena's registration had already written opencode.json with
# only an `mcp` key; the old inline merge read `$json.plugin`, which throws
# under the installer's Set-StrictMode -Version Latest, and the catch reported
# "Could not parse existing opencode.json" - the plugin never landed.
#
# The function is dot-sourced from the library and EXECUTED under StrictMode,
# on pwsh and, where it exists, Windows PowerShell 5.1 (the installer's host):
#   a. Serena's file (BOM'd, no plugin key): spec added, mcp kept, no BOM written;
#   b. a plugin list without the spec: appended, the user's entry kept;
#   c. the spec already present: not duplicated;
#   d. no file: created with the spec;
#   e. unparseable content: left byte-for-byte untouched, with a warning.
# The sh twin merges with jq (`.plugin // []`), which has no such failure mode.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v python3 >/dev/null 2>&1 || skip 'python3 not installed'
shells=()
command -v pwsh >/dev/null 2>&1 && shells+=(pwsh)
command -v powershell.exe >/dev/null 2>&1 && shells+=(powershell.exe)
[ "${#shells[@]}" -gt 0 ] || skip 'no PowerShell installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
q() { # $1 = json file, $2 = python expression over d -> compact JSON
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8-sig")); print(json.dumps(eval(sys.argv[2]), separators=(",", ":")))' "$1" "$2"
}

# shellcheck disable=SC2088  # the literal spec the installer writes; OpenCode expands it, not the shell
spec='~/.config/opencode/node_modules/superpowers'
cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Path, [string]$Spec)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib
Add-OpenCodePluginSpec -Path $Path -Spec $Spec
PSEOF

for sh in "${shells[@]}"; do
    # `|| true`: a harness that throws must reach the assertions below, not end the test silently.
    run() { "$sh" -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" -Path "$(winpath "$1")" -Spec "$spec" 2>&1 | tr -d '\r' || true; }

    # a. Serena's file: BOM, mcp only.
    cfg="$tmp/$sh-a.json"
    printf '\xef\xbb\xbf{"mcp":{"serena":{"type":"local","command":["serena","start-mcp-server"],"enabled":true}}}' >"$cfg"
    out="$(run "$cfg")"
    [ "$(q "$cfg" 'd.get("plugin")')" = "[\"$spec\"]" ] || fail "$sh: a: the spec must be added to a file without a plugin key (got $(q "$cfg" 'd.get("plugin")'); output: $out)"
    [ "$(q "$cfg" 'd["mcp"]["serena"]["command"]')" = '["serena","start-mcp-server"]' ] || fail "$sh: a: the mcp key must survive"
    [ "$(head -c 3 "$cfg" | od -An -tx1 | tr -d ' ')" != 'efbbbf' ] || fail "$sh: a: the merged file must be written without a BOM"
    case "$out" in *'Could not parse'*) fail "$sh: a: a valid file must not be reported unparseable: $out" ;; esac

    # b. a plugin list without the spec.
    cfg="$tmp/$sh-b.json"
    printf '{"plugin":["other"]}' >"$cfg"
    run "$cfg" >/dev/null
    [ "$(q "$cfg" 'd["plugin"]')" = "[\"other\",\"$spec\"]" ] || fail "$sh: b: the spec must be appended after the user's plugin (got $(q "$cfg" 'd["plugin"]'))"

    # c. already present.
    cfg="$tmp/$sh-c.json"
    printf '{"plugin":["%s"]}' "$spec" >"$cfg"
    run "$cfg" >/dev/null
    [ "$(q "$cfg" 'd["plugin"]')" = "[\"$spec\"]" ] || fail "$sh: c: the spec must not be duplicated (got $(q "$cfg" 'd["plugin"]'))"

    # d. no file.
    cfg="$tmp/$sh-d.json"
    run "$cfg" >/dev/null
    [ -f "$cfg" ] && [ "$(q "$cfg" 'd["plugin"]')" = "[\"$spec\"]" ] || fail "$sh: d: a missing file must be created with the spec"

    # e. unparseable.
    cfg="$tmp/$sh-e.json"
    printf '{ not json' >"$cfg"
    out="$(run "$cfg")"
    [ "$(cat "$cfg")" = '{ not json' ] || fail "$sh: e: an unparseable file must be left untouched"
    case "$out" in *'Could not parse existing opencode.json'*) pass ;; *) fail "$sh: e: an unparseable file must warn (got: $out)" ;; esac
done

finish
