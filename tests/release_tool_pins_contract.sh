#!/usr/bin/env bash
set -euo pipefail

# lychee and vale: pinned GitHub release tarballs on Linux (no apt package), and the pins must be
# real pins - in .chezmoidata.yaml, moved by scripts/update-versions.sh (the weekly auto-update
# PR), followed by `dot upgrade`. Until 2026-10-11 the two versions and four sha256s were written
# inline in the installer template: nothing bumped them, `dot upgrade` only reported "lychee,
# vale" as outside package managers, and the closing note's "bump its pin" named a pin no
# script knew about.
#   - .chezmoidata.yaml carries <tool>_version, <tool>_sha256_x86_64, <tool>_sha256_aarch64
#   - the installer renders those (no literal version in the template); its rendered URLs are
#     the ones release_tool_url (scripts/lib/agent-skills.sh) builds - one URL shape, two users
#   - release_tool_pin_sync <name> <pin> <sha> <sudo> (`dot upgrade`): absent -> nothing; not the
#     dotfiles' install (outside /usr/local/bin) -> left alone; at the pin -> "is current", with
#     the newest upstream release named when the pin lags; otherwise download, verify, reinstall
#   - update-versions.sh: release_tool_pin_write rewrites the three keys together; a section
#     resolves both tools' newest release and both arch digests
#   - the closing note no longer lists the pinned or GitHub-upgraded tools
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
lib="$repo_root/scripts/lib/agent-skills.sh"
tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"
data="$repo_root/.chezmoidata.yaml"
upd="$repo_root/scripts/update-versions.sh"
du="$repo_root/scripts/dotupgrade.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- 1. the pins, in the data file --------------------------------------------------------------
for t in lychee vale; do
    v="$(sed -n "s/^  ${t}_version: \"\\([^\"]*\\)\"\$/\\1/p" "$data")"
    case "$v" in [0-9]*.[0-9]*.[0-9]*) pass ;; *) fail ".chezmoidata.yaml: ${t}_version='$v' is not an exact X.Y.Z pin" ;; esac
    for a in x86_64 aarch64; do
        s="$(sed -n "s/^  ${t}_sha256_${a}: \"\\([^\"]*\\)\"\$/\\1/p" "$data")"
        if [ "${#s}" = 64 ] && [ -z "${s//[0-9a-f]/}" ]; then pass; else fail ".chezmoidata.yaml: ${t}_sha256_${a}='$s' is not 64 lowercase hex characters"; fi
    done
done
lychee_pin="$(sed -n 's/^  lychee_version: "\([^"]*\)"$/\1/p' "$data")"
vale_pin="$(sed -n 's/^  vale_version: "\([^"]*\)"$/\1/p' "$data")"

# --- 2. the template renders them; no literal version is left in the source --------------------
require "$tmpl" '{{ .versions.lychee_version }}'
require "$tmpl" '{{ .versions.vale_version }}'
for key in lychee_sha256_x86_64 lychee_sha256_aarch64 vale_sha256_x86_64 vale_sha256_aarch64; do
    require "$tmpl" "{{ .versions.$key }}"
done
if grep -Eq 'lychee-v[0-9]+\.[0-9]+\.[0-9]+/' "$tmpl"; then fail "template: a literal lychee version is still written in a URL"; else pass; fi
if grep -Eq 'vale/releases/download/v[0-9]+\.' "$tmpl"; then fail "template: a literal vale version is still written in a URL"; else pass; fi

# --- 3. one URL shape: the rendered installer's URLs are release_tool_url's ---------------------
if command -v chezmoi >/dev/null 2>&1; then
    render_to "$tmp/linux.sh" sh '{"modern_cli": true}'
    for t in lychee vale; do
        for a in x86_64 aarch64; do
            pin="$lychee_pin"; [ "$t" = vale ] && pin="$vale_pin"
            want="$(bash -c '. "$1"; release_tool_url "$2" "$3" "$4"' _ "$lib" "$t" "$pin" "$a" 2>/dev/null || true)"
            [ -n "$want" ] || fail "release_tool_url $t $pin $a printed nothing"
            grep -Fq "install_release_binary $t \"$want\"" "$tmp/linux.sh" || fail "render: the $t $a URL must be release_tool_url's ($want)"
        done
    done
fi

# --- 4. release_tool_pin_sync, executed --------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/sys" "$tmp/dest" "$tmp/elsewhere" "$tmp/pkg/lychee-x86_64-unknown-linux-gnu"
for c in bash sh grep sed sort head tail cat tr wc mktemp rm mkdir awk cut timeout env printf dirname basename readlink tar gzip install cp mv chmod touch sha256sum shasum; do
    if p="$(command -v "$c" 2>/dev/null)"; then link_tool "$p" "$tmp/sys/$c" || true; fi
done
printf '#!/bin/sh\necho "lychee 9.9.9"\n' >"$tmp/pkg/lychee-x86_64-unknown-linux-gnu/lychee"; chmod +x "$tmp/pkg/lychee-x86_64-unknown-linux-gnu/lychee"
tar -czf "$tmp/release.tar.gz" -C "$tmp/pkg" lychee-x86_64-unknown-linux-gnu
good="$( (sha256sum "$tmp/release.tar.gz" 2>/dev/null || shasum -a 256 "$tmp/release.tar.gz") | cut -c1-64)"
cat >"$tmp/bin/curl" <<'EOF2'
#!/bin/sh
printf '%s\n' "$*" >>"${CURL_LOG:?}"
out=''; prev=''
for a in "$@"; do case "$prev" in -o|--output) out="$a" ;; esac; prev="$a"; done
[ -n "$out" ] || exit 2
cp "${FIXTURE_TGZ:?}" "$out"
EOF2
printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >>"${TOOL_LOG:?}"\nexec "$@"\n' >"$tmp/bin/sudo"
printf '#!/bin/sh\necho x86_64\n' >"$tmp/bin/uname"
chmod +x "$tmp/bin"/*
set_lychee() { # <dir> <version>: a lychee reporting <version> in <dir> (dest = ours, elsewhere = not ours)
    rm -f "$tmp/dest/lychee" "$tmp/elsewhere/lychee"
    printf '#!/bin/sh\necho "lychee %s"\n' "$2" >"$1/lychee"; chmod +x "$1/lychee"
}
run() { # <pin> <sha> : prints output and rc; github_latest_tag answers $FAKE_LATEST
    : >"$tmp/curl.log"; : >"$tmp/tool.log"
    PATH="$tmp/dest:$tmp/elsewhere:$tmp/bin:$tmp/sys" CURL_LOG="$tmp/curl.log" TOOL_LOG="$tmp/tool.log" FIXTURE_TGZ="$tmp/release.tar.gz" GITHUB_TOOL_BIN="$tmp/dest" \
        bash -c 'set -euo pipefail; . "$1"; shift; github_latest_tag() { printf "%s\n" "${FAKE_LATEST:-}"; }; rc=0; release_tool_pin_sync lychee "$@" sudo || rc=$?; echo "rc=$rc"' _ "$lib" "$@" 2>&1
}
run_collect() { # same, inside tool_current_collect ... tool_current_flush (dot upgrade's span)
    : >"$tmp/curl.log"; : >"$tmp/tool.log"
    PATH="$tmp/dest:$tmp/elsewhere:$tmp/bin:$tmp/sys" CURL_LOG="$tmp/curl.log" TOOL_LOG="$tmp/tool.log" FIXTURE_TGZ="$tmp/release.tar.gz" GITHUB_TOOL_BIN="$tmp/dest" \
        bash -c 'set -euo pipefail; . "$1"; shift; github_latest_tag() { printf "%s\n" "${FAKE_LATEST:-}"; }; rc=0; tool_current_collect; release_tool_pin_sync lychee "$@" sudo || rc=$?; tool_current_flush "GitHub-release tools"; echo "rc=$rc"' _ "$lib" "$@" 2>&1
}
# a. at the pin: current, nothing downloaded; a newer upstream is named with the remedy
set_lychee "$tmp/dest" 0.24.2
got="$(FAKE_LATEST=0.24.2 run 0.24.2 "$good")"
case "$got" in *'lychee is current (0.24.2)'*rc=0*) pass ;; *) fail "at pin: must say current (got: $got)" ;; esac
[ ! -s "$tmp/curl.log" ] || fail "at pin: must not download"
got="$(FAKE_LATEST=0.25.0 run 0.24.2 "$good")"
case "$got" in *'lychee is current (0.24.2'*'0.25.0'*'auto-update'*rc=0*) pass ;; *) fail "pin behind upstream: must name the newer release and the auto-update remedy (got: $got)" ;; esac
# inside dot upgrade's collect span a plainly current tool joins the folded line; a pin behind
# upstream has news and keeps its own line
got="$(FAKE_LATEST=0.24.2 run_collect 0.24.2 "$good")"
case "$got" in *'lychee is current'*) fail "collect span: the per-tool line must be held (got: $got)" ;; *'   GitHub-release tools current: lychee 0.24.2'*rc=0*) pass ;; *) fail "collect span: one folded line expected (got: $got)" ;; esac
got="$(FAKE_LATEST=0.25.0 run_collect 0.24.2 "$good")"
case "$got" in *'lychee is current (0.24.2; upstream 0.25.0'*) pass ;; *) fail "collect span, pin behind upstream: must keep its own line (got: $got)" ;; esac
case "$got" in *'GitHub-release tools current'*) fail "collect span, pin behind upstream: must not also be folded (got: $got)" ;; *) pass ;; esac
# b. behind the pin, ours: downloaded, verified, reinstalled through sudo, reported
set_lychee "$tmp/dest" 0.23.0
got="$(FAKE_LATEST=0.24.2 run 0.24.2 "$good")"
case "$got" in *'lychee reinstalled at pin 0.24.2 (was 0.23.0)'*rc=0*) pass ;; *) fail "behind pin: must reinstall and report (got: $got)" ;; esac
grep -Fq 'lychee-v0.24.2/lychee-x86_64-unknown-linux-gnu.tar.gz' "$tmp/curl.log" || fail "behind pin: must download the pinned asset (curl saw: $(/bin/cat "$tmp/curl.log"))"
grep -Eq -- '--speed-limit [0-9]+' "$tmp/curl.log" || fail "behind pin: the download must be stall-guarded"
grep -Eq '^sudo install ' "$tmp/tool.log" || fail "behind pin: installed through sudo (log: $(/bin/cat "$tmp/tool.log"))"
[ "$("$tmp/dest/lychee")" = "lychee 9.9.9" ] || fail "behind pin: the binary must be replaced by the archive's"
# c. checksum mismatch: nothing installed, said
set_lychee "$tmp/dest" 0.23.0
got="$(FAKE_LATEST=0.24.2 run 0.24.2 0000000000000000000000000000000000000000000000000000000000000000)"
case "$got" in *'lychee'*'checksum'*rc=0*) pass ;; *) fail "mismatch: must warn and return 0 (got: $got)" ;; esac
[ "$("$tmp/dest/lychee")" = "lychee 0.23.0" ] || fail "mismatch: the installed binary must be untouched"
# d. not the dotfiles' install (elsewhere on PATH): left alone
set_lychee "$tmp/elsewhere" 0.23.0
got="$(FAKE_LATEST=0.24.2 run 0.24.2 "$good")"
case "$got" in *'lychee'*'left alone'*rc=0*) pass ;; *) fail "not ours: must be left alone (got: $got)" ;; esac
[ ! -s "$tmp/curl.log" ] || fail "not ours: must not download"
# e. absent: silent
rm -f "$tmp/dest/lychee" "$tmp/elsewhere/lychee"
got="$(FAKE_LATEST=0.24.2 run 0.24.2 "$good")"
[ "$got" = "rc=0" ] || fail "absent: must be silent (got: $got)"

# --- 5. update-versions.sh: the writer, executed on a fixture; the resolver section exists ------
# shellcheck source=scripts/update-versions.sh
. "$upd"
cp "$data" "$tmp/data.yaml"
release_tool_pin_write lychee 0.99.0 "$(printf 'a%.0s' $(seq 64))" "$(printf 'b%.0s' $(seq 64))" "$tmp/data.yaml"
grep -Fxq '  lychee_version: "0.99.0"' "$tmp/data.yaml" || fail "release_tool_pin_write: version not rewritten"
grep -Fxq "  lychee_sha256_x86_64: \"$(printf 'a%.0s' $(seq 64))\"" "$tmp/data.yaml" || fail "release_tool_pin_write: x86_64 digest not rewritten"
grep -Fxq "  lychee_sha256_aarch64: \"$(printf 'b%.0s' $(seq 64))\"" "$tmp/data.yaml" || fail "release_tool_pin_write: aarch64 digest not rewritten"
grep -Fxq "  vale_version: \"$vale_pin\"" "$tmp/data.yaml" || fail "release_tool_pin_write: must leave the other tool's pins alone"
grep -Fq 'maestro_version: ' "$tmp/data.yaml" || fail "release_tool_pin_write: must leave unrelated pins alone"
require "$upd" 'github_latest_tag "$(release_tool_repo'
require "$upd" 'release_tool_pin_write'
for t in lychee vale; do grep -Eq "for (rt|tool|t) in .*\\b$t\\b" "$upd" || fail "update-versions.sh: $t must be among the tools whose pins are resolved"; done
require "$repo_root/.github/workflows/auto-update.yml" 'lychee'

# --- 6. dot upgrade follows the pins and the note stops naming managed tools -------------------
require "$du" 'release_tool_pins_upgrade sudo'
awk '/github_tool_sync "\$n" sudo upgrade/ {a=NR} /release_tool_pins_upgrade sudo/ {b=NR} END {exit !(a && b && a<b)}' "$du" ||
    fail "dotupgrade.sh: the pin follow-up must run after the GitHub tool upgrades, in the apt branch"
forbid "$du" 'for n in delta dust procs lychee vale; do'
forbid "$du" 'unmanaged_tool_repo'

finish
