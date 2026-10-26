#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the fakes are called by the sourced function
set -euo pipefail

# The Fly.io CLI (flyctl) is a core tool on every OS:
#   - the catalog carries brew's formula and winget's portable package (machine-wide, see
#     tests/winget_machine_scope_contract.sh), and no apt name: Linux/WSL has none;
#   - the rendered installers install it: brew/winget from the catalog, Linux through
#     install_flyctl, only when core is on;
#   - install_flyctl is EXECUTED against a fake curl serving a fake install script: it passes
#     --non-interactive with ~/.fly/bin on the script's PATH (so the script never offers to edit
#     ~/.zshrc), skips a flyctl that is already installed, and judges success by the binary - a
#     failed download (curl | sh exits 0) warns and the run continues;
#   - dot_zshrc puts ~/.fly/bin on PATH.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

catalog="$repo_root/.chezmoidata/packages.yaml"
sh_t="$repo_root/run_onchange_install_packages.sh.tmpl"
fx="$(mktemp -d)"
trap 'rm -rf "$fx"' EXIT

# --- catalog ---------------------------------------------------------------------------------
record() { awk -v id="$1" '$0 ~ "^    - id: "id"$" {f=1; next} f && /^    - id: / {exit} f' "$catalog"; }
rec="$(record flyctl)"
printf '%s\n' "$rec" | grep -Fqx '      group: core' || fail "catalog: flyctl must be in core"
printf '%s\n' "$rec" | grep -Fqx '      brew: flyctl' || fail "catalog: flyctl needs its brew formula"
printf '%s\n' "$rec" | grep -Fqx '      winget: Fly-io.flyctl' || fail "catalog: flyctl needs its winget package"
if printf '%s\n' "$rec" | grep -q '^      apt:'; then fail "catalog: flyctl has no apt package - install_flyctl installs it"; fi
pass

# --- rendered installers ---------------------------------------------------------------------
if command -v chezmoi >/dev/null 2>&1; then
    in_apt() { awk '/^install_apt\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$1" | grep -Eq '^ +install_flyctl$'; }
    render_to "$fx/linux.sh" sh '{"core":true}'
    in_apt "$fx/linux.sh" || fail "linux render (core on): install_apt must call install_flyctl"
    render_to "$fx/linux-off.sh" sh '{"core":false}'
    if in_apt "$fx/linux-off.sh"; then fail "linux render (core off): install_flyctl must not run"; fi
    render_to "$fx/darwin.sh" darwin '{"core":true}'
    grep -Eq '^ *brew install .*\bflyctl\b' "$fx/darwin.sh" || fail "macOS render: flyctl must come from brew"
    render_to "$fx/win.ps1" ps1 '{"core":true}'
    grep -Fq '$wingetPackages += "Fly-io.flyctl|--scope machine|"' "$fx/win.ps1" || fail "windows render: flyctl is not in the winget list, machine-wide"
    pass
else
    printf 'note: chezmoi not installed - render checks skipped\n'
fi

# --- install_flyctl, executed ----------------------------------------------------------------
extract_fn() { awk -v n="$1" 'index($0, n "() {") == 1 {f=1} f{print} f && /^}$/{exit}' "$sh_t"; }
extract_fn install_flyctl >"$fx/fn.sh"
grep -q '^install_flyctl() {' "$fx/fn.sh" || fail "install_flyctl() not found in the installer template"
mkdir -p "$fx/bin" "$fx/home"
# The fake vendor script records its arguments and PATH, then installs like the real one.
cat >"$fx/install.sh" <<EOF
printf '%s\n' "\$*" >"$fx/script.args"
printf '%s\n' "\$PATH" >"$fx/script.path"
mkdir -p "\$HOME/.fly/bin" && printf '#!/bin/sh\n' >"\$HOME/.fly/bin/flyctl" && chmod +x "\$HOME/.fly/bin/flyctl"
EOF
cat >"$fx/bin/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$fx/curl.log"
[ -f "$fx/curl.fail" ] && exit 22
cat "$fx/install.sh"
EOF
chmod +x "$fx/bin/curl"
run_install() { # [extra PATH dir]; installs into $fx/home
    trap - EXIT   # called inside $( ): the parent's cleanup must not run when that subshell ends
    : >"$fx/curl.log"; rm -f "$fx/script.args" "$fx/script.path"
    (
        HOME="$fx/home"
        PATH="${1:+$1:}$fx/bin:$PATH"
        info() { echo "INFO: $*"; }; warn() { echo "WARN: $*"; }
        net_timeout() { shift; "$@"; }
        # shellcheck disable=SC1091
        . "$fx/fn.sh"
        install_flyctl
    )
}

out="$(run_install)" || fail "install_flyctl must not fail the run (output: $out)"
grep -Fq 'https://fly.io/install.sh' "$fx/curl.log" || fail "install_flyctl must fetch https://fly.io/install.sh"
[ -x "$fx/home/.fly/bin/flyctl" ] || fail "install_flyctl must leave ~/.fly/bin/flyctl (output: $out)"
grep -Fqx -- '--non-interactive' "$fx/script.args" 2>/dev/null || fail "the install script must run with --non-interactive (got: $(cat "$fx/script.args" 2>/dev/null))"
case "$(cat "$fx/script.path" 2>/dev/null)" in
    "$fx/home/.fly/bin:"*) ;;
    *) fail "the install script must see ~/.fly/bin first on PATH, so it never offers to edit ~/.zshrc" ;;
esac
printf '%s' "$out" | grep -q 'INFO: flyctl installed' || fail "a successful install must say so (got: $out)"
pass

out="$(run_install)"
[ ! -s "$fx/curl.log" ] || fail "a flyctl already in ~/.fly/bin must not be downloaded again"
rm -rf "$fx/home/.fly"
mkdir -p "$fx/brew"; printf '#!/bin/sh\n' >"$fx/brew/flyctl"; chmod +x "$fx/brew/flyctl"
out="$(run_install "$fx/brew")"
[ ! -s "$fx/curl.log" ] || fail "a flyctl already on PATH must not be downloaded again"
pass

touch "$fx/curl.fail"
out="$(run_install)" || fail "a failed download must not fail the run (output: $out)"
[ ! -e "$fx/home/.fly/bin/flyctl" ] || fail "a failed download must install nothing"
printf '%s' "$out" | grep -q 'WARN: flyctl install failed' || fail "a failed download must warn, even though curl | sh exits 0 (got: $out)"
pass

# --- shell PATH ------------------------------------------------------------------------------
require "$repo_root/dot_zshrc" '[[ -d "$HOME/.fly/bin" ]] && path=("$HOME/.fly/bin" "${path[@]}")'

finish
