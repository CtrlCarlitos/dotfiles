#!/usr/bin/env bash
# shellcheck disable=SC2016  # PowerShell and template text are literal
set -euo pipefail

# `dot ssh`: pick one of chezmoi.toml's [[data.ssh_hosts]] and connect - the cross-terminal
# equivalent of the "SSH: <name>" Windows Terminal profiles (Ghostty has no profiles).
# This pins, EXECUTED against fake chezmoi / fzf / ssh / wt:
#   1. scripts/lib/ssh-hosts.tsv.tmpl renders one TAB line per host (target, os, tmux, comment)
#      and maps tmux the way the Windows Terminal profiles do (true -> "main", a string -> it);
#   2. bash and PowerShell twins: a name connects directly; the picker (fzf, or a numbered menu
#      without it) connects to the chosen host; tmux joins the remote session; an unknown name
#      exits 2; no hosts exits 1; --list prints aligned rows;
#   3. PowerShell inside Windows Terminal opens the host's own profile in a new tab when the
#      profile exists; otherwise, outside Windows Terminal, or with --here, ssh runs here;
#   4. all three `dot` dispatchers route `dot ssh`.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# --- 4. dispatchers ------------------------------------------------------------------------
grep -Fq 'ssh)     shift; bash "$repo_scripts/dot-ssh.sh" "$@" ;;' "$repo_root/dot_aliases.zsh" || fail "zsh dot: no ssh arm"
for f in Documents/PowerShell/Microsoft.PowerShell_profile.ps1 Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1; do
    grep -Fq "'ssh' { & (Join-Path \$repoScripts 'dot-ssh.ps1') @rest }" "$repo_root/$f" || fail "$f: no dot ssh arm"
done
pass

# --- 1. the host template ------------------------------------------------------------------------
TAB="$(printf '\t')"
if command -v chezmoi >/dev/null 2>&1; then
    hosts_json='{"ssh_hosts":[{"name":"mac-mini","hostname":"10.0.0.5","user":"me","port":2222,"os":"mac","tmux":true,"comment":"build box"},{"name":"prod","hostname":"prod.example.com","tmux":"work"},{"name":"bare","hostname":"bare.example.com","tmux":false}]}'
    rendered="$(render --override-data "$hosts_json" --file "$repo_root/scripts/lib/ssh-hosts.tsv.tmpl" | sed '/^$/d')"
    want="mac-mini${TAB}me@10.0.0.5:2222${TAB}mac${TAB}main${TAB}build box
prod${TAB}prod.example.com${TAB}${TAB}work${TAB}
bare${TAB}bare.example.com${TAB}${TAB}${TAB}"
    [ "$rendered" = "$want" ] || fail "ssh-hosts.tsv.tmpl rendered:
$(printf '%s' "$rendered" | cat -A)
want:
$(printf '%s' "$want" | cat -A)"
    none="$(render --override-data '{}' --file "$repo_root/scripts/lib/ssh-hosts.tsv.tmpl" | sed '/^$/d')"
    [ -z "$none" ] || fail "no ssh_hosts must render nothing (got: $none)"
    pass
else
    printf 'note: chezmoi not installed - template check skipped\n'
fi

# --- 2. bash twin ---------------------------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/scripts/lib"
cp "$repo_root/scripts/dot-ssh.sh" "$tmp/scripts/"
: >"$tmp/scripts/lib/ssh-hosts.tsv.tmpl"
printf 'mac-mini\tme@10.0.0.5:2222\tmac\tmain\tbuild box\nprod\tprod.example.com\t\twork\t\nbare\tbare.example.com\t\t\t\n' >"$tmp/hosts.tsv"
cat >"$tmp/bin/chezmoi" <<EOF
#!/usr/bin/env bash
[ "\${NO_HOSTS:-0}" = 1 ] || cat "$tmp/hosts.tsv"
EOF
# fzf: echo the input line that starts with \$FZF_PICK (empty = cancelled)
cat >"$tmp/bin/fzf" <<'EOF'
#!/usr/bin/env bash
[ -n "${FZF_PICK:-}" ] || exit 130
grep "^$FZF_PICK " || exit 1
EOF
cat >"$tmp/bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s|' "\$@" >"$tmp/ssh.log"
EOF
chmod +x "$tmp/bin/"*
run_sh() { # args... -> "exit|ssh-args"
    : >"$tmp/ssh.log"
    local code=0
    PATH="$tmp/bin:$PATH" bash "$tmp/scripts/dot-ssh.sh" "$@" >"$tmp/out" 2>&1 </dev/null || code=$?
    printf '%s|%s' "$code" "$(cat "$tmp/ssh.log")"
}
r="$(run_sh mac-mini)"; [ "$r" = "0|-t|mac-mini|tmux new-session -A -s main|" ] || fail "sh: a tmux=true host joins session main (got $r)"
r="$(run_sh bare)"; [ "$r" = "0|bare|" ] || fail "sh: a host without tmux is a plain ssh (got $r)"
r="$(FZF_PICK=prod run_sh)"; [ "$r" = "0|-t|prod|tmux new-session -A -s work|" ] || fail "sh: the picked host connects, with its named session (got $r)"
r="$(run_sh)"; [ "$r" = "130|" ] || fail "sh: a cancelled picker connects nowhere (got $r)"
r="$(run_sh nope)"; [ "$r" = "2|" ] || fail "sh: an unknown host exits 2 (got $r)"
r="$(NO_HOSTS=1 run_sh)"; [ "$r" = "1|" ] || fail "sh: no hosts exits 1 (got $r)"
run_sh --list >/dev/null
[ "$(sed -n 1p "$tmp/out")" = "mac-mini  me@10.0.0.5:2222  mac  tmux:main  build box" ] || fail "sh: --list rows must align (got: $(sed -n 1p "$tmp/out"))"
# the numbered menu (no fzf, or DOT_SSH_PICKER=menu - this host may have a real fzf on PATH)
: >"$tmp/ssh.log"
code=0; printf '3\n' | DOT_SSH_PICKER=menu PATH="$tmp/bin:$PATH" bash "$tmp/scripts/dot-ssh.sh" >"$tmp/out" 2>&1 || code=$?
[ "$code|$(cat "$tmp/ssh.log")" = "0|bare|" ] || fail "sh: without fzf, menu entry 3 connects to the third host (got $code|$(cat "$tmp/ssh.log"))"
pass

# --- 2+3. PowerShell twin ----------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    printf '{ "profiles": { "list": [ { "name": "SSH: mac-mini", "commandline": "ssh.exe mac-mini" } ] } }' >"$tmp/wt.json"
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Script, [string]$Hosts, [string]$Wt)
# $global:, not $script:: inside these fakes $script: is dot-ssh.ps1's scope (the script running)
$global:hostsFile = $Hosts
$global:noHosts = $false
$global:pick = ''
$global:calls = @()
function chezmoi { if ($global:noHosts) { return }; Get-Content -LiteralPath $global:hostsFile }
function fzf { $in = @($input); if ($global:pick) { $in | Where-Object { $_ -like "$($global:pick) *" } | Select-Object -First 1 } }
function ssh { $global:calls += 'ssh ' + ($args -join '|'); $global:LASTEXITCODE = 0 }
function wt.exe { $global:calls += 'wt ' + ($args -join '|'); $global:LASTEXITCODE = 0 }
function Case($label, [string[]]$a, [string]$wtSession = '', [string]$pick = '', [bool]$noHosts = $false) {
    $global:calls = @(); $global:pick = $pick; $global:noHosts = $noHosts
    $env:WT_SESSION = $wtSession
    $env:DOT_SSH_WT_SETTINGS = $Wt
    $global:LASTEXITCODE = 0
    $null = & $Script @a 6>$null
    Write-Output ("$label=" + $global:LASTEXITCODE + '|' + ($global:calls -join ';'))
}
Case 'direct-tmux' @('mac-mini')
Case 'direct-plain' @('bare')
Case 'picked' @() '' 'prod'
Case 'cancelled' @() '' ''
Case 'unknown' @('nope')
Case 'none' @() '' '' $true
Case 'wt-profile' @('mac-mini') 'wt-1'
Case 'wt-no-profile' @('prod') 'wt-1'
Case 'wt-here' @('mac-mini', '--here') 'wt-1'
$env:WT_SESSION = ''
# the numbered menu
$env:DOT_SSH_PICKER = 'menu'
function Read-Host { '3' }
Case 'menu' @()
$env:DOT_SSH_PICKER = ''
$list =(& $Script --list 6>&1 | Out-String) -split "`r?`n" | Where-Object { $_ }
Write-Output ('list-first=' + $list[0])
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Script "$(winpath "$repo_root/scripts/dot-ssh.ps1")" -Hosts "$(winpath "$tmp/hosts.tsv")" -Wt "$(winpath "$tmp/wt.json")" </dev/null 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "ps1: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-500))"; }
    expect 'direct-tmux=0|ssh -t|mac-mini|tmux new-session -A -s main'
    expect 'direct-plain=0|ssh bare'
    expect 'picked=0|ssh -t|prod|tmux new-session -A -s work'
    expect 'cancelled=130|'
    expect 'unknown=2|'
    expect 'none=1|'
    expect 'wt-profile=0|wt -w|0|nt|--profile|SSH: mac-mini'
    expect 'wt-no-profile=0|ssh -t|prod|tmux new-session -A -s work'
    expect 'wt-here=0|ssh -t|mac-mini|tmux new-session -A -s main'
    expect 'menu=0|ssh bare'
    expect 'list-first=mac-mini  me@10.0.0.5:2222  mac  tmux:main  build box'
    pass
else
    printf 'note: pwsh not installed - PowerShell twin skipped\n'
fi

finish
