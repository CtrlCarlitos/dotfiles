#Requires -Version 5.1
<#
dot ssh - pick one of your SSH hosts and connect (`dot ssh`, PowerShell twin of dot-ssh.sh).

The hosts are chezmoi.toml's [[data.ssh_hosts]] - the same entries that become ~/.ssh/config
Host blocks and the "SSH: <name>" Windows Terminal profiles.

  dot ssh            pick with fzf (a numbered menu without fzf), then connect
  dot ssh <name>     connect to that host directly
  dot ssh --list     print the hosts
  dot ssh --here     connect in this window even inside Windows Terminal

DOT_SSH_PICKER=menu uses the numbered menu even where fzf is installed.
Inside Windows Terminal the host opens in a new tab through its own profile (tab color, tmux),
when that profile exists; otherwise - or with --here - ssh runs right here. A host with tmux
set joins its remote session: `ssh -t <name> "tmux new-session -A -s <session>"`.
#>
# No param() block: every argument (--list, a host name) arrives in $args. A declared
# parameter would swallow the first positional one - `dot ssh --list` once bound "--list" to
# it and opened the picker instead. The tests point at a fake Windows Terminal settings file
# through DOT_SSH_WT_SETTINGS.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Write-DotSshUsage {
    Write-Host 'dot ssh - connect to one of your [[data.ssh_hosts]]'
    Write-Host '  dot ssh            pick a host (fzf, or a numbered menu), then connect'
    Write-Host '  dot ssh <name>     connect to that host'
    Write-Host '  dot ssh --list     list the hosts'
    Write-Host '  dot ssh --here     connect in this window even inside Windows Terminal'
}

$name = ''
$list = $false
$inHere = $false
foreach ($a in $args) {
    switch -Regex ($a) {
        '^(-h|--help|-Help)$' { Write-DotSshUsage; return }
        '^(-l|--list|-List)$' { $list = $true }
        '^(--here|-Here)$' { $inHere = $true }
        default { $name = [string]$a }
    }
}

$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$raw = @(& chezmoi execute-template --file (Join-Path $here 'lib\ssh-hosts.tsv.tmpl') 2>$null)
$ErrorActionPreference = $previous
$hosts = @(foreach ($line in $raw) {
    if ("$line".Trim() -eq '') { continue }
    $f = "$line" -split "`t"
    [pscustomobject]@{ Name = $f[0]; Target = $(if ($f.Count -gt 1) { $f[1] } else { '' }); Os = $(if ($f.Count -gt 2) { $f[2] } else { '' }); Session = $(if ($f.Count -gt 3) { $f[3] } else { '' }); Comment = $(if ($f.Count -gt 4) { $f[4] } else { '' }) }
})
if ($hosts.Count -eq 0) {
    Write-Host 'dot ssh: no SSH hosts yet - add a [[data.ssh_hosts]] block to ~/.config/chezmoi/chezmoi.toml (docs/secrets.md), then dot up' -ForegroundColor Yellow
    exit 1
}

# One aligned display line per host (columns as wide as their longest value); the first word
# is always the host name.
$wn = ($hosts | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
$wt = ($hosts | ForEach-Object { $_.Target.Length } | Measure-Object -Maximum).Maximum
$wo = ($hosts | ForEach-Object { $_.Os.Length } | Measure-Object -Maximum).Maximum
$lines = @(foreach ($h in $hosts) {
    $extra = $h.Comment
    if ($h.Session) { $extra = "tmux:$($h.Session)" + $(if ($extra) { "  $extra" } else { '' }) }
    ("{0,-$wn}  {1,-$wt}  {2,-$wo}  {3}" -f $h.Name, $h.Target, $h.Os, $extra).TrimEnd()
})
if ($list) { $lines | ForEach-Object { Write-Host $_ }; return }

if (-not $name) {
    $choice = ''
    if ($env:DOT_SSH_PICKER -ne 'menu' -and (Get-Command fzf -ErrorAction SilentlyContinue)) {
        $ErrorActionPreference = 'Continue'
        $choice = ($lines | & fzf --prompt='ssh> ' --height=40% --reverse --no-multi --header='enter: connect  esc: cancel' | Out-String).Trim()
        $ErrorActionPreference = $previous
    } else {
        for ($i = 0; $i -lt $lines.Count; $i++) { Write-Host ('{0,2}) {1}' -f ($i + 1), $lines[$i]) }
        $pick = (Read-Host 'Host number (empty to cancel)').Trim()
        if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $lines.Count) { $choice = $lines[[int]$pick - 1] }
        elseif ($pick) { Write-Host "dot ssh: no host number $pick" -ForegroundColor Red; exit 2 }
    }
    if (-not $choice) { exit 130 }
    $name = ($choice -split '\s+', 2)[0]
}

$entry = $hosts | Where-Object { $_.Name -eq $name } | Select-Object -First 1
if (-not $entry) {
    Write-Host "dot ssh: no host named '$name' (dot ssh --list shows them)" -ForegroundColor Red
    exit 2
}

# Inside Windows Terminal: a new tab through the host's own profile, when it has one.
if (-not $inHere -and $env:WT_SESSION -and (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    $WtSettings = if ($env:DOT_SSH_WT_SETTINGS) { $env:DOT_SSH_WT_SETTINGS } else { Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json' }
    $profileName = "SSH: $($entry.Name)"
    $profilePattern = '"name"\s*:\s*"' + [regex]::Escape($profileName) + '"'
    if ((Test-Path -LiteralPath $WtSettings) -and ((Get-Content -LiteralPath $WtSettings -Raw) -match $profilePattern)) {
        & wt.exe -w 0 nt --profile $profileName
        return
    }
}

if ($entry.Session) {
    & ssh -t $entry.Name "tmux new-session -A -s $($entry.Session)"
} else {
    & ssh $entry.Name
}
exit $LASTEXITCODE
