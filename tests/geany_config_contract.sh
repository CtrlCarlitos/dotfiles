#!/usr/bin/env bash
set -euo pipefail

# Geany contract: two Windows-only modify-templates that MERGE one key each,
# through the shared .chezmoitemplates/ini-force fragment.
#   - AppData/Local/gtk-3.0/settings.ini  -> [Settings] gtk-application-prefer-dark-theme = true
#   - AppData/Roaming/geany/geany.conf    -> [geany] color_scheme=dark.conf
# Geany rewrites geany.conf on every exit, and other GTK tools write settings.ini,
# so neither file may be owned (docs/invariants.md #3). Pinned behaviors: an
# empty file gets the section, a wrong value is replaced (once), every other
# key/section/comment survives, CRLF stays CRLF, the merge is idempotent, and
# neither file is managed where Geany is absent.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
gtk="$repo_root/AppData/Local/gtk-3.0/modify_settings.ini"
geany="$repo_root/AppData/Roaming/geany/modify_geany.conf"

. "$repo_root/tests/lib.sh"

for f in "$gtk" "$geany"; do
    [ -f "$f" ] || { fail "missing modify template: $f"; exit 1; }
    grep -Fq 'chezmoi:modify-template' "$f" || fail "$f must be a modify-template (merge), not an owned file"
    grep -Fq 'includeTemplate "ini-force"' "$f" || fail "$f must use includeTemplate (docs/invariants.md #4)"
done

command -v chezmoi >/dev/null || skip "chezmoi not installed"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/chezmoi.toml"
merge() {  # $1 = template; stdin = current file
    chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" --with-stdin --file "$1"
}

# --- GTK settings.ini
[ "$(: | merge "$gtk")" = $'[Settings]\ngtk-application-prefer-dark-theme = true' ] ||
    fail "gtk: empty file must become exactly the [Settings] block"
out=$(printf '[Settings]\ngtk-theme-name = Adwaita\ngtk-application-prefer-dark-theme = false\n' | merge "$gtk")
[ "$out" = $'[Settings]\ngtk-application-prefer-dark-theme = true\ngtk-theme-name = Adwaita' ] ||
    fail "gtk: wrong value must be replaced once, other keys kept (got: $out)"
out=$(printf '[Other]\na = 1\n' | merge "$gtk")
[ "$out" = $'[Other]\na = 1\n\n[Settings]\ngtk-application-prefer-dark-theme = true' ] ||
    fail "gtk: missing section must be appended (got: $out)"
[ "$(printf '%s\n' "$out" | merge "$gtk")" = "$out" ] || fail "gtk: merge is not idempotent"

# --- geany.conf
cur=$'[geany]\nbeep_on_errors=true\ncolor_scheme=\neditor_font=Consolas 10\n\n[tools]\nterminal_cmd=cmd\ncolor_scheme=keep-me\n'
out=$(printf '%s' "$cur" | merge "$geany")
printf '%s\n' "$out" | grep -Fxq 'color_scheme=dark.conf' || fail "geany: color_scheme not forced"
[ "$(printf '%s\n' "$out" | grep -c '^color_scheme=')" = 2 ] || fail "geany: expected one forced key plus the [tools] one"
printf '%s\n' "$out" | grep -Fxq 'color_scheme=keep-me' || fail "geany: a same-named key in another section was touched"
printf '%s\n' "$out" | grep -Fxq 'editor_font=Consolas 10' || fail "geany: unrelated key dropped"
printf '%s\n' "$out" | grep -Fxq 'terminal_cmd=cmd' || fail "geany: other section dropped"
[ "$(printf '%s\n' "$out" | merge "$geany")" = "$out" ] || fail "geany: merge is not idempotent"
crlf=$(printf '[geany]\r\ncolor_scheme=x\r\n' | merge "$geany" | od -An -c | tr -d ' \n')
case "$crlf" in *'\r\n'*) ;; *) fail "geany: CRLF file lost its line ending" ;; esac
case "$crlf" in *'\r\n') ;; *) fail "geany: output must end in CRLF" ;; esac

# --- .chezmoiignore: only where Geany exists. The fixture home has no Geany.
render_managed() {  # $1 = os, $2 = home
    # ProgramFiles is pinned: this host may really have Geany installed.
    ProgramFiles="$tmp/pf" chezmoi managed --config "$tmp/chezmoi.toml" --source "$repo_root" \
        --override-data "{\"chezmoi\":{\"os\":\"$1\",\"kernel\":{\"osrelease\":\"\"},\"homeDir\":\"$2\"}}"
}
render_managed windows /nonexistent >"$tmp/none.txt"
# Git Bash re-injects the real ProgramFiles, so the negative case is only
# provable on a host that has no Geany of its own (CI).
if [ ! -d "${PROGRAMFILES:-/nonexistent}/Geany" ]; then
    grep -Eq 'gtk-3.0|geany' "$tmp/none.txt" && fail "windows without Geany: Geany files must not be managed"
fi
mkdir -p "$tmp/home/AppData/Roaming/geany"
render_managed windows "$tmp/home" >"$tmp/with.txt"
grep -Fq 'AppData/Roaming/geany/geany.conf' "$tmp/with.txt" || fail "windows with a Geany config dir: geany.conf must be managed"
grep -Fq 'AppData/Local/gtk-3.0/settings.ini' "$tmp/with.txt" || fail "windows with a Geany config dir: settings.ini must be managed"
render_managed linux "$tmp/home" | grep -Eq 'gtk-3.0|geany' && fail "linux: Geany files must never be managed"

finish
