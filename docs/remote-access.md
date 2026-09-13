# Remote Access (Phone + Sharing)

Reach your dev machine's OpenCode web UI from your phone, and share a running
session with a collaborator or student — without opening a single router port.

There are two paths, and they serve different people:

## Architecture (two paths, one service)

| Path | Tool | Who | Auth |
|-----|------|-----|------|
| Personal | Tailscale | You (phone) | WireGuard device identity |
| Sharing | Cloudflare Tunnel + Access | Collaborators/students | Email OTP |

Both paths point at the same thing: `opencode web` listening on `localhost:4096`.
Nothing is ever exposed directly — each path terminates an encrypted tunnel in
front of it.

- **Tailscale** is your private tailnet: every device you sign in on can reach
  every other, authenticated by device identity (WireGuard keys). Zero config,
  zero ports, zero DNS.
- **Cloudflare Tunnel** is for people you *don't* want on your tailnet: an
  outbound-only tunnel from your machine to Cloudflare's edge, with an Access
  policy (email OTP) deciding who may pass. Free tier: 50 users, $0 forever.

The two are completely independent — `tailscaled` and `cloudflared` don't know
about each other, and running both is safe.

---

## Setup: Tailscale (personal phone access)

### Desktop (one-time)

```bash
# Install (this repo's dev_desktop group already does this on Linux/macOS/
# Windows - run manually only if you skipped that group)
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate (opens a browser to sign in to your tailnet)
sudo tailscale up

# Enable Tailscale SSH (optional but recommended - lets you shell in from
# the phone without managing host SSH keys)
sudo tailscale set --ssh
```

> **Note:** `tailscale up --ssh` is deprecated — use `tailscale set --ssh`.

### Phone (one-time)

1. Install the Tailscale app (iOS: App Store, Android: Play Store).
2. Sign in with the **same account** as the desktop (Google/GitHub/etc).
3. Toggle the VPN on. That's it — your phone is now on the tailnet.

### Expose OpenCode web

```bash
# Start OpenCode web (ALWAYS with a password - see Security notes)
OPENCODE_SERVER_PASSWORD=<secret> opencode web --port 4096

# Serve it over HTTPS on your tailnet (--bg = background + persist across reboots)
sudo tailscale serve --bg 4096

# Find your hostname
tailscale status
# or, machine-readable:
tailscale status --json | jq -r '.Self.DNSName'
```

Open `https://<machine>.<tailnet>.ts.net` on the phone, sign in to the
tailnet's VPN, enter the OpenCode password — done. Tailscale's serve proxy
gives you a valid HTTPS certificate automatically.

To stop serving:

```bash
sudo tailscale serve off
```

---

## Setup: Cloudflare Tunnel (sharing with third parties)

Use this when a collaborator or student needs to watch or join a session and
is *not* on your tailnet. **Named tunnels only** — Quick Tunnels
(`trycloudflare.com`) don't support SSE, which OpenCode's UI needs.

### Prerequisites

- A domain on Cloudflare (any plan, free works).
- `cloudflared` installed — this repo's `dev_desktop` group installs it
  (verified version at time of writing: 2026.9.1).

### Desktop (one-time)

```bash
# 1. Log in - opens a browser; pick your domain
cloudflared tunnel login

# 2. Create a named tunnel
cloudflared tunnel create ai-dev
#    Note the TUNNEL_ID it prints - you need it for the config below.

# 3. Route DNS (CNAME) for the hostname you want
cloudflared tunnel route dns ai-dev dev.yourdomain.com
```

Create `~/.cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /home/<user>/.cloudflared/<TUNNEL_ID>.json
ingress:
  - hostname: dev.yourdomain.com
    service: http://localhost:4096
  - service: http_status:404
```

Run it (foreground, for testing):

```bash
cloudflared tunnel run ai-dev
```

Or as a boot-persistent service:

```bash
sudo cloudflared service install
sudo systemctl enable cloudflared
```

### Cloudflare dashboard (Access policy)

**Always** put an Access policy in front of the tunnel URL — without one,
anyone who guesses the hostname gets in.

1. Zero Trust dashboard → **Access controls → Applications → Create new
   application → Self-hosted and private** → **Add public hostname** →
   `dev.yourdomain.com`.
   (Heads-up: the old `/policies/access/` URL path 404s now; the current
   path is `/access-controls/`.)
2. **Policies → Add a policy** → Action: **Allow** → Include: **Emails** →
   add your collaborator's/student's address.
3. They'll get a one-time PIN by email at each visit (email OTP).

Free tier covers 50 users at $0 forever.

### Sharing a session

```bash
# Desktop: start the service + web UI
OPENCODE_SERVER_PASSWORD=<secret> opencode web --port 4096
cloudflared tunnel run ai-dev   # or rely on the systemd service
```

Send the collaborator `https://dev.yourdomain.com` + the OpenCode password
through separate channels. They authenticate twice: email OTP (Cloudflare
Access), then the OpenCode password.

---

## Security notes

- **ALWAYS set `OPENCODE_SERVER_PASSWORD`** — OpenCode's docs warn explicitly
  about unsecured servers; without it anyone reaching the port owns the
  session (files, shell, agent).
- **Use named tunnels, never Quick Tunnels** (`trycloudflare.com`) — they
  don't support SSE, and the random URLs are public with zero auth.
- **Always put an Access policy in front of a tunnel URL** — the tunnel
  encrypts transport; Access decides who may use it.
- **Prefer HTTPS serve** (`tailscale serve`, not `--http`) — OpenCode issue
  [#47645](https://github.com/anomalyco/opencode/issues/47645) shows
  `crypto.subtle` breaks file attachments on plain-HTTP remote hosts.
- `cloudflared` and `tailscaled` are independent — running both is safe.
- Known issue: SSE bug in OpenCode 1.18.25, tracked as
  [#46733](https://github.com/anomalyco/opencode/issues/46733) — if the web
  UI stalls/streams oddly, this is likely it, not your tunnel.

---

## Quick reference

| Action | Command |
|--------|---------|
| Tailscale auth | `sudo tailscale up` |
| Tailscale SSH | `sudo tailscale set --ssh` |
| Serve port 4096 (persistent) | `sudo tailscale serve --bg 4096` |
| Stop serving | `sudo tailscale serve off` |
| My tailnet hostname | `tailscale status --json \| jq -r '.Self.DNSName'` |
| Phone URL | `https://<machine>.<tailnet>.ts.net` |
| Cloudflare login | `cloudflared tunnel login` |
| Create tunnel | `cloudflared tunnel create ai-dev` |
| Route DNS | `cloudflared tunnel route dns ai-dev dev.yourdomain.com` |
| Run tunnel | `cloudflared tunnel run ai-dev` |
| Install as service | `sudo cloudflared service install && sudo systemctl enable cloudflared` |
| Start OpenCode web | `OPENCODE_SERVER_PASSWORD=<secret> opencode web --port 4096` |

---

## Why Tailscale AND Cloudflare Tunnel (not either/or)

The two tools answer different questions. **Tailscale is for you** (personal
phone/laptop access — WireGuard mesh, zero public surface, carries SSH and
everything else). **Cloudflare Tunnel is for them** (students, collaborators —
browser-only, email-verified, no VPN client to install). Running both is safe:
`tailscaled` and `cloudflared` are independent outbound daemons with no port
conflicts or routing overlap.

```
phone/laptop ── tailscale ──▶ desktop          (private: SSH, opencode web, everything)
students     ── browser ──▶ CF Access ──▶ cloudflared ──▶ opencode web :4096
```

### Comparison

| Dimension | Tailscale (personal) | Cloudflare Tunnel + Access (sharing) |
|---|---|---|
| Client needed | Tailscale app | Browser only |
| Transport | WireGuard mesh, p2p direct when possible | Cloudflare edge relay (335+ cities) |
| Attack surface | Nothing public | Public URL; safe only with Access policy |
| Auth model | Device identity (WireGuard keys) | Email OTP / GitHub / Google identity |
| Sharing granularity | Per-machine, quarantined, port-scoped ACLs | Per-app, up to 1,000 emails per rule |
| Free tier | 6 users, 100 devices | 50 Zero Trust users, unlimited tunnels |
| Non-HTTP protocols | Any IP protocol (SSH, VNC) | HTTP/WSS primarily |
| Latency | Lowest (direct p2p when UDP works) | Always edge-relayed (excellent, not p2p) |

### Why not code-server?

`opencode web` is already touch-native (designed for phone browsers);
code-server costs ~1 GB RAM / 2 vCPU, uses single-password auth (2
logins/min rate limit, not multi-tenant), and VS Code's desktop UI isn't
touch-optimized. Adopt only if you need VS Code extensions or Open-VSX.

### Why not a reverse proxy (Caddy/Traefik/nginx)?

TLS termination, auth middleware, and routing are already handled by
Tailscale serve (auto-TLS) and Cloudflare Tunnel + Access (edge TLS +
email OTP). A proxy adds a daemon to maintain, risks breaking OpenCode's
SSE streaming (buffering/timeout misconfiguration), and solves a problem
that doesn't exist at 1-3 services. Add Caddy later if you hit 5+ web
services on one hostname.

### Third-party sharing decision tree

- **"Watch my coding session" (read-only)** → `opencode share` command
  (zero infrastructure, public `opncd.ai/s/<id>` link) or Tailscale Funnel
  (live but unauthenticated, bandwidth-capped)
- **"Give my student interactive access"** → Cloudflare Tunnel + Access
  (they verify email, get a browser session — no install, no VPN)
- **"Give my collaborator SSH/terminal access"** → Tailscale device sharing
  (they install Tailscale, get quarantined access to one machine with
  port-scoped ACLs — best isolation)
- **Never** expose a bare tunnel URL without an Access policy —
  `opencode web`'s only native auth is one shared password

### Sources

- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
- [Cloudflare Access policies](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/)
- [Tailscale Funnel](https://tailscale.com/kb/1223/tailscale-funnel)
- [Tailscale device sharing](https://tailscale.com/kb/1084/sharing-tailnet-machines)
- [Tailscale pricing](https://tailscale.com/pricing)
- [code-server](https://github.com/coder/code-server)
- [OpenCode web](https://opencode.ai/docs/web/)
