# 🐳 Devcontainer Setup

Use your dotfiles automatically in VS Code devcontainers.

## The Architecture (two layers, different jobs)

| Layer | Mechanism | When it runs | What it does | Cost |
|-------|-----------|-------------|--------------|------|
| **Tools** (node, serena, claude, etc.) | devcontainer-features (`features` block) | Container **build** (Docker image layer) | Installs binaries into the image | Cached — subsequent starts skip it |
| **Config** (aliases, profiles, git identities) | VS Code dotfiles (`dotfiles.repository`) | Container **start** (every time) | Runs `install.sh` → `chezmoi init --apply` | Cheap — file copies only |

The dotfiles installer **does not install packages** in devcontainers — `chezmoi init` renders all groups false non-interactively (CI=true), so only configuration files are applied. This is by design: installing packages on every container start would be wasteful since they're already in the Docker image via features.

If you want a tool in your devcontainer, add it as a feature. If you want your aliases, git identity, and shell profile in your devcontainer, wire the dotfiles.

## Setup

### 1. Add Features to devcontainer.json

Available features: [github.com/CtrlCarlitos/devcontainer-features](https://github.com/CtrlCarlitos/devcontainer-features)

```json
{
  "features": {
    "ghcr.io/devcontainers/features/common-utils": {
      "installZsh": true,
      "installOhMyZsh": true,
      "configureZshAsDefaultShell": true,
      "installOhMyZshConfig": false
    },

    "ghcr.io/CtrlCarlitos/devcontainer-features/runtime_core:1": {
      "version": "22"
    },

    "ghcr.io/CtrlCarlitos/devcontainer-features/claude-code:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/opencode:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/antigravity-cli:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/serena:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/graft:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/modern-cli:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/nerd-font:1": {}
  }
}
```

Pick only what you need — features are opt-in per tool.

### 2. Add Dotfiles Configuration

Add to the same `devcontainer.json`:

```json
{
  "customizations": {
    "vscode": {
      "settings": {
        "dotfiles.repository": "CtrlCarlitos/dotfiles",
        "dotfiles.installCommand": "install.sh"
      }
    }
  }
}
```

Or use VS Code global settings (applies to all devcontainers):
1. Open VS Code Settings (`Ctrl+,`)
2. Search for "dotfiles"
3. Set **Repository**: `CtrlCarlitos/dotfiles`
4. Set **Install Command**: `install.sh`

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

    "ghcr.io/CtrlCarlitos/devcontainer-features/runtime_core:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/claude-code:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/modern-cli:1": {}
  },

  "customizations": {
    "vscode": {
      "settings": {
        "terminal.integrated.defaultProfile.linux": "zsh",
        "dotfiles.repository": "CtrlCarlitos/dotfiles",
        "dotfiles.installCommand": "install.sh"
      }
    }
  }
}
```

### What happens on container start

The dotfiles `install.sh` detects the devcontainer environment (`DEVCONTAINER=true` or `REMOTE_CONTAINERS=true`) and:
1. Skips the consent prompt (non-interactive)
2. Skips the gum bootstrap and package menu (saves bandwidth — tools come from features)
3. Runs `chezmoi init --apply` — applies your shell config, git identities, aliases, and profiles

No packages are installed. Only configuration is applied. This runs on every container start (fast — it's file copies, not package downloads).

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

The Nerd Font must be installed on your **host machine** (Windows/Mac), not in the container. VS Code uses the host's fonts. Or add the `nerd-font` feature for terminal-only font rendering.

### Oh-My-Zsh not found

Make sure `common-utils` feature has `"installOhMyZsh": true`.

### Slow container startup

Features add ~30-60 seconds on first build. Subsequent rebuilds are faster (Docker layer caching). The dotfiles config application adds < 5 seconds on each start.

### zsh-z not working

The `zsh-plugins` feature may not include zsh-z. Our dotfiles script installs it if missing.
