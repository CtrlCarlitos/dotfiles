# Secrets and machine-local data

The pattern: **sensitive values live in `~/.config/chezmoi/chezmoi.toml` —
machine-local, never git-tracked — and chezmoi templates render them.** Git
carries the templates; each machine carries its own values. The same
mechanism already drives git identities (`[[data.accounts]]`); everything
below follows it.

## What belongs where

| Data | Home |
|---|---|
| Git accounts (name/email/keys/dirs) | `[[data.accounts]]` in chezmoi.toml |
| SSH host aliases (bastions, servers) | `[[data.ssh_hosts]]` in chezmoi.toml |
| Genuine secret file payloads (keys, tokens) | chezmoi `encrypted_` prefix with age/gpg — future; overkill for aliases |

Nothing in this table is ever committed. If you can `git grep` it, it is in
the wrong place.

## SSH hosts (`[[data.ssh_hosts]]`)

Rendered into `~/.ssh/config` by `private_dot_ssh/private_config.tmpl` on
every apply — VS Code Remote-SSH (installed by the global extension set)
reads `~/.ssh/config` natively, so aliases appear in the Remote-SSH host
list automatically.

```toml
# ~/.config/chezmoi/chezmoi.toml
[[data.ssh_hosts]]
  name     = "prod-jump"              # required: Host alias
  hostname = "10.0.0.5"               # required: IP or DNS
  user     = "carlitos"               # optional: login user
  port     = 22                       # optional
  identity = "id_personal"            # optional: key name in ~/.ssh
  proxy    = ""                       # optional: ProxyJump alias (bastion)
  comment  = "Bastion for staging - office IP only"   # optional: free text
```

The `comment` field renders as the block's header comment in
`~/.ssh/config`, so `grep` on the config answers "what was this host?" —
the operator's memory hook. Fields are all optional except `name` and
`hostname`; `identity` files get their ACL normalized by
`run_onchange_generate_identities` on every apply.

Add hosts, run `chezmoi apply`, done. Remove the entry and apply to retire
the alias.

## Why not `encrypted_`?

Chezmoi supports encrypting tracked files (age/gpg) — right for
private keys or tokens that must ship with the repo to many machines. Host
aliases, usernames, and comments are per-machine facts, not repo payloads:
the untracked-config pattern is simpler and keeps each machine's truth
local. Revisit `encrypted_` only if a secret must genuinely travel inside
the repository.
