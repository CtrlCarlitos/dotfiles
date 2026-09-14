# Remote Access

## 1. Scope and non-goals

This guide describes manual, machine-local setup after installing the optional
package groups. Keep development-agent backends private: use a tailnet or a
local console, never a public route.
No Caddy, code-server, Tailscale Funnel, or public agent backends.
Do not provide an external route to an agent backend.

Identities, credentials, tunnel definitions, SSH keys, and tailnet ACL values
belong on the machine or in the provider dashboard, never in this repository.

## 2. Install-only package groups

`remote_access` installs only the Tailscale and cloudflared clients. It never
signs in, creates tunnels, changes service state, or stores credentials.

`remote_access_server` installs only OpenSSH server prerequisites. It never
enables a server, opens a firewall, writes SSH configuration or keys, or creates
a portproxy. Selecting either group is not remote-access configuration.

## 3. Private OpenCode

Run OpenCode only on loopback and protect it with a machine-local password.

**Manual, machine-local action:** start the private listener in the terminal
where its password is available locally.

```bash
OPENCODE_SERVER_PASSWORD='<machine-local secret>' opencode web --hostname 127.0.0.1 --port 4096
```

**Warning, manual machine-local exposure action:** after authenticating this
machine to the tailnet, map the loopback listener with Tailscale Serve. Review
the tailnet ACL before making it reachable.

```bash
tailscale serve --https=443 http://127.0.0.1:4096
```

Open the machine's tailnet HTTPS name from an authorized device. Do not publish
the listener. **Warning, manual machine-local exposure action:** to remove the
mapping, run `tailscale serve off` on that machine.

## 4. Native phone and browser agent paths

Use each vendor's authenticated remote-control path rather than exposing its
backend:

- **Claude Remote Control:** pair and approve the device through Claude's
  native remote-control flow.
- **Codex Remote:** use the paired Mac or Windows ChatGPT desktop bridge; keep
  its pairing and account state on those devices.
- **Antigravity Remote Control:** use the session-scoped remote-control flow
  and revoke the session when it is no longer needed.
- **Universal fallback:** run work in tmux and connect through private SSH.

These are manual, machine-local choices. Vendor pairing, tokens, and session
approvals must not be copied into dotfiles or shared configuration.

## 5. Approved external app sharing

Share only an approved non-agent web application through Cloudflare Access. Use
one Access application per approved app, send cloudflared directly to that
app's loopback origin, and end every ingress list with `http_status:404`.

**Manual, machine-local tunnel lifecycle action:** create the tunnel and its
credentials through the provider's login flow on the host. Keep the resulting
credential file local.

```bash
cloudflared tunnel login
cloudflared tunnel create <approved-app>
```

**Warning, manual machine-local exposure action:** create the local tunnel
configuration with a loopback origin for the approved app only.

```yaml
tunnel: <machine-local-tunnel-id>
credentials-file: /home/<user>/.cloudflared/<machine-local-tunnel-id>.json
ingress:
  - hostname: <approved-app.example.com>
    service: http://127.0.0.1:<approved-app-port>
  - service: http_status:404
```

**Warning, manual machine-local exposure action:** create a separate Cloudflare
Access application and allow policy for that app. Keep its identities, policy
values, and tunnel credentials in the dashboard or on the host. This workflow
is never for an agent execution backend.

## 6. SSH key boundaries

Git authentication keys, Git signing keys, and `allowed_signers` files are not
login keys. Create a dedicated, passphrase-protected SSH key pair for each
device and target account. Keep private keys on the source device and add only
the matching public key to the target account's local `authorized_keys` file.

**Warning, manual machine-local authorized_keys action:** verify the target
account and public-key fingerprint before adding it; never reuse a Git or
signing key.

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_<device>_access.pub <account>@<tailnet-host>
```

## 7. Linux setup

Use a non-root account, a reviewed Tailscale SSH policy, and tmux for durable
sessions. Test changes from a second terminal before ending the current SSH
session.

**Warning, manual machine-local service action:** enable and check the SSH
daemon only after placing the dedicated public key and reviewing the tailnet
ACL that limits access.

```bash
sudo systemctl enable --now ssh
sudo systemctl status ssh --no-pager
tmux new -s work
```

Keep normal elevation interactive with passworded `sudo`; do not permit root
SSH or generic `NOPASSWD` rules.

## 8. Windows setup

Use **Windows :22** for Windows administration. Configure key-only OpenSSH.
The Windows firewall limits inbound traffic to the Tailscale interface and
tailnet address space; Tailscale ACLs select approved identities and ports. Use
RDP **:3389** only for GUI work or WSL recovery.

**Warning, manual machine-local service, firewall, and SSH-configuration
action:** confirm a dedicated public key works before disabling password login
or changing the firewall. Apply these commands in an elevated local PowerShell
session, not through an unattended installer.

```powershell
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
New-NetFirewallRule -Name OpenSSH-Tailscale -DisplayName 'OpenSSH via Tailscale' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -InterfaceAlias Tailscale -RemoteAddress <tailnet-address-space>
notepad $env:ProgramData\ssh\sshd_config
```

Use a normal Windows account. For rare UAC work, use a local RDP session rather
than Administrator SSH or agent forwarding.

## 9. WSL setup

Keep Tailscale on Windows only. Reach WSL sshd through a Windows Tailscale-IP
portproxy at **WSL :2222**. The Windows firewall limits traffic to its
Tailscale interface and address space; Tailscale ACLs select approved
identities and ports. Reconcile the portproxy when WSL reboots or its IP
changes.

**Warning, manual machine-local service, SSH-configuration, and portproxy
action:** first configure WSL sshd for dedicated-key authentication, then obtain
the current WSL IP and create the Windows-side mapping. Re-check it after every
reboot or address change.

```bash
sudo systemctl enable --now ssh
sudoedit /etc/ssh/sshd_config
hostname -I
```

```powershell
netsh interface portproxy add v4tov4 listenaddress=<windows-tailscale-ip> listenport=2222 connectaddress=<current-wsl-ip> connectport=22
New-NetFirewallRule -Name WSL-SSH-Tailscale -DisplayName 'WSL SSH via Tailscale' -Direction Inbound -Protocol TCP -LocalPort 2222 -Action Allow -InterfaceAlias Tailscale -RemoteAddress <tailnet-address-space>
```

## 10. macOS setup

Use the Tailscale app with Apple Remote Login/OpenSSH, dedicated login keys,
and VS Code Remote-SSH. Use Screen Sharing only for recovery.

**Warning, manual machine-local service and authorized_keys action:** enable
Remote Login only after reviewing its allowed users and installing a dedicated
public key for the target account.

```bash
sudo systemsetup -setremotelogin on
mkdir -p ~/.ssh && chmod 700 ~/.ssh
```

## 11. Elevation

Use interactive, passworded `sudo` on Unix. Use user-scope installs on Windows
where possible and RDP for rare Windows UAC. Never use root or Administrator
SSH, generic `NOPASSWD`, or agent forwarding.

## 12. Operations

Keep credentials and keys machine-local. Rotate dedicated login keys, review
tailnet ACLs and service logs, revoke vendor remote sessions, and regularly
check that unattended hosts still have their expected power, network, disk,
and recovery path. **Warning, manual machine-local exposure lifecycle action:**
remove Tailscale Serve mappings and external-app tunnels when they are no
longer needed.
