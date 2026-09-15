# 🐳 Devcontainer Setup

Use your dotfiles automatically in VS Code devcontainers.

## The Architecture (two layers, different jobs)

| Layer | Mechanism | When it runs | What it does | Cost |
|-------|-----------|-------------|--------------|------|
| **Tools** (runtime core, serena, claude, etc.) | devcontainer-features (`features` block) | Container **build** (Docker image layer) | Installs binaries into the image | Cached — subsequent starts skip it |
| **Config** (aliases, profiles, git identities) | VS Code dotfiles (`dotfiles.repository`) | Container **start** (every time) | Runs `install.sh` → `chezmoi init --apply` | Cheap — file copies only |

The dotfiles installer **does not install packages** in devcontainers — `chezmoi init` renders all groups false non-interactively (CI=true), so only configuration files are applied. This is by design: installing packages on every container start would be wasteful since they're already in the Docker image via features. Devcontainers do not own, start, or configure host remote-access services; set those up manually on the host with the [remote-access guide](remote-access.md).

If you want a tool in your devcontainer, add it as a feature. If you want your aliases, git identity, and shell profile in your devcontainer, wire the dotfiles.

## Setup

### 1. Add Features to devcontainer.json

Full feature inventory: [github.com/CtrlCarlitos/devcontainer-features](https://github.com/CtrlCarlitos/devcontainer-features). The following is a representative selection:

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
    "ghcr.io/CtrlCarlitos/devcontainer-features/modern-cli:1": {}
  }
}
```

Pick only what you need — features are opt-in per tool.

### Compatibility and reproducibility

The examples intentionally use Debian/Ubuntu images. `runtime_core` and
`nerd-font` require an APT-based image, while several other features assume
Linux build tools or package managers. `guardrail` currently supports Linux
x86_64 only, so omit it on arm64 containers.

The `:1` references select the latest compatible feature release, not an
immutable tool image. Pin feature options where reproducibility matters and
expect APT, npm, and upstream installers to change independently.

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

### 4. Agent-workstation profile (optional)

The complete example is deliberately lightweight. Add this profile only when a
container needs the full agent workstation. Individual CLI features install
only their named CLI: skills, browser automation, and Guardrail are separate
features.

```json
{
  "features": {
    "ghcr.io/CtrlCarlitos/devcontainer-features/runtime_core:1": {
      "version": "22"
    },
    "ghcr.io/CtrlCarlitos/devcontainer-features/claude-code:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/opencode:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/antigravity-cli:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/codex:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/serena:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/graft:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/curated-skills:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/guardrail:1": {},
    "ghcr.io/CtrlCarlitos/devcontainer-features/playwright:1": {
      "browser": "chromium"
    }
  }
}
```

This maps dotfiles' `agent_toolkit` bundle to Serena, Graft, and optional
Playwright. CLI features map to their individual CLIs; `curated-skills` and
`guardrail` provide the cross-agent integrations. Playwright downloads a
browser and should be omitted from containers that do not need browser
automation. `act` has no devcontainer feature; install it in the base image or
project Dockerfile when local GitHub Actions execution is required.

### 5. OpenCode server safety

Keep OpenCode's feature server disabled unless the container explicitly needs
it, and bind any enabled server to `127.0.0.1` unless an authenticated proxy is
deliberately configured. Binding it to `0.0.0.0` requires
`OPENCODE_SERVER_PASSWORD` at container runtime. Supply the password through
the runtime environment or your platform's secret mechanism, not image build
configuration or feature options.

### 6. Persist agent authentication and configuration

Feature installation is cached in the image, but agent authentication and
configuration live in the remote user's home directory. Use named volumes when
they should survive a rebuild: `~/.claude`, `~/.codex`, and
`~/.config/opencode`. This example assumes the standard `vscode`
remote user from the base image; change the target paths if your `remoteUser`
differs.

```json
{
  "remoteUser": "vscode",
  "mounts": [
    "source=devcontainer-claude,target=/home/vscode/.claude,type=volume",
    "source=devcontainer-codex,target=/home/vscode/.codex,type=volume",
    "source=devcontainer-opencode-config,target=/home/vscode/.config/opencode,type=volume"
  ]
}
```

`~/.local/share/opencode` is an optional user-managed data path. Mount it only
when you intentionally need its contents to survive rebuilds.

Claude also stores user settings in `~/.claude.json`. Docker named volumes are
directories, so do not mount one at that file path. If that file must persist,
create a host file outside the repository and bind mount it explicitly, for
example `source=/absolute/host/path/claude.json,target=/home/vscode/.claude.json,type=bind`.

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

The Nerd Font must be installed on your **host machine** (Windows/Mac), not in the container. VS Code uses the host's fonts, so a container-installed Nerd Font does not affect VS Code's integrated terminal. Use the `nerd-font` feature only for GUI software that renders inside the container.

### Oh-My-Zsh not found

Make sure `common-utils` feature has `"installOhMyZsh": true`.

### Slow container startup

Features add ~30-60 seconds on first build. Subsequent rebuilds are faster (Docker layer caching). The dotfiles config application adds < 5 seconds on each start.

### zsh-z not working

`zsh-z` is a SHA-pinned dotfiles external, installed when the dotfiles configuration is applied. Make sure the `dotfiles.repository` configuration above is present, then rebuild the container.
