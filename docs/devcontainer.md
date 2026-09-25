# 🐳 Devcontainer Setup

Use your dotfiles automatically in VS Code devcontainers.

## The Architecture (two layers, different jobs)

| Layer | Mechanism | When it runs | What it does | Cost |
|-------|-----------|-------------|--------------|------|
| **Tools** (runtime core, serena, claude, etc.) | devcontainer-features (`features` block) | Container **build** (Docker image layer) | Installs binaries into the image | Cached — subsequent starts skip it |
| **Config** (aliases, profiles, git identities) | VS Code dotfiles (`dotfiles.repository`) | Container **start** (every time) | Runs `install.sh` → `chezmoi init --apply` | Cheap — file copies only |

The dotfiles installer **does not install packages** in devcontainers — `.chezmoi.toml.tmpl` keys its container detection on `DEVCONTAINER`/`REMOTE_CONTAINERS` being set or `/.dockerenv` existing, and renders all package groups false non-interactively when it fires. (`CI=true` also forces non-interactive rendering anywhere, but the devcontainer path is the detection above, not CI.) Only configuration files are applied. This is by design: installing packages on every container start would be wasteful since they're already in the Docker image via features. Devcontainers do not own, start, or configure host remote-access services; set those up manually on the host with the [remote-access guide](remote-access.md).

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

### 6. Persist authentication once: identity volumes + a forwarded agent

**Separate identity from project.** Tokens and SSH keys are per *user*, not per
project, so they belong in named volumes and an agent socket shared by every
container. Do that and you log in **once, ever**: restarts, rebuilds and brand-new
projects all inherit it. Only deleting the volume loses it.

Keep the volume names identical across projects — that is what makes a new
project start already authenticated.

The first five mounts are the agent CLIs' credentials and config. The last is the
SSH **agent socket** — never `~/.ssh`, never a key file.

```json
{
  "remoteUser": "vscode",
  "mounts": [
    "source=agents-claude,target=/home/vscode/.claude,type=volume",
    "source=agents-codex,target=/home/vscode/.codex,type=volume",
    "source=agents-opencode-config,target=/home/vscode/.config/opencode,type=volume",
    "source=agents-gemini,target=/home/vscode/.gemini,type=volume",
    "source=agents-gh,target=/home/vscode/.config/gh,type=volume",
    "source=${localEnv:SSH_AUTH_SOCK},target=/ssh-agent,type=bind"
  ],
  "remoteEnv": { "SSH_AUTH_SOCK": "/ssh-agent" }
}
```

Where each CLI actually keeps its credentials (verified, not assumed):

| CLI | File | Volume above |
|---|---|---|
| Claude Code | `~/.claude/.credentials.json` | `agents-claude` |
| Codex | `~/.codex/auth.json` | `agents-codex` |
| OpenCode | `~/.local/share/opencode/auth.json` | none by default — see below |
| agy | under `~/.gemini` | `agents-gemini` |
| gh | `~/.config/gh/hosts.yml` | `agents-gh` |

**OpenCode is the exception, and it is a real trade-off.** `~/.config/opencode`
holds config and commands; its auth lives in `~/.local/share/opencode/auth.json`,
an optional user-managed data path that also contains `opencode.db`, snapshots and
per-project state. So:

- **Default (above):** config persists, auth does not. You re-run OpenCode's login
  after a rebuild.
- **Want persistent OpenCode auth?** Mount the data path too, and prefer a
  *per-project* volume name so sessions and snapshots don't bleed between projects:
  `"source=myproject-opencode-data,target=/home/vscode/.local/share/opencode,type=volume"`.
- **Headless?** Provide the provider API key through the environment instead and
  skip the mount entirely.

Claude also keeps user settings in `~/.claude.json`. Docker named volumes are
directories, so that single file cannot be one; use an explicit bind mount if it
must persist, for example
`source=/absolute/host/path/claude.json,target=/home/vscode/.claude.json,type=bind`.

`gh` uses the OS keyring on your host, so there is nothing on the host to share.
Inside a container there is no keyring, so `gh auth login` writes
`~/.config/gh/hosts.yml`, which the volume persists.

**Do not bind-mount host credential files.** A bind mount gives everything in the
container write access to the tokens that own your GitHub, Anthropic and OpenAI
sessions — and agents often run there with permission prompts disabled. A named
volume is a separate copy you authorize once, inside the trust boundary you meant
to create. For headless or CI runs, inject an API key from a secret store instead.

### SSH without VS Code (terminal-first)

VS Code forwards the agent for you. The `devcontainer` CLI and plain `docker run`
do not, so a terminal-first workflow wires it explicitly — that is what the
`SSH_AUTH_SOCK` mount above does.

- **Launch from WSL, not PowerShell.** WSL's agent is a Unix socket Docker can
  bind. The Windows OpenSSH agent is a named pipe, which a Linux container cannot
  mount without an `npiperelay` + `socat` bridge — which is exactly what
  `ssh-agent-relay` sets up; see **[SSH Agents](ssh-agents.md)**. Mount the
  per-account **filtered** socket (`ssh-agent-relay use <alias>`), not the raw one,
  so the container cannot authenticate as another account.
- Your zsh already starts an agent and loads the declared keys, so the socket
  exists at login.
- **Key material never enters the container.** While attached, though, anything
  inside can *use* the keys the agent holds.

**One agent per GitHub account.** Forwarding exposes the whole agent, so a single
agent holding three accounts' keys lets a customer's container authenticate as
your personal account. Start one agent per account, each with one key, and let
each project tree select its own socket — the same per-directory idea the
`[[data.accounts]]` `dirs` list already uses for git identity:

```sh
# ~/.zshrc (or a login script): one socket per account
ssh-agent -a "$XDG_RUNTIME_DIR/ssh-agent.personal.sock" >/dev/null 2>&1

# projects/work/.envrc (direnv): this tree uses the work agent
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.work.sock"
```

`${localEnv:SSH_AUTH_SOCK}` in `devcontainer.json` then resolves to whichever
agent is active in the directory you launch from.

**Signing in a container**, without mounting a key: derive the public key from
the forwarded agent at start, and sign through the agent.

```sh
ssh-add -L | head -1 > ~/.ssh/signing.pub
git config --global user.signingkey ~/.ssh/signing.pub
git config --global commit.gpgsign true
```

Chezmoi leaves signing off in containers by default (`commit.gpgsign` and the
`-i <key> -o IdentitiesOnly=yes` pin are host-only), because a container has no
key files: `IdentitiesOnly` with a missing identity refuses the agent's keys, and
ssh signing needs a public key file present.

### Where the code lives, and where the agents run

You do not SSH into the container.

- **Code:** in the WSL filesystem, bind-mounted to `/workspaces/<repo>`. Edits are
  visible from both sides; keep it out of `/mnt/c` for speed.
- **Toolchain:** in the image, via features. That is the point — the Windows host
  needs Docker, WSL, chezmoi and your agent, and no language runtimes.
- **Agents:** run `claude`, `codex`, `opencode` or `agy` **inside** the container
  (`devcontainer exec` or `docker exec`), where the toolchain and the project are.
  They inherit the volumes above, so they are already logged in.

### What happens on container start

The dotfiles `install.sh` detects the devcontainer environment (`DEVCONTAINER=true` or `REMOTE_CONTAINERS=true`) and:
1. Skips the consent prompt (non-interactive)
2. Skips the gum bootstrap and package menu (saves bandwidth — tools come from features)
3. Runs `chezmoi init --apply` — applies your shell config, git identities, aliases, and profiles

No packages are installed. Only configuration is applied. This runs on every container start (fast — it's file copies, not package downloads).

## Troubleshooting

### Fonts not displaying correctly

The Nerd Font must be installed on your **host machine** (Windows/Mac), not in the container. VS Code uses the host's fonts, so a container-installed Nerd Font does not affect VS Code's integrated terminal. Use the `nerd-font` feature only for GUI software that renders inside the container.

### Oh-My-Zsh not found

Make sure `common-utils` feature has `"installOhMyZsh": true`.

### Slow container startup

Features add ~30-60 seconds on first build. Subsequent rebuilds are faster (Docker layer caching). The dotfiles config application adds < 5 seconds on each start.

### zsh-z not working

`zsh-z` is a SHA-pinned dotfiles external, installed when the dotfiles configuration is applied. Make sure the `dotfiles.repository` configuration above is present, then rebuild the container.
