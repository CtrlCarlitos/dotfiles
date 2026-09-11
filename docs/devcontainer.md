# 🐳 Devcontainer Setup

Use your dotfiles automatically in VS Code devcontainers.

## How It Works

| Component | Installed By | Configured By |
|-----------|--------------|---------------|
| Zsh + Oh-My-Zsh | **Chezmoi (Externals)** | Dotfiles |
| Starship | **Chezmoi (Packages)** | run_onchange_install... |
| Zsh plugins | **Chezmoi (Externals)** | Dotfiles (.zshrc) |
| Git | **Features** | Dotfiles |
| AI Tools (Codex, Claude, OpenCode, Antigravity, Superpowers, Playwright, act, ...) | **Devcontainer Features** (not dotfiles) | - |
| MesloLGS NF | **Host machine** | - |
| Your aliases & config | - | **Dotfiles** |

> **Note:** In devcontainers, **every** package category defaults to `false` -
> Core, Modern CLI, Fonts, AI Tools, Desktop, and Antigravity IDE alike (verified
> against `.chezmoi.toml.tmpl`: `$isDevcontainer` forces `$interactive` false,
> and every category's non-interactive literal is `false`, `install_core`
> included as of this session - it used to be the one exception that
> defaulted `true` even non-interactively, which silently overrode a CI test
> config; fixed to match the other five). Nothing from
> `run_onchange_install_packages.*` runs in a devcontainer by default - git,
> zsh, AI tools, everything comes from devcontainer Features or Chezmoi's own
> Externals mechanism instead (see the table above and the example below).

## Setup

### 1. Add Features to devcontainer.json

```json
{
  "features": {
    // Shell setup
    "ghcr.io/devcontainers/features/common-utils": {
      "installZsh": true,
      "installOhMyZsh": true,
      "configureZshAsDefaultShell": true,
      "installOhMyZshConfig": false
    },

    "ghcr.io/devcontainers-extra/features/zsh-plugins": {
      "plugins": "zsh-autosuggestions zsh-syntax-highlighting zsh-completions"
    },
    
    // Git (if not in base image)
    "ghcr.io/devcontainers/features/git:1": {},
    
    // AI tools (optional)
    "ghcr.io/anthropics/devcontainer-features/claude-code:1": {}
  }
}
```

### 2. Add Dotfiles Configuration

Add to the same `devcontainer.json`:

```json
{
  "customizations": {
    "vscode": {
      "settings": {
        "dotfiles.repository": "CtrlCarlitos/dotfiles",
        "dotfiles.targetPath": "~/dotfiles",
        "dotfiles.installCommand": "devcontainer/install.sh"
      }
    }
  }
}
```

Or use VS Code global settings (applies to all devcontainers):
1. Open VS Code Settings (`Ctrl+,`)
2. Search for "dotfiles"
3. Set **Repository**: `CtrlCarlitos/dotfiles`
4. Set **Install Command**: `devcontainer/install.sh`

### 3. Complete Example

```json
{
  "name": "My Project",
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  
  "features": {
    "ghcr.io/devcontainers/features/common-utils": {
      "installZsh": true,
      "installOhMyZsh": true,
      "configureZshAsDefaultShell": true,
      "installOhMyZshConfig": false
    },

    "ghcr.io/devcontainers-extra/features/zsh-plugins": {
      "plugins": "zsh-autosuggestions zsh-syntax-highlighting zsh-completions"
    },
    "ghcr.io/devcontainers/features/git:1": {},
    "ghcr.io/devcontainers/features/node:1": {}
  },
  
  "customizations": {
    "vscode": {
      "settings": {
        "terminal.integrated.defaultProfile.linux": "zsh",
        "dotfiles.repository": "CtrlCarlitos/dotfiles",
        "dotfiles.installCommand": "devcontainer/install.sh"
      }
    }
  }
}
```

### What the Dotfiles Script Does
In devcontainers, `devcontainer/install.sh` delegates to the universal installer, which:
1. Runs `chezmoi apply`
2. Installs Oh-My-Zsh & plugins (via `.chezmoiexternal.toml`)
3. Links configuration files (`.zshrc`)

This means you do **not** need to use devcontainer features for Zsh/OMZ if you use this repository.

## SSH Keys in Devcontainers

Your SSH keys from the host are automatically forwarded if you:

1. Have SSH agent running on host
2. Have keys loaded: `ssh-add ~/.ssh/id_*`

VS Code forwards the agent automatically.

### Verify SSH Works

```bash
ssh-add -l              # Should list your keys
ssh -T git@github.com   # Should authenticate
```

## Troubleshooting

### Fonts not displaying correctly

The Nerd Font must be installed on your **host machine** (Windows/Mac), not in the container. VS Code uses the host's fonts.

### Oh-My-Zsh not found

Make sure `common-utils` feature has `"installOhMyZsh": true`.

### Slow container startup

Features add ~30-60 seconds on first build. Subsequent rebuilds are faster.

### zsh-z not working

The `zsh-plugins` feature may not include zsh-z. Our dotfiles script installs it if missing.
