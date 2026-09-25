# devprofile — Git Identity Management

Cross-platform (Linux, macOS, WSL, Windows). Manages which Git identity
(name, email, signing key) is active, based on your chezmoi `accounts`.

## How it works (the 90% case)

**You don't need to run devprofile at all.** Every account's `dirs` list
is wired into `~/.gitconfig` as a conditional include — the right identity
(name, email, signing key, SSH alias) is already selected automatically
just by which folder a repo lives in. `cd` into a repo under
`~/projects/work/` and you're committing as your work identity. `cd` into
`~/projects/personal/` and you're your personal identity. No switching, no
remembering.

This works because each account generates:

- A dedicated **SSH auth key** (`id_<username>`) for push/pull
- A dedicated **SSH signing key** (`id_<username>_sign`) for commit signing
- A `[includeIf "gitdir:..."]` block in `~/.gitconfig` that activates the
  right identity when you're inside that account's `dirs`
- A `Host <provider>-<username>` SSH alias so each account pushes/pulls
  with its own key (no SSH-agent key-guessing)

## The devprofile CLI (the 10% case)

For exceptions — repos outside any mapped path, verifying the active
identity, creating a new account:

| Command | What it does |
|---------|-------------|
| `devprofile` | Which identity is active in this repo? |
| `devprofile list` | All configured accounts and their SSH keys |
| `devprofile use <username>` | Override identity for this repo only |
| `devprofile init <username> <email> [--passphrase\|--no-passphrase]` | New account with fresh keys |
| `devprofile verify [--install-hook]` | Sanity check; `--install-hook` adds a pre-commit hook that prints the identity and fails a commit only when `user.name`/`user.email` are unset (git's `useConfigOnly` already blocks that — the hook is a visibility aid, not a gate against the wrong account) |

Passphrase handling for `init`: with neither flag, an interactive terminal
gets a `[y/N]` prompt (default **no** passphrase); `--passphrase` forces the
`ssh-keygen` prompt, `--no-passphrase` skips it. On bash,
`DEVPROFILE_PASSPHRASE` (`1`/`0`, or `true`/`yes`/`no`/`false`) sets the
default when neither flag is given — explicit flags win over the env var.

Short alias everywhere (zsh and PowerShell): `dp`.

## Example outputs

<details>
<summary><code>devprofile list</code></summary>

```
▸ Configured Accounts (3 total):

  ┌────────────────────┬────────────────────────┬──────────────────────────────┬──────────┐
  │ USERNAME           │ NAME                   │ EMAIL                        │ PROVIDER │
  ├────────────────────┼────────────────────────┼──────────────────────────────┼──────────┤
  │ account-a          │ Account A              │ account-a@example.com        │ github   │
  │ account-b          │ Account B              │ account-b@example.com        │ github   │
  │ account-c          │ Account C              │ account-c@example.com        │ github   │
  └────────────────────┴────────────────────────┴──────────────────────────────┴──────────┘

▸ SSH Keys:

  ┌──────────────────────────┬────────────┬────────────────┐
  │ KEY FILE                 │ TYPE       │ STATUS         │
  ├──────────────────────────┼────────────┼────────────────┤
  │ id_account-a             │ auth       │ ✓ in use       │
  │ id_account-a_sign        │ signing    │ ✓ in use       │
  │ id_account-b             │ auth       │ ✓ in use       │
  │ id_account-b_sign        │ signing    │ ✓ in use       │
  │ id_account-c             │ auth       │ ✓ in use       │
  └──────────────────────────┴────────────────┴────────────────┘
```
</details>

<details>
<summary><code>devprofile</code> (bare, inside a repo) / <code>devprofile use account-b</code></summary>

```
✓ Current identity (repo-local):

  ┌──────────┬────────────────────────────────────────────┐
  │ Name     │ Account B                                  │
  ├──────────┼────────────────────────────────────────────┤
  │ Email    │ account-b@example.com                      │
  ├──────────┼────────────────────────────────────────────┤
  │ Key      │ ~/.ssh/id_account-b_sign.pub               │
  └──────────┴────────────────────────────────────────────┘

✓ Email matches a configured account
```

`use` additionally prints a `Signing` row (the dedicated signing key,
separate from the auth key shown as `Key`):
```
✓ Configured identity for this repo: account-b

  ┌──────────┬────────────────────────────────────────────┐
  │ Name     │ Account B                                  │
  ├──────────┼────────────────────────────────────────────┤
  │ Email    │ account-b@example.com                      │
  ├──────────┼────────────────────────────────────────────┤
  │ Key      │ ~/.ssh/id_account-b                        │
  ├──────────┼────────────────────────────────────────────┤
  │ Signing  │ ~/.ssh/id_account-b_sign                   │
  └──────────┴────────────────────────────────────────────┘
```
</details>

<details>
<summary><code>devprofile verify</code> — correct identity for this repo</summary>

```
▸ Identity Verification:

  ┌──────────┬──────────────────────────────────────────┬───┐
  │ Identity │ Account B <account-b@example.com>        │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Key      │ ~/.ssh/id_account-b_sign.pub             │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Account  │ Email matches configured account         │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Dir      │ Matches account-b (dirs mapping)         │ ✓ │
  └──────────┴──────────────────────────────────────────┴───┘

✓ All checks passed!
```
</details>

<details>
<summary><code>devprofile verify</code> — wrong identity for this repo</summary>

E.g. `devprofile use account-c` was run while sitting in a repo whose
`dirs` mapping actually belongs to `account-b`:

```
▸ Identity Verification:

  ┌──────────┬──────────────────────────────────────────┬───┐
  │ Identity │ Account C <account-c@example.com>        │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Key      │ ~/.ssh/id_account-c.pub                  │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Account  │ Email matches configured account         │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Dir      │ Expected account-b (account-b@example... │ ✗ │
  └──────────┴──────────────────────────────────────────┴───┘

! 1 issue(s) found
```
</details>

## Configuring accounts

Accounts live in `~/.config/chezmoi/chezmoi.toml` under `[[data.accounts]]`:

```toml
[[data.accounts]]
  name = "Your Name"
  email = "you@example.com"
  username = "your-username"
  provider = "github"
  key = "id_personal"           # SSH auth key
  signingKey = "id_personal_sign"  # Optional: dedicated signing key
  organizations = []            # Orgs to rewrite URLs for
  dirs = ["projects/personal"]  # Where this identity is active
```

See [docs/chezmoi.toml.example](chezmoi.toml.example) for a complete example.

## SSH agent behavior

- **Linux/macOS:** keys are added to `ssh-agent` on shell start (passphrase
  asked once per agent lifetime).
- **Windows:** the `ssh-agent` Windows service stores keys DPAPI-encrypted
  and reloads them automatically on boot. No macOS-style `UseKeychain`
  needed.
- **Keys persist across reboots on all platforms.**
- **This repo only ever ADDS keys, never flushes.** A key you loaded
  yourself is left alone.
- **To remove a key:** `ssh-add -d ~/.ssh/<key>` (or `ssh-add -D` to clear
  all, then re-run `chezmoi apply` to reload the declared set).

## Verifying signatures locally

`~/.ssh/allowed_signers` (what makes `git log --show-signature` /
`git verify-commit` work) is generated **per machine, from what's already
local to it** — this repo never commits anyone's public keys.

Each `chezmoi apply` merges three things into this file:
1. Whatever the file already contains (hand-edits survive)
2. Each configured account's signing key from `chezmoi.toml`
3. Every other `*.pub` under `~/.ssh` not already covered (email recovered
   from the key's comment; unrecognizable comments are skipped with a warning)

If you copy keys between your machines, everything lines up automatically.
If you generate fresh keys per machine, the scan above picks each one up
over time, or you can copy `~/.ssh/allowed_signers` itself.

## FAQ

**Existing keys without passphrases?**
No need to regenerate. The passphrase option only affects new keys. To add
one to an existing key:
```sh
ssh-keygen -p -f ~/.ssh/id_yourkey
```

**Auth vs signing keys?**
`key` is used for auth (push/pull). `signingKey` is optional for commit
signing. If `signingKey` is omitted, `key` is used for both. For separate
keys, a passphrase on **both** is recommended.

**`devprofile verify`'s `Dir` row?**
Cross-checks the current repo's path against every account's `dirs` list
and flags mismatches — catches a repo cloned/moved under the wrong
account's directory, or a `devprofile use` run in the wrong repo.

**Platform docs?**
- [Windows specifics](windows.md) — PowerShell profiles, Chocolatey, the
  Windows `ssh-agent` service
- [WSL specifics](testing-wsl.md) — WSL has its own agent, separate from
  Windows
