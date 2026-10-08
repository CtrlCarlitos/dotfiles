# scripts/lib/ps-desktop-shortcuts.ps1 - [data.upgrade] desktop_shortcuts = false: installers
# drop shortcuts on the Desktop (Geany, OBS, ShareX, Termius, Handy, ...), and no winget or
# Chocolatey sweep has a per-installer switch to stop them. Every place dotfiles runs
# installers - dot up's installer, migrate-to-winget, dot upgrade - snapshots the Desktops
# first and removes only the shortcuts that are NEW afterwards; a shortcut that was already
# there is never touched. Loaded by ps-common.ps1 and inlined into
# run_onchange_install_packages.ps1.tmpl. ASCII only (docs/invariants.md #16).

# True when [data.upgrade] desktop_shortcuts = false is set in the chezmoi
# config: the operator does not want installers' desktop shortcuts to survive
# `dot upgrade`. Absent or any other value = leave shortcuts alone (the
# default). Plain line scan, like the other config reads in scripts/:
# `chezmoi data` would resolve its own config path (docs/invariants.md #5).
function Test-DesktopShortcutsDisabled {
    param([string]$ConfigPath = (Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.toml'))
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
    $inUpgrade = $false
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -match '^\s*\[data\.upgrade\]\s*$') { $inUpgrade = $true; continue }
        if ($inUpgrade -and $line -match '^\s*\[') { $inUpgrade = $false }
        if ($inUpgrade -and $line -match '^\s*desktop_shortcuts\s*=\s*false\s*(#.*)?$') { return $true }
    }
    return $false
}

# Shortcut files (*.lnk, *.url) on this user's Desktop and the Public Desktop.
# GetFolderPath follows OneDrive-redirected Desktops. Returns full paths.
function Get-DesktopShortcut {
    param([string[]]$Directory = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')))
    $dirs = $Directory |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
        Select-Object -Unique
    foreach ($dir in $dirs) {
        Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.lnk', '.url' } |
            ForEach-Object { $_.FullName }
    }
}

# Delete the shortcuts that exist now but not in $Before (a Get-DesktopShortcut
# snapshot taken ahead of the upgrade). Shortcuts that were already there are
# never touched. Returns the removed paths.
function Remove-NewDesktopShortcut {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Before = @(), [string[]]$Directory)
    $known = @{}
    foreach ($path in $Before) { $known[$path.ToLowerInvariant()] = $true }
    $scan = if ($PSBoundParameters.ContainsKey('Directory')) { @(Get-DesktopShortcut -Directory $Directory) } else { @(Get-DesktopShortcut) }
    foreach ($path in $scan) {
        if ($known.ContainsKey($path.ToLowerInvariant())) { continue }
        if ($PSCmdlet.ShouldProcess($path, 'remove new desktop shortcut')) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            $path
        }
    }
}
