#!/usr/bin/env bash
set -euo pipefail

# zsh startup contract, executed: dot_zshrc is SOURCED in a real zsh against a
# fixture HOME, and the resulting `path`/`fpath` arrays are asserted - the
# thing the exact-line greps this replaces could only approximate. A reordered
# or typo'd path line now fails because the directory is genuinely missing
# from (or misplaced in) the array, and message/indentation edits no longer
# fail anything.
#
# Homebrew, two ways (both must hold on their own hosts):
#   - fixture brew: where dot_zshrc's absolute brew candidates do not exist
#     (WSL, most dev machines), a stub brew at $HOME/.linuxbrew/bin provides
#     the shellenv and the starship/zoxide/direnv stubs live ONLY in that bin
#     dir - so "Homebrew must initialize before the modern tools" is proven
#     behaviourally: the tool inits run iff brew's PATH contribution ran
#     first.
#   - real Homebrew: GitHub runners ship /home/linuxbrew/.linuxbrew, which
#     dot_zshrc prefers over anything under $HOME. There the real brew
#     initializes; the tool stubs ride the base PATH, the brew bin dir is
#     discovered dynamically, and the ordering invariant keeps its
#     source-order greps (one grep per invariant).
# Kept everywhere: `zsh -n`, shellcheck, and the two `typeset -U` greps
# (dedup is a parse-time property; one grep per invariant).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
zshrc="$repo_root/dot_zshrc"

. "$repo_root/tests/lib.sh"

[[ -f "$zshrc" ]] || fail "missing $zshrc"
if command -v zsh >/dev/null 2>&1; then
    zsh -n "$zshrc" || fail "dot_zshrc has invalid zsh syntax"
else
    printf '%s\n' 'SKIP: zsh syntax + execution checks require zsh'
fi
shellcheck -s bash -e SC1091 "$zshrc" || fail "dot_zshrc must be shellcheck-clean"

# The dedup declarations must survive: they are what makes repeated
# eval "$(brew shellenv)" / re-sourcing idempotent.
require "$zshrc" 'typeset -U path'
require "$zshrc" 'typeset -U fpath'

if ! command -v zsh >/dev/null 2>&1; then
    finish
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
bin="$tmp/bin" # base stub dir; also the only inherited PATH entry
mkdir -p "$bin"

# Discover brew exactly as dot_zshrc does (absolute candidates, in order).
real_brew=""
for candidate in /opt/homebrew /home/linuxbrew/.linuxbrew; do
    if [ -x "$candidate/bin/brew" ]; then
        real_brew="$candidate"
        break
    fi
done

make_fixture_home() {
    mkdir -p "$home/.local/bin" "$home/bin" "$home/.npm-global/bin" \
        "$home/.opencode/bin" "$home/go/bin" "$home/.dotnet/tools" \
        "$home/.mix/escripts" "$home/.composer/vendor/bin" \
        "$home/.zfunc" "$home/.linuxbrew/bin" "$tmp/xdg/composer/vendor/bin"
}
make_fixture_home

if [ -z "$real_brew" ]; then
    brew_bin="$home/.linuxbrew/bin"
else
    brew_bin="$real_brew/bin"
fi

if [ -z "$real_brew" ]; then
    # brew shellenv stub: prepends brew's bin dir; self-sufficient (own coreutils
    # PATH and bin dir) so it works under any child environment.
    cat >"$home/.linuxbrew/bin/brew" <<EOF
#!/bin/sh
PATH="/usr/bin:/bin:\$PATH"
mkdir -p "\$HOME/.linuxbrew/bin"
printf 'export PATH="%s:\$PATH"\n' "\$HOME/.linuxbrew/bin"
EOF
    chmod +x "$home/.linuxbrew/bin/brew"
    # starship/zoxide/direnv live ONLY in brew's bin dir: they are discoverable
    # (and their init invokable) iff brew initialized first - the ordering
    # invariant, executed.
    for tool in starship:'starship-init' zoxide:'zoxide-init' direnv:'direnv-hook'; do
        printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "${STUB_LOG:?}"\nexit 0\n' "${tool#*:}" \
            >"$home/.linuxbrew/bin/${tool%%:*}"
        chmod +x "$home/.linuxbrew/bin/${tool%%:*}"
    done
else
    # Real brew owns the prefix: the tool stubs ride the base PATH so the
    # modern-tool blocks still execute; the ordering invariant keeps its
    # source-order greps below.
    for tool in starship:'starship-init' zoxide:'zoxide-init' direnv:'direnv-hook'; do
        printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "${STUB_LOG:?}"\nexit 0\n' "${tool#*:}" >"$bin/${tool%%:*}"
        chmod +x "$bin/${tool%%:*}"
    done
fi
stub() { # $1 = name, $2 = log marker; lands on the base PATH
    printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "${STUB_LOG:?}"\nexit 0\n' "$2" >"$bin/$1"
    chmod +x "$bin/$1"
}
stub nvim 'nvim-found'

# Source dot_zshrc and dump the resulting arrays. zsh -f? No: the file itself
# must run under plain options; -f would disable its global rc reading only.
ZSH_BIN="$(command -v zsh)"
zsh_driver="$tmp/driver.zsh"
cat >"$zsh_driver" <<EOF
cd "\$HOME"
source "$zshrc"
printf '%s\n' "\${path[@]}"
printf 'FPATH-ENTRY:%s\n' "\${fpath[@]}"
printf 'EDITOR:%s\n' "\$EDITOR"
EOF
if [ -n "$real_brew" ]; then
    # coreutils stay reachable: the real brew shellenv needs them (readlink).
    child_path="$bin:/usr/bin:/bin"
else
    child_path="$bin"
fi
source_zshrc() { # $1+ = extra env assignments as KEY=VALUE words
    env -i HOME="$home" PATH="$child_path" STUB_LOG="$tmp/stub.log" XDG_CONFIG_HOME="$tmp/xdg" "$@" \
        "$ZSH_BIN" "$zsh_driver"
}

# --- 1. Full happy path: every ecosystem dir lands on path, in precedence order
: >"$tmp/stub.log"
out="$(source_zshrc)"

have_in_path() {
    if grep -Fqx -- "$1" <<<"$out"; then pass; else fail "path missing $1 (got: $(tr '\n' ' ' <<<"$out"))"; fi
}
for dir in \
    "$home/.local/bin" "$home/bin" "$home/.npm-global/bin" "$home/.opencode/bin" \
    "$home/go/bin" "$home/.dotnet" "$home/.dotnet/tools" "$home/.mix/escripts" \
    "$home/.composer/vendor/bin" "$tmp/xdg/composer/vendor/bin" \
    "$brew_bin"; do
    have_in_path "$dir"
done
if grep -Fqx 'FPATH-ENTRY:'"$home/.zfunc" <<<"$out"; then pass; else fail "fpath missing $home/.zfunc"; fi

idx_in_path() { # $1 = dir; prints 1-based line index within the path dump
    grep -Fxn -- "$1" <<<"$out" | head -1 | cut -d: -f1
}
npm_pos="$(idx_in_path "$home/.npm-global/bin")"
brew_pos="$(idx_in_path "$brew_bin")"
opencode_pos="$(idx_in_path "$home/.opencode/bin")"
if [ -n "$npm_pos" ] && [ -n "$brew_pos" ] && [ "$npm_pos" -lt "$brew_pos" ]; then pass; else
    fail "npm-global binaries must retain precedence over Homebrew"
fi
if [ -n "$opencode_pos" ] && [ -n "$brew_pos" ] && [ "$opencode_pos" -lt "$brew_pos" ]; then pass; else
    fail "OpenCode binaries must retain precedence over Homebrew"
fi

if [ -z "$real_brew" ]; then
    # Homebrew initialized before the modern tools: their inits only log when
    # brew's PATH contribution (the ONLY place the stubs exist) preceded them.
    for init in starship-init zoxide-init direnv-hook; do
        if grep -Fqx "$init" "$tmp/stub.log"; then pass; else fail "$init never ran - brew init no longer precedes modern-tool setup"; fi
    done
else
    # Real brew: the ordering invariant keeps its source-order proof (one grep
    # per invariant) - the behavioral variant ran where the fixture owns brew.
    # (Which starship/zoxide/direnv binary answers is the host's business here;
    # the blocks executing is what the path-array assertions prove.)
    brew_line="$(grep -nF 'if [[ -x "/opt/homebrew/bin/brew" ]]' "$zshrc" | cut -d: -f1)"
    for marker in '# Starship (Prompt)' '# Zoxide (Smart CD)' '# Direnv (Env vars per directory)'; do
        m_line="$(grep -nF "$marker" "$zshrc" | cut -d: -f1)"
        if [ -n "$brew_line" ] && [ -n "$m_line" ] && [ "$brew_line" -lt "$m_line" ]; then pass; else
            fail "$marker must initialize after the Homebrew block"
        fi
    done
fi

# EDITOR: nvim is on PATH -> chosen.
if grep -Fqx 'EDITOR:nvim' <<<"$out"; then pass; else fail "EDITOR must be nvim when nvim is available"; fi

# --- 2. Fallbacks and overrides ------------------------------------------------
# The nvim->vim fallback is only deterministic where this test controls the
# whole PATH (fixture-brew hosts); on real-brew hosts the restricted PATH's
# tail may carry the runner's own nvim, so there the assertion would not be.
if [ -z "$real_brew" ]; then
    rm -f "$bin/nvim"
    out="$(source_zshrc)"
    if grep -Fqx 'EDITOR:vim' <<<"$out"; then pass; else fail "EDITOR must fall back to vim without nvim"; fi
fi

mkdir -p "$home/custom-go/bin" "$tmp/composer/vendor/bin"
out="$(source_zshrc GOPATH="$home/custom-go:$home/other-go" COMPOSER_HOME="$tmp/composer")"
have_in_path "$home/custom-go/bin"
have_in_path "$tmp/composer/vendor/bin"
have_in_path "$home/.composer/vendor/bin"

finish
