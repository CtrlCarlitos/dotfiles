#!/usr/bin/env bash
set -euo pipefail

# The VS Code settings tiers used to exist twice: a PowerShell [ordered]@{} and
# a Python dict, ~75 duplicated values in two syntaxes. Every change was two
# edits in two languages, and they drifted. Then they rendered from
# .chezmoidata.yaml `vscode.settings`. Now they live in each machine's
# chezmoi.toml [data.vscode.settings]: `chezmoi init` (which `dot up` runs)
# seeds them from .chezmoitemplates/vscode-settings.toml when absent and
# otherwise writes back what the machine has. This pins:
#   1. the seed holds every tier, and .chezmoidata.yaml holds NONE (chezmoi
#      deep-merges it with the config, so a key deleted there would come back);
#   2. the config template seeds, preserves an edit and a deleted tier, and is
#      idempotent (executed against scratch configs);
#   3. both installer twins read the tiers through the guarded $vsCfg, no
#      literal copies, defaults_windows only in the .ps1 twin;
#   4. the rendered twins: values intact (files.eol), and a config WITHOUT the
#      settings renders, skipping the step with a note instead of failing (the
#      first `chezmoi update --apply` of `dot up` runs before its `chezmoi init`).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
sh_t="$repo_root/run_onchange_install_packages.sh.tmpl"
ps_t="$repo_root/run_onchange_install_packages.ps1.tmpl"
seed="$repo_root/.chezmoitemplates/vscode-settings.toml"
data="$repo_root/.chezmoidata.yaml"

. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. The seed holds every tier; .chezmoidata.yaml none of them.
for key in forced defaults defaults_windows terminal_colors; do
    grep -Fqx -- "[$key]" "$seed" || fail "vscode-settings.toml: missing tier [$key]"
done
for key in junk unset; do
    grep -Eq "^$key +=  *\[" "$seed" || fail "vscode-settings.toml: missing list tier $key"
done
if grep -Eq '^  settings:' "$data"; then
    fail ".chezmoidata.yaml: vscode.settings is back - the settings live in chezmoi.toml (deep merge would resurrect deleted keys)"
fi
pass

# 2. The config template, executed: seed, preserve, idempotent.
if command -v chezmoi >/dev/null 2>&1; then
    cfg="$tmp/chezmoi.toml"
    # `chezmoi init` itself prompts on the terminal (it hung here); CI=1 turns the prompts off,
    # and execute-template --init renders the same config template.
    init() {
        CI=1 chezmoi execute-template --init --config "$cfg" --source "$repo_root"             <"$repo_root/.chezmoi.toml.tmpl" >"$tmp/next.toml" && mv "$tmp/next.toml" "$cfg"
    }
    q() { chezmoi execute-template --source "$repo_root" --config "$cfg" "$1"; }
    : >"$cfg"
    init || fail "chezmoi init failed on an empty config"
    [ "$(q '{{ index .vscode.settings.forced "editor.fontFamily" }}')" = 'MesloLGS Nerd Font Mono' ] ||
        fail "init must seed [data.vscode.settings] when the config has none"
    [ "$(q '{{ len .vscode.settings.defaults }}|{{ len .vscode.settings.junk }}|{{ len .vscode.extensions }}')" = "$(
        chezmoi execute-template --source "$repo_root" --config "$cfg" '{{ $s := includeTemplate "vscode-settings.toml" . | fromToml }}{{ len $s.defaults }}|{{ len $s.junk }}|{{ len .vscode.extensions }}')" ] ||
        fail "the seeded settings must match the seed, and the extensions must still come from .chezmoidata.yaml"
    cp "$cfg" "$tmp/first.toml"
    init
    cmp -s "$tmp/first.toml" "$cfg" || fail "a second init must not change the config"
    # an edit and a deleted tier survive
    awk '/^    \[data\.vscode\.settings\.defaults_windows\]$/{skip=1; next} skip && /^      /{next} {skip=0; print}' "$cfg" |
        sed -E 's/("terminal\.integrated\.fontSize" +=) 16$/\1 14/' >"$tmp/edited.toml"
    cp "$tmp/edited.toml" "$cfg"
    init
    [ "$(q '{{ index .vscode.settings.defaults "terminal.integrated.fontSize" }}|{{ hasKey .vscode.settings "defaults_windows" }}')" = '14|false' ] ||
        fail "init must keep the machine's edit and a deleted tier (got: $(q '{{ index .vscode.settings.defaults "terminal.integrated.fontSize" }}|{{ hasKey .vscode.settings "defaults_windows" }}'))"
    pass
else
    printf 'note: chezmoi not installed - config template checks skipped\n'
fi

# 3. Both twins read the tiers through $vsCfg rather than carrying their own copy.
for tier in forced defaults junk unset terminal_colors; do
    grep -Fq -- "(get \$vsCfg \"$tier\"" "$sh_t" || fail "run_onchange_install_packages.sh.tmpl: no longer renders tier $tier"
    grep -Fq -- "(get \$vsCfg \"$tier\"" "$ps_t" || fail "run_onchange_install_packages.ps1.tmpl: no longer renders tier $tier"
done
if grep -Fq -- '.vscode.settings.' "$sh_t" "$ps_t"; then
    fail "an installer reads .vscode.settings.<tier> unguarded - a tier deleted from chezmoi.toml would break the render"
fi
# defaults_windows is for the Windows twin ONLY: enableWin32InputMode is a ConPTY workaround.
grep -Fq -- '(get $vsCfg "defaults_windows"' "$ps_t" || fail "ps1 twin no longer renders the Windows-only tier"
if grep -Fq -- '"defaults_windows"' "$sh_t"; then fail "sh twin renders defaults_windows - that tier is Windows-only"; fi
# No tier value may reappear as a literal in either twin.
for f in "$sh_t" "$ps_t"; do
    for lit in '#1E1E2E' 'afterDelay' '__pycache__' 'remote.SSH.configFile'; do
        if grep -Fq -- "$lit" "$f"; then fail "$(basename -- "$f"): '$lit' is hardcoded again - it comes from chezmoi.toml"; fi
    done
done
# The font is also Windows Terminal's default face: it must come from the same key.
# shellcheck disable=SC2016  # literal template text
grep -Fq -- '$desiredFont = {{ get (get $vsCfg "forced" | default dict) "editor.fontFamily"' "$ps_t" ||
    fail 'ps1 twin: $desiredFont no longer derives from the forced font'
pass

# 4. The rendered twins. Every grep reads a here-string, never `printf | grep -q`
#    (under pipefail an early -q match makes the pipeline report SIGPIPE).
if command -v chezmoi >/dev/null 2>&1; then
    on='{"core":true,"fonts":true,"dev_desktop":true}'
    render_to "$tmp/sh.out" sh "$on"
    render_to "$tmp/ps.out" ps1 "$on"
    sh_out="$(cat "$tmp/sh.out")"; ps_out="$(cat "$tmp/ps.out")"
    # files.eol must stay a one-character newline: JSON "\n", PowerShell backtick-n
    grep -qF '"files.eol":"\n"' <<<"$sh_out" || fail 'sh twin: files.eol is not an escaped newline'
    grep -qF "'files.eol' = \"$(printf '\140')n\"" <<<"$ps_out" || fail 'ps1 twin: files.eol did not render as backtick-n'
    if grep -qF '"terminal.integrated.enableWin32InputMode"' <<<"$sh_out"; then fail 'sh twin: rendered the Windows-only tier'; fi
    grep -qF "'terminal.integrated.enableWin32InputMode'" <<<"$ps_out" || fail 'ps1 twin: missing the Windows-only tier'
    grep -qF '$desiredFont = "MesloLGS Nerd Font Mono"' <<<"$ps_out" || fail 'ps1 twin: Windows Terminal font did not render'
    grep -qF 'local vs_cfg_missing="false"' <<<"$sh_out" || fail 'sh twin: a seeded config must not skip the settings step'
    grep -qF '$vsCfgMissing = $false' <<<"$ps_out" || fail 'ps1 twin: a seeded config must not skip the settings step'
    grep -qF '"editor.fontFamily": "MesloLGS Nerd Font Mono"' <<<"$sh_out" || grep -qF '"editor.fontFamily":"MesloLGS Nerd Font Mono"' <<<"$sh_out" ||
        fail 'sh twin: the forced font did not render from the seeded config'

    pass

    # a config from before the move: renders, skips the step with a note
    RENDER_NO_VSCODE_SETTINGS=1 render_to "$tmp/sh-old.out" sh "$on"
    RENDER_NO_VSCODE_SETTINGS=1 render_to "$tmp/ps-old.out" ps1 "$on"
    grep -qF 'local vs_cfg_missing="true"' "$tmp/sh-old.out" || fail 'sh twin: a config without the settings must skip the step with a note'
    grep -qF '$vsCfgMissing = $true' "$tmp/ps-old.out" || fail 'ps1 twin: a config without the settings must skip the step'
    grep -qF '$desiredFont = "MesloLGS Nerd Font Mono"' "$tmp/ps-old.out" || fail 'ps1 twin: the Windows Terminal font must fall back to Meslo'
    grep -qF 'FORCED = json.loads(r"""{}""")' "$tmp/sh-old.out" || fail 'sh twin: a missing tier must render as empty'
    pass
    # the PowerShell renders must parse
    if command -v pwsh >/dev/null 2>&1; then
        # shellcheck disable=SC2016  # PowerShell source
        printf '%s
' 'param([string]$Path)' '$e = $null'             '$null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$e)'             '$e | ForEach-Object { $_.Message }' >"$tmp/parse.ps1"
        wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
        for f in ps.out ps-old.out; do
            perr="$(pwsh -NoProfile -File "$(wp "$tmp/parse.ps1")" -Path "$(wp "$tmp/$f")" 2>&1)"
            [ -z "$perr" ] || fail "ps1 twin ($f) does not parse: $perr"
        done
        pass
    fi
    bash -n "$tmp/sh.out" || fail 'sh twin does not parse'
    bash -n "$tmp/sh-old.out" || fail 'sh twin (no settings) does not parse'
fi

finish
