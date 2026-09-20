# Chezmoi Backup & Restore Guide

This guide covers the supported backup and recovery flow across **Windows**, **WSL**, **Linux**, and **macOS**.

---

## What Is Backed Up

`dotbackup` creates a portable, AES-256 encrypted 7-Zip archive with encrypted archive headers (`-mhe=on`). The archive path is:

```text
~/.dot_backups/dotfiles-YYYYMMDD-HHMMSS.7z
```

The archive has a fixed allowlist:

- `~/.config/chezmoi/chezmoi.toml`
- Every regular file under `~/.ssh`, including non-standard private-key names, public keys, SSH config, known-host data, and signing data
- A `manifest.json` describing the `dotfiles-backup-v1` archive format, creation time, and source platform

Git configuration, VS Code state, application data, installed packages, caches, and installed tools are excluded. Chezmoi recreates managed configuration after recovery.

Before continuing, install `7z` or `7zz` and ensure `chezmoi.toml` exists. The scripts prompt for the passphrase without echoing it and never put it on the command line. Store the passphrase in a password-manager secure note named `Dotfiles backup passphrase`; do not store it in ChezMoi configuration, shell history, or the archive.

---

## Backup

### Linux / macOS / WSL

Run the supported backup script from the machine being backed up:

```bash
bash ~/.local/share/chezmoi/scripts/dotbackup.sh
```

The script writes the encrypted `.7z` archive to `~/.dot_backups/` and prints its exact path. It refuses to replace an archive if its timestamped destination already exists.

### Windows (PowerShell)

Run the supported backup script:

```powershell
pwsh -File "$env:USERPROFILE\.local\share\chezmoi\scripts\dotbackup.ps1"
```

It creates the same AES-256, header-encrypted `.7z` archive under `~/.dot_backups/` and refuses an existing destination archive.

---

## Transfer The Archive

The scripts do not upload backups. After creating one, manually copy the encrypted `.7z` archive to independent storage or to the destination machine, for example by USB drive, cloud storage, or SCP/SFTP. Keep the archive and its password-manager passphrase separate.

Because the archive is portable, a backup created on Windows, Linux, macOS, or WSL can be restored on another supported platform. Do not unpack or recreate the archive by hand.

---

## Restore

Restore only onto a machine where any existing `~/.config/chezmoi/chezmoi.toml` and conflicting files under `~/.ssh` have been reviewed. `dotrestore` refuses to overwrite either an existing ChezMoi config or any existing SSH file. Resolve collisions manually, then rerun the script.

### Linux / macOS / WSL

Pass the transferred archive path to the restore script:

```bash
bash ~/.local/share/chezmoi/scripts/dotrestore.sh ~/.dot_backups/dotfiles-YYYYMMDD-HHMMSS.7z
```

### Windows (PowerShell)

Pass the transferred archive path to the restore script:

```powershell
pwsh -File "$env:USERPROFILE\.local\share\chezmoi\scripts\dotrestore.ps1" -Archive "C:\path\dotfiles-YYYYMMDD-HHMMSS.7z"
```

The restore script prompts for the passphrase, validates the manifest, restores the allowlisted local data, and then directs you to run:

```bash
chezmoi init
chezmoi apply
```

Run `chezmoi init` first, then `chezmoi apply`. This recreates managed configuration and applies the repository's SSH permission or ACL normalization.

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
