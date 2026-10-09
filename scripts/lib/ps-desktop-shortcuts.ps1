# scripts/lib/ps-desktop-shortcuts.ps1 - [data.upgrade] desktop_shortcuts = false: installers
# drop shortcuts on the Desktop (Geany, OBS, ShareX, Termius, Handy, ...), and no winget or
# Chocolatey sweep has a per-installer switch to stop them. Every place dotfiles runs
# installers - dot up's installer, migrate-to-winget, dot upgrade - snapshots the Desktops
# first (Get-DesktopShortcutBaseline, not a fresh Get-DesktopShortcut call - see there for why)
# and removes only the shortcuts that are NEW afterwards; a shortcut that was already in the
# baseline is never touched. Loaded by ps-common.ps1 and inlined into
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

# The Desktop as it looked before dotfiles started managing shortcuts here, persisted once in
# dotfiles state so EVERY later run diffs against the same fixed point - not a snapshot taken
# fresh at the start of whichever run happens to call it. A fresh-every-run snapshot (plain
# Get-DesktopShortcut, what this used to call) treats anything already on the Desktop as
# permanently exempt, including a shortcut dropped by an install that ran before the FIRST sweep
# ever executed: the original one-time bootstrap, a run that crashed before sweeping, or a
# manual `winget install` run between two `dot upgrade`s. Confirmed live, 2026-10: Geany, VLC,
# Antigravity and Termius, all from the original bootstrap, survived every `dot up`/
# `dot upgrade` since, because no run's own before/after window ever saw them appear - they
# needed one manual cleanup pass. Freezing the baseline the first time this runs means every
# run from then on diffs against that same fixed point, so anything appearing after it -
# including between monitored runs - is caught without needing a fresh snapshot to happen to
# have witnessed it arrive. The trade a frozen baseline makes deliberately: a shortcut you add
# on purpose AFTER the baseline was captured is just as "new" to it as an installer's, and gets
# swept on the next run too, same as [data.upgrade] desktop_shortcuts = false already promises
# for anything an installer drops.
function Get-DesktopShortcutBaseline {
    param([string[]]$Directory)
    $path = Join-Path $env:USERPROFILE ".local\state\dotfiles\desktop-shortcuts-baseline.txt"
    if (Test-Path -LiteralPath $path) {
        return @([IO.File]::ReadAllLines($path) | Where-Object { $_ })
    }
    # The outer @() is load-bearing, not redundant with the one on each branch: Windows
    # PowerShell 5.1 collapses an if/else statement's output to $null when the executed
    # branch's only emitted object is itself a zero-length array (confirmed live, 2026-10-09 -
    # WriteAllLines then threw "Value cannot be null" the first time this machine's Desktop and
    # Public Desktop both had zero shortcuts left to snapshot). pwsh does not have this quirk.
    $current = @(if ($PSBoundParameters.ContainsKey('Directory')) { Get-DesktopShortcut -Directory $Directory } else { Get-DesktopShortcut })
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [IO.File]::WriteAllLines($path, $current)
    return $current
}

# Delete the shortcuts that exist now but not in $Before (a Get-DesktopShortcutBaseline
# snapshot taken ahead of the upgrade). Shortcuts that were already in the baseline are
# never touched. Returns the removed paths.
function Remove-NewDesktopShortcut {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Before = @(), [string[]]$Directory)
    $known = @{}
    foreach ($path in $Before) { $known[$path.ToLowerInvariant()] = $true }
    # Same $null-collapse quirk as Get-DesktopShortcutBaseline's $current - see there.
    $scan = @(if ($PSBoundParameters.ContainsKey('Directory')) { Get-DesktopShortcut -Directory $Directory } else { Get-DesktopShortcut })
    foreach ($path in $scan) {
        if ($known.ContainsKey($path.ToLowerInvariant())) { continue }
        if ($PSCmdlet.ShouldProcess($path, 'remove new desktop shortcut')) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            $path
        }
    }
}
