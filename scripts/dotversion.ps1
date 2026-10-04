#Requires -Version 5.1
<#
dotversion.ps1 - which version of the dotfiles repo is this machine on?
The version is COMPUTED from git, never stored in a file, so it cannot drift
from the history: `git describe` over the CalVer release tags vYYYY.MM.DD[.N].
Prints one line and exits 0, or - when there is no git metadata to ask (a copy
of the repo without .git) - says so and exits 1.

  dotfiles v2026.10.04 (abc1234)                       exactly on a release
  dotfiles v2026.10.04 (+3 commits, abc1234)           past it
  dotfiles v2026.10.04 (+3 commits, abc1234, dirty)    tracked files edited
  dotfiles abc1234 (untagged)                          no release tag reachable
  dotfiles unknown (no git metadata in DIR)            exit 1

Untracked files do not count as dirty (a scratch file is not an edit of the
repo). Usage: .\dotversion.ps1   (or: dot version). `dot doctor` prints the
same line. Bash twin: dotversion.sh (invariant #10: change both).
#>
Set-StrictMode -Version Latest
# Scope-local on purpose: on Windows PowerShell 5.1 a native stderr line would
# throw under 'Stop', and git's "not a repository" is exactly such a line.
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot

$null = & git -C $root rev-parse --git-dir 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Output "dotfiles unknown (no git metadata in $root)"
    exit 1
}

$desc = & git -C $root describe --tags --long --always --abbrev=7 --match 'v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]*' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $desc) {
    Write-Output "dotfiles unknown (git cannot describe HEAD in $root)"
    exit 1
}
$desc = ([string]$desc).Trim()

$dirty = [bool](& git -C $root status --porcelain --untracked-files=no 2>$null)

if ($desc -match '^(v\d{4}\.\d{2}\.\d{2}[\d.]*)-(\d+)-g([0-9a-f]+)$') {
    $tag = $Matches[1]
    $ahead = [int]$Matches[2]
    $detail = ''
    if ($ahead -gt 0) {
        $plural = if ($ahead -eq 1) { '' } else { 's' }
        $detail = "+$ahead commit$plural, "
    }
    $detail += $Matches[3]
    if ($dirty) { $detail += ', dirty' }
    Write-Output "dotfiles $tag ($detail)"
} else {
    $detail = 'untagged'
    if ($dirty) { $detail += ', dirty' }
    Write-Output "dotfiles $desc ($detail)"
}
