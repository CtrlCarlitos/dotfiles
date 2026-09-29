# Remote Agent Sessions — the operator guide

One durable session, any screen. Start an agent at your desk, walk away,
reconnect from a phone, then take the same session back at the computer —
without killing anything and without re-learning keys.

**The one rule: the session is the workspace; every screen is disposable.**

## 5-minute quick start

| Where | Command |
|---|---|
| Windows (psmux) | open the **psmux** Terminal profile, or `psmux` in any tab |
| WSL/Linux/macOS (tmux) | `tmux new -A -s main` |
| Back at any machine | same commands — they attach to the running session |

Run your agent inside it (`opencode`, `claude`, `codex`), detach (`Ctrl+a` then
`d`), and the agent keeps running. Reattach later from anywhere.

## The mental model

```
coding agent / shell
        |
   tmux or psmux        <- the durable workspace
        |
 SSH / local terminal   <- disposable view
        +-- desktop/laptop
        +-- Android phone/tablet
        +-- iPhone/iPad
```

A disconnect, a dead battery, or a closed app only kills the *view*. The agent
keeps running until you actually exit it or the machine reboots.

## Your keybindings (canonical)

These dotfiles configure **`Ctrl+a` as the prefix — not stock tmux's `Ctrl+b`.**
If a tutorial says `Ctrl+b`, substitute `Ctrl+a`. Press the prefix, release,
then press the action key. Identical in tmux and psmux:

| Action | Binding |
|---|---|
| Prefix | `Ctrl+a` |
| Send a literal Ctrl+A | `Ctrl+a`, `Ctrl+a` |
| Detach (agent keeps running) | `Ctrl+a`, `d` |
| New window | `Ctrl+a`, `c` |
| Next / previous window | `Ctrl+a`, `n` / `p` |
| Switch windows (no prefix) | `Shift+←` / `Shift+→` |
| Swap window (no prefix) | `Ctrl+Shift+←` / `Ctrl+Shift+→` |
| Split side-by-side | `Ctrl+a`, `\|` |
| Split top/bottom | `Ctrl+a`, `-` |
| Navigate panes | `Ctrl+a`, `h`/`j`/`k`/`l` |
| Resize pane | `Ctrl+a`, `H`/`J`/`K`/`L` |
| Copy mode (scroll) | `Ctrl+a`, `[` — then `v` select, `y` yank |
| Reload config | `Ctrl+a`, `r` |
| List keybindings | `Ctrl+a`, `?` |

`tests/psmux_contract.sh` asserts these shared bindings in both configs, so the
two multiplexers cannot drift. Where a key genuinely differs, it is listed in
[Troubleshooting](#troubleshooting-and-recovery).

## Session layout policy

Simple convention, favoring small screens:

- **session = project/repository** (e.g. `tmux new -A -s dotfiles`)
- **window = one agent or process** (`1: shell`, `2: opencode`, `3: codex`, `4: tests`)
- **panes** only when a side-by-side genuinely helps — phones are too small for
  busy splits

Windows-over-panes is the mobile-friendly shape: switching windows is one
prefix action; panes need navigation and eat screen space.

## Desktop → phone → desktop

1. **At the desk:** start the project session, run the agent inside it.
2. **Leaving:** `Ctrl+a`, `d` (detach). Or just walk away — closing the laptop
   app only closes the view. The Tailscale tunnel roams Wi-Fi → cellular
   without dropping the session.
3. **On the phone:** connect over Tailscale + SSH (Tailscale gives the device
   a private address; your SSH keys authorize it — see
   [Remote access](remote-access.md)). Then attach:
   - WSL/Linux/macOS host: `tmux attach -t main` (or `tmux new -A -s main`)
   - Windows host: `psmux attach -t default` (or just `psmux`)
4. **Back at the desk:** run the same attach command locally. Two clients can
   share a session (both see the same view; the layout follows the smallest
   screen — expect big fonts on the desktop while the phone is attached).
   To take the screen back exclusively:
   - tmux: `tmux attach -d -t main`
   - psmux: `psmux detach-client -a` (after attaching)

## Android

| Client | Why | Watch out |
|---|---|---|
| **Termius** | mature cross-platform baseline; virtual key row (Ctrl/Esc/Tab/arrows), gestures, port forwarding, multi-session | proprietary; subscription gates some extras |
| **TermRover** | purpose-built tmux client: session picker, one-tap prefix actions, quick Esc/Tab/Ctrl row, touch scrollback, voice prompts | much newer and smaller install base — validate before standardizing |
| **ConnectBot** | open-source minimal fallback | bare-bones key entry; keep as reference |

Setup (any client): add host `<machine>` over SSH with your Tailscale address
(or MagicDNS name), your key, then the attach command above.

## iPhone / iPad

| Client | Why | Watch out |
|---|---|---|
| **Blink Shell** | strongest iOS terminal: SSH + Mosh, on-screen Smart Keys (Ctrl/Alt/Esc/arrows), startup commands (put the attach command there) | Apple-only; paid |
| **Termius** | the same cross-platform baseline as Android | same caveats |
| **TermRover** | tmux-first touch UX, if the Android validation goes well | young |

## Touch-only usage (no Ctrl key)

Every recommended client solves "no Ctrl" with a key row or one-tap actions:

- **Prefix:** tap the client's Ctrl key, tap `a` — or TermRover's one-tap
  prefix button.
- **Esc / Tab / arrows:** the quick row; Esc must reach the agent instantly
  (this repo sets `escape-time 0` in both multiplexers precisely for this).
- **Splits on touch:** `Ctrl`-row + `|` or `-`; prefer *windows* over panes
  (one `Ctrl+a`, `c` beats fiddly splits).
- **Copy/paste:** enter copy mode (`Ctrl+a`, `[`), `v`/`y` — where the yank
  lands on a phone depends on the client's OSC 52 support; **test this first**
  (see the matrix below). Client-side selection/copy is the fallback.
- **Long prompts / dictation:** TermRover offers voice composition; every
  keyboard app's dictation works into the terminal input.

## Client test matrix (do this on real devices)

For each candidate (Termius, TermRover, Blink; ConnectBot as control):

- [ ] attach to a running session over Tailscale SSH
- [ ] prefix works; detach works; reattach works
- [ ] window switch, pane navigate, scrollback
- [ ] copy: `Ctrl+a`, `[`, `v`, `y` — where does the yank land?
- [ ] Esc reaches the agent instantly; `Ctrl+C` interrupts
- [ ] Enter / multiline input (in an agent: Shift+Enter or `Ctrl+J`)
- [ ] no key silently intercepted by the app
- [ ] app killed → agent survives; reattach works
- [ ] Wi-Fi → cellular mid-session; screen lock mid-session
- [ ] phone rotation / small screen: layout shrinks, desktop unaffected after
      exclusive reattach

Record the outcome per client in this issue; the first client that passes the
whole matrix on both platforms becomes the documented default.

## Troubleshooting and recovery

- **SSH died / app killed:** the session never noticed. Reattach.
- **"no session" on reattach:** `tmux ls` / `psmux ls` on the *host* lists
  what exists; attach by the listed name. A reboot empties the list — agents
  must be restarted (sessions are not persisted across reboots; there is no
  resurrect/continuum equivalent on psmux).
- **Layout went tiny on the desktop:** a small client is (or was) attached.
  Take over exclusively: `tmux attach -d -t main` / `psmux detach-client -a`.
  Optionally reapply a layout: `Ctrl+a`, `Space` cycles presets.
- **Prefix does nothing:** you are probably at the bare shell prompt, not
  inside the multiplexer — attach first.
- **Stuck view:** `Ctrl+a`, `d` detaches you cleanly; the session keeps
  running either way.

## Agent notes inside sessions

- **Newline in agents:** `Ctrl+J` is the universal newline — inside psmux it
  is the *reliable* one (psmux does not implement win32-input-mode, so
  `Shift+Enter` can arrive as a bare Enter and submit).
- **Esc is instant:** `escape-time 0` is set in both multiplexers.
- **OpenCode clipboard:** highlight-copies inside the TUI; `Ctrl+V` or
  Shift+right-click pastes (see [Terminal Experience](terminal.md#clipboard)).
- **Mouse:** the multiplexer owns the mouse; `Shift+drag` hands it back to the
  outer terminal for native selection.

## Related

- [Remote access](remote-access.md) — Tailscale/SSH plumbing and `dot remote`
- [Tmux Guide](tmux.md) — beginner tmux walkthrough
- [Terminal Experience](terminal.md) — the local terminal half
- Issue #188 — the battle-proofing checklist this guide implements
