#!/usr/bin/env bash
set -euo pipefail

# install_fonts' 7z extraction is the one noisy, ungated step left in an
# otherwise quiet+warn-and-continue installer (WSL `dot up`, 2026-10-09):
#
#   - It printed 7-Zip's own banner and "Scanning the drive.../Extracting
#     archive.../Everything is Ok" straight to the log, breaking the promise
#     quiet_apt_enable states ("apt install/update output is quiet ... errors
#     are always shown" - scripts/lib/agent-skills.sh).
#   - Unlike the `wget` download three lines above it, a failing extraction
#     had no `if ! ...; then warn; continue; fi` guard, so under `set -e` a
#     corrupt/partial zip would have killed the whole `dot up`/`dot upgrade`
#     instead of just skipping that font - breaking the warn-and-continue
#     contract tests/installer_hygiene_contract.sh pins for every other risky
#     step in this installer (#114).
#
# Proven for real: install_fonts is extracted from the rendered installer and
# run against stub wget/curl/7z binaries, no network or real downloads.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

template="$repo_root/run_onchange_install_packages.sh.tmpl"
[ -f "$template" ] || { fail "missing $template"; finish; }
command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed (needed to render the installer)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

: > "$tmp/chezmoi.toml"
groups="{$(grep -oE 'promptBoolOnce \. "packages\.[a-z_]+"' "$repo_root/.chezmoi.toml.tmpl" | sed -E 's/.*"packages\.([a-z_]+)"/"\1":true/' | paste -sd, -)}"
rendered="$tmp/installer.sh"
chezmoi execute-template --config "$tmp/chezmoi.toml" --source "$repo_root" \
    --override-data "{\"chezmoi\":{\"os\":\"linux\",\"kernel\":{\"osrelease\":\"6.8-generic\"}},\"packages\":$groups}" \
    --file "$template" > "$rendered"

harness="$tmp/harness.sh"
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
        ". $repo_root/scripts/lib/agent-skills.sh" 'SUDO=""'
    awk '/^install_fonts\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$rendered"
    printf '%s\n' 'install_fonts'
} > "$harness"
grep -q 'nf_zip_names=' "$harness" || { fail "install_fonts was not found in the rendered installer"; finish; }

# wget: the real call is `-O "$WORK/$zip_name.zip" <url>` - just create the target.
cat > "$tmp/bin/wget" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == -O ]]; then
        j=$((i + 1))
        : > "${!j}"
    fi
done
EOF

# curl: one call, for the Nerd Fonts release tag lookup.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"tag_name": "v3.4.0"}\n'
EOF
chmod +x "$tmp/bin/wget" "$tmp/bin/curl"

run_fonts() { # $1 = HOME dir, $2 = WORK dir
    HOME="$1" WORK="$2" PATH="$tmp/bin:$PATH" bash "$harness"
}

# --- 1. A failing extraction must warn-and-continue, not abort the run -----
cat > "$tmp/bin/7z" <<'EOF'
#!/usr/bin/env bash
echo "boom: corrupt archive" >&2
exit 2
EOF
chmod +x "$tmp/bin/7z"

home1="$tmp/home1"; work1="$tmp/work1"
mkdir -p "$home1" "$work1"
out1="$tmp/out1.log"
if run_fonts "$home1" "$work1" >"$out1" 2>&1; then
    pass
else
    fail "install_fonts must not abort the run when 7z extraction fails (warn-and-continue, #114): $(cat "$out1")"
fi
grep -q 'Meslo Nerd Font extraction failed' "$out1" || fail "expected a warning naming the Meslo extraction failure: $(cat "$out1")"
pass
grep -q 'FiraCode Nerd Font extraction failed' "$out1" || fail "a failed Meslo extraction must not stop FiraCode from being attempted: $(cat "$out1")"
pass
[ ! -e "$work1/Meslo.zip" ] || fail "a failed extraction must not leave its zip behind"
pass
[ ! -e "$work1/FiraCode.zip" ] || fail "a failed extraction must not leave its zip behind"
pass

# --- 2. A successful extraction runs 7z quiet, same spirit as wget's -q ----
log2="$tmp/7z-calls.log"
cat > "$tmp/bin/7z" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$log2"
dir="" zip=""
for arg in "\$@"; do
    case "\$arg" in
        -o*) dir="\${arg#-o}" ;;
        *.zip) zip="\$(basename "\$arg")" ;;
    esac
done
case "\$zip" in
    Meslo.zip) marker=MesloLGMNerdFont-Regular.ttf ;;
    FiraCode.zip) marker=FiraCodeNerdFont-Regular.ttf ;;
    *) marker="" ;;
esac
[ -n "\$marker" ] && : > "\$dir/\$marker"
EOF
chmod +x "$tmp/bin/7z"

home2="$tmp/home2"; work2="$tmp/work2"
mkdir -p "$home2" "$work2"
out2="$tmp/out2.log"
run_fonts "$home2" "$work2" >"$out2" 2>&1 || fail "install_fonts failed on a clean extraction: $(cat "$out2")"
pass
grep -q 'Meslo Nerd Font installed' "$out2" || fail "Meslo was not reported installed: $(cat "$out2")"
pass
grep -q 'FiraCode Nerd Font installed' "$out2" || fail "FiraCode was not reported installed: $(cat "$out2")"
pass

[ -f "$log2" ] || fail "7z was never invoked"
pass
calls="$(cat "$log2" 2>/dev/null || true)"
[ "$(wc -l < "$log2")" -eq 2 ] || fail "expected exactly 2 7z invocations (Meslo, FiraCode), got: $calls"
pass
while IFS= read -r call; do
    [[ "$call" == *-bso0* ]] || fail "7z call missing the quiet-output flag -bso0 (would print its banner/progress): $call"
    pass
    [[ "$call" == *-bsp0* ]] || fail "7z call missing the quiet-progress flag -bsp0: $call"
    pass
done < "$log2"

finish
