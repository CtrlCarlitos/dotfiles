# Execute both profile dispatchers and the doctor's LF pass on isolated fixtures.
# Called by CI on pwsh and Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('doctor-dispatch-' + [guid]::NewGuid())
$originalHome = $HOME
try {
    $scripts = Join-Path $scratch '.local/share/chezmoi/scripts'
    New-Item -ItemType Directory -Force $scripts | Out-Null
    [IO.File]::WriteAllText((Join-Path $scripts 'dotfiles-doctor.ps1'), 'param([switch]$Fix); $Fix.IsPresent')
    Set-Variable HOME $scratch -Force
    foreach ($profileName in 'PowerShell', 'WindowsPowerShell') {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "Documents/$profileName/Microsoft.PowerShell_profile.ps1"), [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Profile parse failed: $parseErrors" }
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'dot' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        if ((dot doctor) -ne $false) { throw "${profileName}: read-only doctor enabled repair" }
        if ((dot doctor --fix) -ne $true) { throw "${profileName}: --fix was not forwarded" }
        if ((dot doctor -Fix) -ne $true) { throw "${profileName}: -Fix was not forwarded" }
    }
    $ssh = Join-Path $scratch '.ssh'
    New-Item -ItemType Directory -Force (Join-Path $ssh 'nested') | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)
    $textPath = Join-Path $ssh 'nested/config with spaces'
    [IO.File]::WriteAllBytes($textPath, $utf8.GetBytes("Host example`r`n# standalone`rCR`n"))
    $binaryPath = Join-Path $ssh 'binary'
    $binary = [byte[]](0, 13, 10, 255)
    [IO.File]::WriteAllBytes($binaryPath, $binary)
    $lfPath = Join-Path $ssh 'known_hosts'
    [IO.File]::WriteAllBytes($lfPath, $utf8.GetBytes("already LF`n"))
    $source = [IO.File]::ReadAllText((Join-Path $repo 'scripts/dotfiles-doctor.ps1'))
    $start = $source.IndexOf('# --- 8.')
    $end = $source.IndexOf('if ($script:Errors -gt 0)', $start)
    $pass = [scriptblock]::Create('param($homeDir, $Fix)' + "`n" + $source.Substring($start, $end - $start))
    function Result($r, $check, $message) { "$r $check $message" }
    $report = & $pass $scratch $false
    if (-not ($report -match '^warn ssh-crlf')) { throw 'CRLF warning missing' }
    if (-not [IO.File]::ReadAllText($textPath).Contains("`r`n")) { throw 'Read-only check modified text' }
    $report = & $pass $scratch $true
    if (-not ($report -match '^ok ssh-crlf normalized')) { throw 'Repair confirmation missing' }
    if ([IO.File]::ReadAllText($textPath) -cne "Host example`n# standalone`rCR`n") { throw 'Text conversion was not byte-preserving except CRLF' }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($binaryPath)) -ne [Convert]::ToBase64String($binary)) { throw 'Binary file changed' }
    if ([IO.File]::ReadAllText($lfPath) -cne "already LF`n") { throw 'LF file changed' }
    if ((& $pass $scratch $false) -match '^warn ') { throw 'Warning persisted after repair' }
    Write-Host 'PASS: both dispatchers, read-only warning, LF repair, binary preservation, clean recheck'

    # Execute the installer's actual account-loading block against disposable
    # keys. ssh-add is mocked so no fixture is loaded into the user's agent.
    foreach ($name in 'plain', 'protected') {
        $passphrase = if ($name -eq 'plain') { '' } else { 'fixture-passphrase' }
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Command ssh-keygen).Source
        $info.Arguments = '-q -t ed25519 -N "' + $passphrase + '" -f "' + (Join-Path $ssh $name) + '"'
        $info.UseShellExecute = $false
        $process = [Diagnostics.Process]::Start($info)
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Fixture key generation timed out' }
        if ($process.ExitCode -ne 0) { throw 'Fixture key generation failed' }
        $process.Dispose()
    }
    [IO.File]::WriteAllText((Join-Path $ssh 'loaded'), 'must be skipped before parsing')
    $template = [IO.File]::ReadAllText((Join-Path $repo 'run_onchange_generate_identities.ps1.tmpl'))
    $start = $template.IndexOf('    if (Get-Command ssh-add -ErrorAction SilentlyContinue)')
    $end = $template.IndexOf('        # The Windows ssh-agent', $start)
    $loader = [scriptblock]::Create('param($declaredKeys, $declaredFps)' + "`n" + $template.Substring($start, $end - $start) + "`n}")
    $script:addedKeys = @()
    Set-Item -Path Function:ssh-add -Value {
        if ($args[0] -eq '-l') { '256 SHA256:already-loaded fixture'; return }
        $script:addedKeys += [IO.Path]::GetFileName($args[0])
    }
    $originalUserProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = $scratch
        & $loader @('loaded', 'plain', 'protected') @{ loaded = 'SHA256:already-loaded' }
    } finally { $env:USERPROFILE = $originalUserProfile }
    if ($script:addedKeys.Count -ne 1 -or $script:addedKeys[0] -ne 'plain') {
        throw "Installer must load only the unencrypted, not-yet-loaded key: $script:addedKeys"
    }
    Write-Host 'PASS: installer skips loaded/protected keys and loads an unencrypted missing key'
} finally {
    Set-Variable HOME $originalHome -Force
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
