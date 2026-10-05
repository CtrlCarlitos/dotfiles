# Remote Access

`dot remote` (scripts/remote-access.sh on Linux, macOS, and inside WSL;
scripts/remote-access.ps1 on the Windows host) sets up, reports on, and
repairs the machine-local plumbing for private remote access: Tailscale
provides connectivity, SSH/RDP provide remote access, tmux provides session
persistence, and a Cloudflare tunnel gated by Cloudflare Access is the
optional browser path. The scripts configure the host; provider-side steps
stay manual. This guide is the map between the two.

## 1. Scope and non-goals

Keep development-agent backends private: use a tailnet or a local console,
never a public route.
No Caddy, code-server, Tailscale Funnel, or public agent backends.
Do not provide an external route to an agent backend.

Identities, credentials, tunnel definitions, SSH keys, and tailnet ACL values
belong on the machine or in the provider dashboard, never in this repository.

Install-only package groups never configure anything: `remote_access`
installs the Tailscale and cloudflared clients only; `remote_access_server`
installs OpenSSH-server prerequisites only.

## 2. Policy for agent web services

Agent web services (OpenCode and similar backends) stay private:

- They MUST bind to loopback (127.0.0.1) in their own environment and never
  be router-forwarded or reachable without authentication. Ports must not
  collide across environments: a Windows listener wins WSL2 localhost
  forwarding on the same port.
- They MUST retain their application authentication — the
  `OPENCODE_SERVER_PASSWORD` stays set even when only the tailnet can reach
  the port.
- An OpenCode listener may ride Tailscale Serve or a Cloudflare tunnel only behind Cloudflare Access.

Windows and WSL instances are separate backends; each declares its own
`environment` and port under `[data.remote_access.services]` (example ports:
4096 windows, 4097 wsl). Remove an exposure when it is no longer needed:
`tailscale serve off` on the serving machine.

Manual start of a private listener and its private mapping:

```bash
OPENCODE_SERVER_PASSWORD='<machine-local secret>' opencode web --hostname 127.0.0.1 --port 4096
tailscale serve --https=443 http://127.0.0.1:4096
```

## 3. Native phone and browser agent paths

Use each vendor's authenticated remote-control path rather than exposing its
backend:

- **Claude Remote Control:** pair and approve the device through Claude's
  native remote-control flow.
- **Codex Remote:** use the paired Mac or Windows ChatGPT desktop bridge; keep
  its pairing and account state on those devices.
- **Antigravity Remote Control:** use the session-scoped remote-control flow
  and revoke the session when it is no longer needed.
- **Universal fallback:** run work in tmux and connect through private SSH.

Vendor pairing, tokens, and session approvals must not be copied into
dotfiles or shared configuration.

## 4. Manual provider actions (never scripted)

`dot remote` checks for these and prints `ACTION REQUIRED` when missing; it
never automates provider authentication:

- Enroll the machine in the tailnet (`tailscale up` or the GUI login), and
  review the tailnet ACL that limits approved devices and ports.
- `cloudflared tunnel login`, then `cloudflared tunnel create <name>` — the
  resulting credential file `~/.cloudflared/<tunnel-id>.json` is machine-local
  and is never committed.
- Create one Cloudflare Access application and allow policy per exposed
  hostname, with MFA enforced by your identity provider.
- Register the cloudflared service as an elevated manual step:
  `cloudflared service install`.
- On the Windows host the installer's own post-install notes cover the same
  two steps, but only while they are still true: `[Post-Install] Tailscale is
  not connected` (when `tailscale status` fails; `remote_access` group) and
  `[Post-Install] The SSH server (sshd) is not running` (when the `sshd`
  service is not `Running`; `remote_access_server` group). A probe that cannot
  tell (tool missing, command failed or hung) prints the note rather than
  hiding it. Connected and running machines see neither.
- macOS: enable Remote Login and Screen Sharing by hand — `dot remote`
  verifies their state but never flips it.

## 5. `dot remote setup`

Idempotent configure for the running host: already-correct state is verified,
not rewritten, and a second run makes zero mutations. Missing prerequisites
are reported, never installed.

- **Windows:** sshd Automatic + running; the `OpenSSH-Tailscale` (:22),
  `WSL-SSH-Tailscale` (:2222), and `RemoteDesktop-Tailscale` (:3389) rules
  scoped to the Tailscale interface and tailnet address space; Remote Desktop
  when `rdp.enabled`; optional Windows-side WSL port forwarding;
  Tailscale Serve mappings from `services.*`; and `tunnel render`.
- **Linux:** sshd; a tailnet-scoped firewall; xrdp installed through the
  system package manager only when a desktop environment is detected and
  `rdp.enabled`; Tailscale Serve mappings; `tunnel render`.
- **macOS:** Remote Login / Screen Sharing verification only; Tailscale Serve
  mappings; `tunnel render`.

```bash
dot remote setup
```

Setup ends with the staged-flow reminder: verify key login from another
device, then run `dot remote harden-ssh`.

## 6. `dot remote status`

Read-only doctor; always exit 0. One section per area — Tailscale, SSH, RDP,
WSL, Tailscale Serve, Cloudflare, Applications, tmux — with verified /
manual-action / FAIL markers. FAIL lines name what `fix` would repair; WARN
lines name the manual action. Never prints secrets.

## 7. `dot remote fix`

Repairs deterministic machine-local state only. Per platform:

- **Windows:** restart sshd and restore its `Automatic` startup mode;
  re-ensure the Tailscale-scoped firewall rules for the capabilities the
  config declares (`OpenSSH-Tailscale` :22 when `ssh.enabled`,
  `RemoteDesktop-Tailscale` :3389 when `rdp.enabled`, `WSL-SSH-Tailscale`
  :2222 when `wsl.enabled` — behind the same authenticated-Tailscale gate
  as setup); reconcile the WSL portproxy when `wsl.enabled`; restart the
  cloudflared service when it is registered but not running (never
  installed by fix); re-apply configured Tailscale Serve mappings
  (auth-gated); re-render the local tunnel config.
- **Linux:** restart sshd and restore its startup mode; restart the
  cloudflared service when the systemd unit exists but is not running
  (read-only `systemctl list-unit-files` existence check); re-apply
  configured Tailscale Serve mappings (auth-gated); re-render the local
  tunnel config. The tailnet-scoped firewall stays a verify-only path
  owned by setup, and the :2222 portproxy is Windows-owned — fix prints
  the pointer to `dot remote wsl-reconcile` on the Windows host.
- **macOS:** the Serve and tunnel repairs only — Remote Login, Screen
  Sharing, and service restarts stay manual.

It never signs in to Tailscale, touches Access policies, weakens SSH auth,
disables a security control, or exposes a new service. On an already-healthy
host fix records zero mutations — every repair verifies current state first.

## 8. `dot remote harden-ssh`

Flips the target sshd to key-only (`PasswordAuthentication no`). Two guards:
it refuses unless the target's authorized_keys state holds at least one login
key, and it refuses without `--confirmed` — you attest that key login was
tested from another device.

## 9. `dot remote wsl-reconcile`

Windows-only. The reconcile-not-hardcode pattern: query the current WSL IPv4,
inspect the managed :2222 portproxy rule, compare, no-op when correct, replace
only the managed rule when stale or missing, verify the WSL SSH target, and
report PASS / WARN / FAIL.

`dot remote wsl-reconcile --install-task` registers the elevated logon
Scheduled Task `dotfiles-wsl-reconcile`, which re-runs the reconcile on every
logon (WSL IPs change across reboots). Idempotent, and not required by
default — the default workflow reconciles on demand with `dot remote
wsl-reconcile` or `dot remote fix`.

### Config gates the plumbing reads

All of these live in your machine-local `~/.config/chezmoi/chezmoi.toml`
(never committed), next to `services`, `tunnel` and `login_keys`:

```toml
[data.remote_access.wsl]
enabled = true    # Windows-side portproxy/firewall/logon reconciliation only

[data.remote_access.ssh]
enabled = true
login_keys = ["id_phone", "id_laptop"]
```

With `wsl.enabled` absent or false, the WSL arm degrades to a WARN naming the
manual action instead of touching the distro.

## 10. `dot remote tunnel render` and `tunnel validate`

`tunnel render` writes the machine-local cloudflared `config.yml` from
`[data.remote_access.tunnel]`: one ingress pair per declared
hostname/service, the terminal `http_status:404` always appended, credentials
referenced by path only. `tunnel validate` parses an existing config: every
`http://` origin must be loopback, the last ingress entry must be
`http_status:404`, and no token material may appear inline.

```yaml
tunnel: <machine-local-tunnel-id>
credentials-file: /home/<user>/.cloudflared/<machine-local-tunnel-id>.json
ingress:
  - hostname: <machine-local-hostname>
    service: http://127.0.0.1:4096
  - service: http_status:404
```

## 11. tmux session persistence

Attach-or-create is the durable pattern; take over a session stuck to a dead
client:

```bash
tmux new-session -A -s main   # attach to "main" or create it
tmux attach -d                # detach other clients and take over
```

The operator guide for durable agent sessions across desk and phone
(canonical keys, handoff, recovery): [Remote Agent Sessions](remote-agent-sessions.md).

`[[data.ssh_hosts]]` entries with `tmux = true` make the Windows Terminal SSH
tab re-attach to session "main" (or a named session) on connect; see
[Secrets & SSH Hosts](secrets.md#ssh-hosts-datassh_hosts) and the
[Tmux Guide](tmux.md).

## 12. Login keys (authoritative local contract)

Each receiving OS declares existing public-key names in its own config:

```toml
[data.remote_access]
enabled = true

[data.remote_access.ssh]
enabled = true
login_keys = ["id_phone", "id_laptop"]

[data.remote_access.rdp]
enabled = true
```

Each name refers to `~/.ssh/<name>.pub`. No private key is required on the
receiving host. There is no key generation, `targets`, or old-schema fallback.
Outgoing Git/server identities and `dot ssh-fingerprints` remain separate.

```sh
dot remote keys status             # read-only comparison
dot remote keys sync               # add declared keys, revoke undeclared keys
dot remote keys remove id_phone    # edit local TOML and reconcile authorization
```

Setup and fix invoke the same reconciliation when SSH provisioning is enabled.
A missing list or invalid/missing desired public file is an error, before any
key change. An explicit `login_keys = []` revokes all authorization entries.
This includes manually installed keys: there is no unmanaged-key exception.
Existing restrictions/options on retained identities survive, and changing a
comment does not create duplicate authorization.

Windows administrator accounts use the shared
`%ProgramData%/ssh/administrators_authorized_keys`; other Windows accounts and
Unix hosts use the login user's `~/.ssh/authorized_keys`. The administrator
contract governs that entire shared file. Setup, status and hardening select
the same file. Custom SSH authorization routing must be reviewed explicitly.

Before replacement, the writer keeps a `.remote-backup-<unique-id>` beside the
original file. Removal validates the remaining list even when the removed key's
public file is gone. It updates TOML as well as authorization so fix cannot add
the key back. Sync binds its effective key list to a local configuration snapshot
and rechecks it before replacement. Concurrent edits are rejected. A failed
removal attempts to restore both files when their contents still match this
operation's writes; external edits are preserved and partial recovery is reported
with both backup paths. This is not a cross-file atomic transaction. Retain the backups until client login
has been verified. Source key files and agent identities are never deleted.
Revocation affects new logins, not established sessions.

Migration: remove the old `[[data.remote_access.login_keys]]` tables and
OS-specific SSH/RDP toggles; add the sections above. Run status, then explicitly
sync/setup, and verify login from another device before key-only hardening.
For cm03, use `login_keys = ["id_newcmelgar"]` and keep direct WSL incoming access
disabled. Another distro may opt into its own local configuration; Windows
forwarding does not install keys or enable that distro's SSH daemon.

## 13. SSH host aliases

Placeholders only — real values live in the machine-local chezmoi.toml and
render into `~/.ssh/config` on apply (see
[Config Example](chezmoi.toml.example)):

```toml
[[data.ssh_hosts]]
  name     = "dev-win"
  hostname = "<windows-tailscale-ip-or-magicdns>"
  user     = "<account>"
  identity = "id_<machine-local-key-name>"
  os       = "windows"

[[data.ssh_hosts]]
  name     = "dev-wsl"
  hostname = "<windows-tailscale-ip-or-magicdns>"
  port     = 2222                       # the WSL portproxy on the Windows host
  user     = "<account>"
  identity = "id_<machine-local-key-name>"
  tmux     = true
```

`dev-win` reaches **Windows :22**; `dev-wsl` rides the Windows portproxy at
**WSL :2222**, never the WSL IP directly.

## 14. GUI paths

| Capability | Port | Scope |
|---|---|---|
| Windows Remote Desktop | 3389 | Tailscale-scoped rule (`RemoteDesktop-Tailscale`) + ACLs |
| Linux xrdp | 3389 | desktop-detected hosts only (`rdp.enabled`); same tailnet scope |
| macOS Screen Sharing (VNC) | 5900 | recovery only; manual enable; over the tailnet |

RDP is for GUI work or WSL recovery; prefer SSH + tmux otherwise. Use a
normal account; for rare UAC work use a local RDP session, never
Administrator SSH or agent forwarding.

## 15. Elevation

Interactive, passworded `sudo` on Unix; user-scope installs on Windows where
possible. Never root or Administrator SSH, generic `NOPASSWD`, or agent
forwarding.

## 16. Operations

Keep credentials and keys machine-local. Rotate dedicated login keys, review
tailnet ACLs and service logs, revoke vendor remote sessions, and check that
unattended hosts still have their expected power, network, disk, and recovery
path. Remove Tailscale Serve mappings and Cloudflare hostname ingress when
they are no longer needed.
