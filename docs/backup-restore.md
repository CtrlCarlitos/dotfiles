# Chezmoi Backup & Restore Guide

This guide covers backup, restore, and migration across **Windows**, **WSL**, **Linux**, and **macOS**.

---

## Quick Reference

| File | Purpose | Location |
|------|---------|----------|
| `chezmoi.toml` | All config + Git identities | `~/.config/chezmoi/chezmoi.toml` |
| SSH keys | Your identity keys | `~/.ssh/id_*` |

---

## 1. Backup (From Existing Machine)

### Linux / macOS / WSL

```bash
cat << 'EOF' > /tmp/backup-chezmoi.sh
#!/bin/bash
set -euo pipefail
echo "Create backup tarball"
mkdir -p /tmp/chezmoi-backup
cp ~/.config/chezmoi/chezmoi.toml /tmp/chezmoi-backup/ 2>/dev/null || echo "No chezmoi.toml yet"
cp ~/.ssh/id_* /tmp/chezmoi-backup/ 2>/dev/null || echo "No SSH keys yet"
tar -czvf ~/chezmoi-backup.tar.gz -C /tmp chezmoi-backup
rm -rf /tmp/chezmoi-backup
echo "✓ Backup saved to: ~/chezmoi-backup.tar.gz"
EOF
chmod +x /tmp/backup-chezmoi.sh
/tmp/backup-chezmoi.sh
rm -f /tmp/backup-chezmoi.sh
```

### Windows (PowerShell)

```powershell
@'
Write-Host "Create backup folder"
$backupDir = "$env:TEMP\chezmoi-backup"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

Write-Host "Copy config and SSH keys"
Copy-Item "$env:USERPROFILE\.config\chezmoi\chezmoi.toml" $backupDir -ErrorAction SilentlyContinue
Copy-Item "$env:USERPROFILE\.ssh\id_*" $backupDir -ErrorAction SilentlyContinue

Write-Host "Create zip archive"
Compress-Archive -Path $backupDir -DestinationPath "$env:USERPROFILE\chezmoi-backup.zip" -Force
Remove-Item $backupDir -Recurse -Force
Write-Host "✓ Backup saved to: $env:USERPROFILE\chezmoi-backup.zip"
'@ | Set-Content -Encoding UTF8 -Path "$env:TEMP\\backup-chezmoi.ps1"
& "$env:TEMP\\backup-chezmoi.ps1"
Remove-Item "$env:TEMP\\backup-chezmoi.ps1" -Force
```

---

## 2. Transferring Backups Between Platforms

### WSL ↔ Windows

```bash
# WSL → Windows
cp ~/chezmoi-backup.tar.gz /mnt/c/Users/YourWindowsUsername/

# Windows → WSL
cp /mnt/c/Users/YourWindowsUsername/chezmoi-backup.tar.gz ~/
```

### If you have a Windows ZIP on Linux/macOS/WSL

```bash
# Unzip a Windows-created backup in POSIX
unzip -o ~/chezmoi-backup.zip -d /tmp
```

### If you have a POSIX tar.gz on Windows

```powershell
# PowerShell (Windows 10/11 has bsdtar)
tar -xzf "$env:USERPROFILE\chezmoi-backup.tar.gz" -C $env:TEMP
```

If `tar` is missing, install 7-Zip and run:
```powershell
7z x "$env:USERPROFILE\chezmoi-backup.tar.gz" -o"$env:TEMP"
```

### Cross-machine (any platform)

Use your preferred method:
- **USB drive**: Copy the backup file directly
- **Cloud storage**: Upload to OneDrive, Google Drive, Dropbox
- **SCP/SFTP**: `scp ~/chezmoi-backup.tar.gz user@newmachine:~/`

---

## 3. Restore (On New Machine)

> **Run BEFORE the installer** to skip interactive prompts.

### Linux / macOS / WSL

```bash
cat << 'EOF' > /tmp/restore-chezmoi.sh
#!/bin/bash
set -euo pipefail
echo "Extract backup"
tar -xzvf ~/chezmoi-backup.tar.gz -C /tmp

echo "Create directories"
mkdir -p ~/.config/chezmoi ~/.ssh

echo "Restore files"
cp /tmp/chezmoi-backup/chezmoi.toml ~/.config/chezmoi/ 2>/dev/null || true
cp /tmp/chezmoi-backup/id_* ~/.ssh/ 2>/dev/null || true

echo "Fix SSH permissions"
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_* 2>/dev/null || true
chmod 644 ~/.ssh/*.pub 2>/dev/null || true

echo "Cleanup"
rm -rf /tmp/chezmoi-backup ~/chezmoi-backup.tar.gz

echo "✓ Config restored. Now run the installer."
EOF
chmod +x /tmp/restore-chezmoi.sh
/tmp/restore-chezmoi.sh
rm -f /tmp/restore-chezmoi.sh
```

### Windows (PowerShell)

```powershell
@'
Write-Host "Extract backup"
Expand-Archive -Path "$env:USERPROFILE\chezmoi-backup.zip" -DestinationPath "$env:TEMP" -Force

Write-Host "Create directories"
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.config\chezmoi" | Out-Null
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null

Write-Host "Restore files"
Copy-Item "$env:TEMP\chezmoi-backup\chezmoi.toml" "$env:USERPROFILE\.config\chezmoi\" -ErrorAction SilentlyContinue
Copy-Item "$env:TEMP\chezmoi-backup\id_*" "$env:USERPROFILE\.ssh\" -ErrorAction SilentlyContinue

Write-Host "Cleanup"
Remove-Item "$env:TEMP\chezmoi-backup" -Recurse -Force
Remove-Item "$env:USERPROFILE\chezmoi-backup.zip" -Force

Write-Host "✓ Config restored. Now run the installer."
'@ | Set-Content -Encoding UTF8 -Path "$env:TEMP\\restore-chezmoi.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\\restore-chezmoi.ps1"
Remove-Item "$env:TEMP\\restore-chezmoi.ps1" -Force
```

---

## 4. Run the Installer

### Linux / macOS / WSL

```bash
export PAT="your_github_pat"
sh -c "$(curl -H "Authorization: token $PAT" -fsLS https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.sh)"
```

### Windows (PowerShell as Administrator)

```powershell
$PAT="your_github_pat"; iex "& {$(irm -Headers @{Authorization="token $PAT"} https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1)}"
```

The installer will detect your existing config and **skip interactive prompts**.

Note: account `dirs` from `chezmoi.toml` are auto-created during `chezmoi apply`.

> **Privilege requirements, and why the commands above look the way they do:**
> the Windows command needs an elevated ("as Administrator") PowerShell -
> Chocolatey requires it, and without it every package install fails with
> exit code 1 (confirmed live). The Linux/macOS/WSL command deliberately has
> **no** `sudo` in front of it - don't add one. `install.sh` elevates
> internally only for the specific steps that need root; running the whole
> thing as root breaks things it shouldn't (Claude Code's installer
> explicitly refuses to run under sudo, for one).

---

## Platform-Specific Notes

| Platform | Config Location | Notes |
|----------|-----------------|-------|
| **Linux** | `~/.config/chezmoi/` | Standard XDG path |
| **macOS** | `~/.config/chezmoi/` | Same as Linux |
| **WSL** | `~/.config/chezmoi/` | Inside WSL filesystem |
| **Windows** | `%USERPROFILE%\.config\chezmoi\` | PowerShell: `$env:USERPROFILE` |

---

## Troubleshooting

### "Config file template has changed"

This warning appears when the dotfiles have been updated but your local config is older.

```bash
# Back up ~/.config/chezmoi/chezmoi.toml first. `chezmoi init` preserves only
# documented fields that .chezmoi.toml.tmpl explicitly re-emits.
chezmoi init
```

---

### SSH keys not working

**Symptoms**: `Permission denied (publickey)` when cloning/pushing

**Linux/macOS/WSL fix**:
```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_*
chmod 644 ~/.ssh/*.pub
```

**Windows fix**:

Run `chezmoi apply` so the repository's SSH ACL normalizer rebuilds owner-only
key ACLs. Do not use a broad `icacls` grant: it cannot reliably remove existing
explicit grants to other users/groups.

---

### Git clone asks for username/password

**Cause**: Private repo requires authentication during `chezmoi init`.

**Solutions**:
1. **Use SSH** (recommended): ensure SSH keys are set up before cloning.
2. **Use GitHub CLI or a credential manager** for HTTPS authentication.

Do not embed a PAT in a clone URL: it can persist in shell history, process
listings, Git remote configuration, and logs.

---

### Git identity not applied in directory

**Symptoms**: `git config user.email` shows wrong identity

**Check**:
1. Verify directory is in the account's `dirs` list in `chezmoi.toml`
2. Ensure `.gitconfig` has the conditional include:

```bash
cat ~/.gitconfig | grep -A2 "includeIf"
```

**Fix**: Edit `chezmoi.toml` and add the directory, then:
```bash
chezmoi apply
```

---

### Packages not installing

**Check elevation/privileges first** - this is the most common cause:
- **Windows**: packages fail silently (one `choco` exit-code-1 warning per
  package, easy to miss) unless PowerShell is running **as Administrator**.
- **Linux/macOS/WSL**: if `install.sh` was run with `sudo` in front of it,
  some installers (Claude Code's, for one) refuse to run under sudo and
  silently won't install. Re-run as your normal user, no `sudo`.

**Check which packages are enabled**:
```bash
chezmoi data | grep -A10 packages
```

**Force package reinstall**:
```bash
chezmoi apply --force
```

---

### Fresh start (nuclear option)

**Linux/macOS/WSL**:
```bash
rm -rf ~/.config/chezmoi ~/.local/share/chezmoi
export PAT="your_pat"
sh -c "$(curl -H "Authorization: token $PAT" -fsLS https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.sh)"
```

**Windows** (PowerShell as Administrator):
```powershell
Remove-Item -Recurse -Force "$env:USERPROFILE\.config\chezmoi", "$env:USERPROFILE\.local\share\chezmoi"
$PAT="your_pat"; iex "& {$(irm -Headers @{Authorization="token $PAT"} https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1)}"
```

---

## Repair Existing Machine

If chezmoi is installed but config is missing:

### Create chezmoi.toml

```toml
[data]
  [data.packages]
    install_core = true
    install_modern = true
    install_fonts = true
    install_ai_tools = true
    install_desktop = false

[[data.accounts]]
  name = "Your Name"
  email = "your.email@example.com"
  username = "your-github-username"
  provider = "github"
  key = "id_personal"
  organizations = []
  dirs = ["projects/personal", ".local/share/chezmoi"]

# Add more accounts as needed:
# [[data.accounts]]
#   name = "Work Name"
#   email = "work@company.com"
#   ...
```

### Apply the fix

```bash
chezmoi apply --verbose
```
