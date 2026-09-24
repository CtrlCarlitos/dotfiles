# 🔑 SSH agents: one key vault, one agent per account

Private keys exist in **one** place. Everything else — WSL distros, devcontainers,
remote hosts — borrows the *ability to sign* through an agent socket, never the key
itself. Each account gets its own filtered socket, so handing one to a container
cannot authenticate as a different account.

```
WSL (relay mode)
Windows ssh-agent service        <- the only place private keys live
  (DPAPI-encrypted in the registry, survives reboots)
        |  npiperelay + socat (WSL holds no keys)
        v
  upstream socket in WSL
        |  ssh-agent-filter, one per account
        +--> ssh-agent.github-personal.sock   (personal auth + signing keys only)
        +--> ssh-agent.github-work.sock       (work keys only)
                    |  bind-mounted into a devcontainer
                    v
              that project's container
```

Native mode (Linux, macOS): no Windows, no relay, no filter - one real agent per
account, each holding only that account's local keys, feeding the same kind of
per-account socket.

## If the machine dies

One copy per machine is the rule for *live* machines, not a reason to have no copy at all. A key that authorises you to a server may be the only thing that gets you back into that server, and no agent model recovers it for you.

[Backup & Restore](backup-restore.md) creates an AES-256, header-encrypted archive that includes `~/.ssh`, for exactly that case: restoring onto a **replacement** machine. It is not a way to provision an additional one - `dotrestore` refuses to overwrite existing keys, so the two models cannot quietly blur.

## Why

- **Rotation is one operation.** Generate the key once, register the new public key,
  done. With a key per environment you regenerate and re-register everywhere, and
  update `allowed_signers` in each one.
- **A new WSL distro needs no key setup**, so `dotfiles` on a second distro is just
  config.
- **Forwarding exposes an agent, not a file.** Anything in a container can *use* the
  keys that agent holds while attached — which is exactly why each account gets its
  own filtered socket rather than one agent holding everything.
- **Passphrases are typed once, ever.** The Windows agent is a service; `ssh-add`
  stores the key encrypted in the registry and it survives reboots. WSL and
  containers never prompt, because they hold no keys.

## Setup

**Windows (the vault).** `run_onchange_generate_identities.ps1` already sets the
`ssh-agent` service to Automatic and loads your declared keys; `npiperelay` comes
from the `core` package group. Add a passphrase-protected key once by hand:

```powershell
ssh-add "$env:USERPROFILE\.ssh\id_personal"   # asks once, ever
ssh-add -l                                     # what the vault holds
```

**WSL (no keys).** `socat` and `ssh-agent-filter` come from the `core` group. Your
zsh startup runs `ssh-agent-relay start` in the background and points
`SSH_AUTH_SOCK` at your default account's filtered socket. Nothing to type.

```sh
ssh-agent-relay status                      # upstream + per-account sockets
eval "$(ssh-agent-relay use github-work)"   # switch this shell to another account
```

Per **project**, let direnv pick the account, the same way `[[data.accounts]]`
`dirs` picks the git identity:

```sh
# ~/projects/work/.envrc
eval "$(ssh-agent-relay use github-work)"
```

### Linux and macOS hosts

Same outcome, simpler mechanism: the keys are **local**, so there is no relay and
no filter — `ssh-agent-relay start` gives each account **its own real ssh-agent**
holding only that account's keys (from `[[data.accounts]]`). That is stronger than
filtering a shared agent, and needs no `ssh-agent-filter` (which has no Homebrew
formula). `SSH_AGENT_RELAY_NATIVE=1` forces this mode on WSL too, for anyone who
deliberately keeps keys inside the distro.

Passphrase-protected keys never block a shell: macOS loads them from the keychain
(`--apple-use-keychain`), and elsewhere the relay skips the key and prints the
`ssh-add` command to run once.

**Docker on macOS is the one real gap.** Docker Desktop cannot reliably bind-mount
an arbitrary host unix socket; the supported route is its synthesized
`/run/host-services/ssh-auth.sock`, which forwards **the agent Docker Desktop
itself sees** — so you cannot pick a per-account socket per project:

```json
"mounts": ["source=/run/host-services/ssh-auth.sock,target=/ssh-agent,type=bind"],
"remoteEnv": { "SSH_AUTH_SOCK": "/ssh-agent" }
```

Options, in order of preference: keep the *default* macOS agent scoped to one
account and use containers only for that account; run Linux-VM Docker (Colima,
Lima, or a remote engine), where per-account socket mounts work as on Linux; or
accept the shared agent for container work while host-side git stays isolated.
Linux hosts have no such limitation — Docker is native and the per-account socket
mounts directly.

**Devcontainers** mount the *filtered* socket; see
[devcontainer.md](devcontainer.md#ssh-without-vs-code-terminal-first).

```json
"mounts": ["source=${localEnv:SSH_AUTH_SOCK},target=/ssh-agent,type=bind"],
"remoteEnv": { "SSH_AUTH_SOCK": "/ssh-agent" }
```

## How accounts map to keys

`ssh-agent-relay` allows a key into an account's socket by **comment**. `devprofile`
creates keys with the account email as the comment, and `<email>-sign` for the
signing key, so the default mapping needs no configuration. If your keys carry other
comments, set them explicitly:

```toml
[[data.accounts]]
  username = "work-user"
  email = "me@work.example"
  agent_key_comments = ["me@work.example", "work-laptop-2026"]
```

Check what a socket actually exposes — this is the security property, so verify it
rather than assume it:

```sh
SSH_AUTH_SOCK=$(ssh-agent-relay use github-work | cut -d= -f2) ssh-add -l
```

## Signing

Signing needs the **public** key file plus the private key in an agent. On a host
that is already true. In a devcontainer the identity generator writes the `.pub`
from the forwarded agent and enables `commit.gpgsign` for that account; with no
matching key in the agent it leaves signing off and says so, instead of failing
every commit.

## Gotchas found the hard way

- **`bind: Operation not supported`** from `ssh-agent-filter` means its socket
  landed on a Windows-mounted path (`/mnt/c`, DrvFs). The relay sets `TMPDIR` to the
  runtime dir to avoid it; if you run the filter by hand, do the same.
- **A container sees no keys** → the upstream agent is empty. `ssh-add -l` on
  Windows. Keys must be loaded *before* you attach: `AddKeysToAgent` cannot help,
  because it only triggers when ssh reads a key *file*, and containers have none.
- **`ssh-agent-filter` missing** → the relay falls back to the unfiltered upstream
  and warns. Things work; isolation does not. `apt install ssh-agent-filter`.
- **Launch devcontainers from WSL**, not PowerShell: the Windows agent is a named
  pipe, which a Linux container cannot bind.
