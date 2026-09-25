#Requires -Version 7
<#
Behavioral tests for dot_local/bin/devprofile.ps1 - the PowerShell twin of
tests/devprofile_contract.sh. Scope is deliberately narrow (per #122):
  - Get-Accounts TOML parsing (the fallback loader, no chezmoi on the box)
  - Test-Identity dirs mapping (which account a repo's path belongs to)
Everything else (hook install, key generation) needs real git/ssh-keygen and
stays with the bash contract test. No real keys are generated; git is a
function stub, so nothing here touches the host's repos or config.

The functions are extracted from the script rather than dot-sourced: the
script runs its command dispatch at the top level, so loading it whole would
execute Show-Current against the host.
#>
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Devprofile = Join-Path $RepoRoot 'dot_local/bin/devprofile.ps1'
if (-not (Test-Path $Devprofile)) { Write-Error "missing $Devprofile"; exit 1 }

$Source = Get-Content -Raw -LiteralPath $Devprofile
$GetAccountsSrc = [regex]::Match($Source, '(?ms)^function Get-Accounts \{.*?^\}')
$TestIdentitySrc = [regex]::Match($Source, '(?ms)^function Test-Identity \{.*?^\}')
if (-not $GetAccountsSrc.Success) { Write-Error 'Get-Accounts not found in devprofile.ps1'; exit 1 }
if (-not $TestIdentitySrc.Success) { Write-Error 'Test-Identity not found in devprofile.ps1'; exit 1 }

# Same display helpers the script defines (the extracted functions call them).
function Write-Info    { param([string]$Message) Write-Host "▸ $Message" }
function Write-Success { param([string]$Message) Write-Host "✓ $Message" }
function Write-Warn    { param([string]$Message) Write-Host "! $Message" }
function Write-Err     { param([string]$Message) Write-Host "✗ $Message" }

$script:Failed = 0
function Fail([string]$m) {
    $script:Failed++
    Write-Host "FAIL: $m"
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("devprofile-identity-" + [guid]::NewGuid().ToString('N'))
try {
    $Home_ = Join-Path $Tmp 'home'
    $ConfigDir = Join-Path $Home_ '.config/chezmoi'
    New-Item -ItemType Directory -Force -Path $ConfigDir, (Join-Path $Home_ 'projects/bobcorp'), (Join-Path $Home_ 'projects/alice') | Out-Null

    # The accounts fixture - the same shape tests/devprofile_contract.sh uses:
    # bob carries a custom signingKey; a trailing account has no username (must
    # be skipped) and one has empty dirs (must parse to an empty list).
    $ChezmoiConfig = Join-Path $ConfigDir 'chezmoi.toml'
    @'
[[data.accounts]]
  name = "Alice Personal"
  email = "alice@personal.com"
  username = "alice"
  provider = "github"
  key = "id_alice"
  dirs = ["projects/alice", ".dotfiles"]

[[data.accounts]]
  name = "Bob Work"
  email = "bob@work.com"
  username = "bob"
  key = "id_bob"
  signingKey = "id_bob_commit"
  dirs = ["projects/bobcorp"]

[[data.accounts]]
  name = "Empty Dirs"
  email = "empty@dirs.example"
  username = "emptydirs"
  dirs = []

[[data.accounts]]
  name = "No Username"
  email = "nobody@nowhere.example"
'@ | Set-Content -Path $ChezmoiConfig -Encoding utf8

    # chezmoi is shadowed with a failing function so Get-Accounts takes the
    # TOML fallback path - the same determinism rule the bash contract test
    # applies (a host with a real chezmoi must not answer with its own data).
    function chezmoi { $global:LASTEXITCODE = 1 }

    # git stub: reads come from script state, rev-parse from $script:GitRepoRoot.
    $script:GitRepoRoot = $null
    $script:GitName = $null
    $script:GitEmail = $null
    $script:GitSigningKey = $null
    function git {
        $call = ($args | ForEach-Object { "$_" }) -join ' '
        switch -Regex ($call) {
            '^rev-parse --git-dir' { $global:LASTEXITCODE = 0; return '.git' }
            '^rev-parse --show-toplevel' { $global:LASTEXITCODE = 0; return $script:GitRepoRoot }
            '^config user\.name$' { return $script:GitName }
            '^config user\.email$' { return $script:GitEmail }
            '^config user\.signingkey$' { return $script:GitSigningKey }
            default { $global:LASTEXITCODE = 0; return $null }
        }
    }

    #=========================================================================
    # [1] Get-Accounts parses the fixture TOML.
    #=========================================================================
    # Dot-source the extracted definition into the harness scope ONCE: each
    # [scriptblock]::Create invocation has its own scope, and Test-Identity
    # below calls Get-Accounts - it must resolve at run time (it does, via
    # PowerShell's dynamic scoping, from this scope).
    . ([scriptblock]::Create($GetAccountsSrc.Value))
    $accounts = Get-Accounts
    if ($accounts.Count -eq 3) { } else { Fail "[1] expected 3 accounts (no-username one skipped), got $($accounts.Count)" }
    $alice = $accounts | Where-Object { $_.username -eq 'alice' }
    $bob = $accounts | Where-Object { $_.username -eq 'bob' }
    if ($alice -and $alice.email -eq 'alice@personal.com' -and $alice.key -eq 'id_alice' -and $null -eq $alice.signingKey) { } else { Fail '[1] alice parsed wrong' }
    if ($alice.dirs.Count -eq 2 -and $alice.dirs[0] -eq 'projects/alice' -and $alice.dirs[1] -eq '.dotfiles') { } else { Fail "[1] alice dirs wrong: $($alice.dirs -join ',')" }
    if ($bob -and $bob.signingKey -eq 'id_bob_commit' -and $bob.key -eq 'id_bob') { } else { Fail '[1] bob signingKey/key parsed wrong' }
    $emptyDirs = $accounts | Where-Object { $_.username -eq 'emptydirs' }
    if ($emptyDirs -and $emptyDirs.dirs.Count -eq 0) { } else { Fail '[1] empty dirs must parse to an empty list' }
    Write-Host '  ok: Get-Accounts TOML parsing'

    #=========================================================================
    # [2] Test-Identity: repo under bob's dirs, signing as bob -> all clear.
    #=========================================================================
    $env:USERPROFILE = $Home_
    $script:GitRepoRoot = (Join-Path $Home_ 'projects/bobcorp')
    $script:GitName = 'Bob Work'
    $script:GitEmail = 'bob@work.com'
    $script:GitSigningKey = $null
    $out = (& ([scriptblock]::Create($TestIdentitySrc.Value + "`nTest-Identity")) 6>&1 | Out-String)
    if ($out -match 'Matches bob \(dirs mapping\)') { } else { Fail "[2] dirs match not reported: $out" }
    if ($out -match 'All checks passed') { } else { Fail "[2] expected a clean verify: $out" }
    Write-Host '  ok: matching dirs mapping passes'

    #=========================================================================
    # [3] Test-Identity: repo under alice's dirs but signing as bob -> flagged.
    #=========================================================================
    $script:GitRepoRoot = (Join-Path $Home_ 'projects/alice')
    $out = (& ([scriptblock]::Create($TestIdentitySrc.Value + "`nTest-Identity")) 6>&1 | Out-String)
    if ($out -match 'Expected alice \(alice@personal\.com\)') { } else { Fail "[3] mismatch not reported: $out" }
    if ($out -match 'issue\(s\) found') { } else { Fail "[3] issue count not reported: $out" }
    Write-Host '  ok: wrong-account repo flagged'

    #=========================================================================
    # [4] Test-Identity: inline signing key accepted.
    #=========================================================================
    $script:GitRepoRoot = (Join-Path $Home_ 'projects/bobcorp')
    $script:GitSigningKey = 'ssh-ed25519 AAAAFAKEKEY'
    $out = (& ([scriptblock]::Create($TestIdentitySrc.Value + "`nTest-Identity")) 6>&1 | Out-String)
    if ($out -match 'Inline public key') { } else { Fail "[4] inline key not accepted: $out" }
    Write-Host '  ok: inline signing key accepted'

    if ($script:Failed -gt 0) {
        Write-Host "FAIL: devprofile_identity.ps1 ($($script:Failed) failures)"
        exit 1
    }
    Write-Host 'PASS: devprofile_identity.ps1 (4 scenarios)'
    exit 0
} finally {
    Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
