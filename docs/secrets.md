# Secrets and machine-local data

The pattern: **machine-specific values live in `~/.config/chezmoi/chezmoi.toml`
and chezmoi templates render them.** That file is normally untracked; never
put its real values in the repository. Protect it like other local metadata
and include it only in encrypted backups. Documented examples/templates are
intentionally tracked; real host names, aliases, and credentials are not.

## What belongs where

| Data | Home |
|---|---|
| Git accounts (name/email/keys/dirs) | `[[data.accounts]]` in chezmoi.toml |
| SSH host aliases (bastions, servers) | `[[data.ssh_hosts]]` in chezmoi.toml |
| Remote-access login keys (names + targets only) | `[[data.remote_access.login_keys]]` in chezmoi.toml |
| Genuine secret file payloads (keys, tokens) | chezmoi `encrypted_` prefix with age/gpg — future; overkill for aliases |

Nothing in this table is ever committed. If you can `git grep` it, it is in
the wrong place.

## SSH hosts (`[[data.ssh_hosts]]`)

Rendered into `~/.ssh/config` by `private_dot_ssh/private_config.tmpl` on
every apply — VS Code Remote-SSH (installed by the global extension set)
reads `~/.ssh/config` natively, so aliases appear in the Remote-SSH host
list automatically. On Windows each host also becomes a Windows Terminal
profile named `SSH: <name>` (see [Terminal Experience](terminal.md#windows-terminal)).

```toml
# ~/.config/chezmoi/chezmoi.toml
[[data.ssh_hosts]]
  name     = "prod-jump"              # required: Host alias
  hostname = "10.0.0.5"               # required: IP or DNS
  user     = "carlitos"               # optional: login user
  port     = 22                       # optional
  identity = "id_personal"            # optional: key NAME in ~/.ssh - the .pub
                                      # half is referenced and must be copied to
                                      # every machine that SSHes out from it; the
                                      # private half stays Windows-side (offered
                                      # through the ssh-agent relay on WSL)
  # Omit proxy unless this host needs a configured bastion alias.
  proxy    = "bastion"                # optional: ProxyJump alias
  comment  = "Bastion for staging - office IP only"   # optional: free text
  os       = "linux"                  # optional: "mac" | "linux" (Terminal tab color)
  tmux     = true                     # optional: Terminal tab re-attaches to tmux "main" (or a session name)
```

The `comment` field renders as the block's header comment in
`~/.ssh/config`, so `grep` on the config answers "what was this host?" —
the operator's memory hook. Fields are all optional except `name` and
`hostname`; `identity` entries reference key NAMES in `~/.ssh`:
`run_onchange_generate_identities` (on every apply) normalizes the private
key's ACL on Windows, the `.pub` half is what the rendered Host block points
at — copy each `.pub` to a machine's `~/.ssh` and that machine SSHes out
through the ssh-agent relay (the private half stays Windows-side).

Add hosts, run `chezmoi apply`, done. Remove the entry and apply to retire
the alias.

`~/.ssh/config` is the only SSH config. The installers unset VS Code's
`remote.SSH.configFile` on every run, so Remote-SSH, `ssh`, and the Windows
Terminal `SSH: <name>` profiles all read the same file. Hosts from a hand-kept
config (the old OneDrive `Documents\_ssh\config`) go into `[[data.ssh_hosts]]`
by hand.

## Remote-access login keys (`[[data.remote_access.login_keys]]`)

`dot remote` owns a separate namespace of SSH login keys for reaching your own
machines — distinct from the Git identities `[[data.accounts]]` and
`run_onchange_generate_identities` generate. Never one key for both purposes.
The config records names and targets only, never key material:

```toml
# ~/.config/chezmoi/chezmoi.toml (machine-local, never committed)
[[data.remote_access.login_keys]]
  name = "id_<machine-local-key-name>"   # ~/.ssh/<name>(.pub)
  targets = ["windows", "wsl"]           # which server arms authorize the .pub
  generate = true                        # false = public half dropped here from another device
```

`generate = true` has `dot remote setup` offer to create the pair on this
machine; `generate = false` expects the public half dropped into
`~/.ssh/<name>.pub` from the owning device. Private halves stay on the owning
device and are never committed. See [Remote Access](remote-access.md) for the
full schema and the scripted authorization flow.

## Why not `encrypted_`?

Chezmoi supports encrypting tracked files (age/gpg) — right for
private keys or tokens that must ship with the repo to many machines. Host
aliases, usernames, and comments are per-machine facts, not repo payloads:
the untracked-config pattern is simpler and keeps each machine's truth
local. Revisit `encrypted_` only if a secret must genuinely travel inside
the repository.
