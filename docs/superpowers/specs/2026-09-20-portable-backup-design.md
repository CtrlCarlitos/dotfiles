# Portable Dotfiles Backup Design

## Purpose

Provide a small, supported backup and restore flow for machine-local identity
data. It must work across Windows, Linux, macOS, and WSL without preserving
installed packages, caches, or application state.

## Commands

The repository provides four equivalent scripts:

- `scripts/dotbackup.sh`
- `scripts/dotbackup.ps1`
- `scripts/dotrestore.sh`
- `scripts/dotrestore.ps1`

The scripts use the platform's installed `7z` or `7zz` executable. They do
not store, print, or pass a backup passphrase on a command line.

## Archive Format

`dotbackup` writes an AES-256 encrypted, header-encrypted 7-Zip archive to:

```text
~/.dot_backups/dotfiles-YYYYMMDD-HHMMSS.7z
```

The archive is portable between supported operating systems. The user copies
the archive to independent storage or the destination machine; the scripts do
not upload archives.

The archive root is `dotfiles-backup-v1/` and contains:

- `manifest.json`: format version, creation timestamp, and source platform.
- `chezmoi/chezmoi.toml`: machine-local ChezMoi data.
- `ssh/`: the complete `~/.ssh` directory, including non-standard private-key
  filenames, public keys, known-host data, signing data, and SSH config.

No Git configuration, VS Code state, application data, package caches, or
installed tools are included. Chezmoi recreates managed configuration from the
restored local data.

## Backup Flow

1. Confirm that `chezmoi.toml` exists and that `7z` or `7zz` is available.
2. Stage only the allowlisted files in a temporary directory.
3. Prompt twice for a passphrase without terminal echo and require a match.
4. Create the encrypted archive with encrypted filenames.
5. Remove the staging directory and print the resulting archive path.

The passphrase belongs in a password-manager secure note named `Dotfiles
backup passphrase`. It is never added to ChezMoi configuration, shell history,
or the archive.

## Restore Flow

`dotrestore` accepts one archive path. It prompts once for the passphrase,
extracts into a temporary directory, and validates the manifest before writing
any destination files.

Restore refuses to overwrite an existing `chezmoi.toml` or any existing file
under `~/.ssh`. The user must resolve conflicts manually before retrying. This
keeps the simple flow non-destructive.

After a successful restore, the scripts direct the user to run:

```text
chezmoi init
chezmoi apply
```

Those commands regenerate managed configuration and apply the repository's
SSH permissions or ACL normalization.

## Verification

Shell and PowerShell contract tests cover archive layout, encryption flags,
passphrase handling, allowlisted content, manifest validation, and overwrite
refusal. Tests use temporary homes and test archives only.
