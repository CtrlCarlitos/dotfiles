# 🖥️ Terminal Experience

One look and one set of keys across every place you type commands: Windows
Terminal, the VS Code integrated terminal, WSL, and SSH sessions to Mac and Linux
hosts. Colors are **Catppuccin Mocha** everywhere, and the font is
**MesloLGS Nerd Font Mono**.

## Where it lives

| Surface | Managed by | How |
|---|---|---|
| Windows Terminal | `AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/modify_settings.json` | modify-template: merges into `settings.json` |
| Ghostty (macOS, Linux desktop) | `dot_config/ghostty/config.tmpl` | owned file (Ghostty never rewrites it) |
| VS Code terminal: settings | `run_onchange_install_packages.{ps1,sh}.tmpl` | installer VS Code step, see [VS Code](vscode.md) |
| VS Code terminal: keys | `.chezmoitemplates/vscode-keybindings.json`, via `modify_keybindings.json` in `AppData/Roaming/Code/User` (Windows), `Library/Application Support/Code/User` (macOS), `dot_config/Code/User` (Linux desktop) | modify-template: merges into `keybindings.json`, only where VS Code's User folder exists |
| OpenCode theme | `dot_config/opencode/modify_tui.json` | modify-template: merges into `~/.config/opencode/tui.json` |
| Same-folder splits | `Documents/PowerShell/…profile.ps1`, `dot_zshrc` | the shell reports its folder (OSC 9;9) |
| Clipboard over SSH | `dot_tmux.conf`, `dot_config/nvim/init.lua` | OSC 52 |

**Merge, not own.** Windows Terminal, VS Code and OpenCode all rewrite their own
settings files (from their Settings UI, or when they detect new profiles). If
chezmoi owned those files, every apply would stop at "changed since chezmoi last
wrote it". So the templates read the current file and force only their own keys:

- Anything the template sets (colors, font, the keys below) wins on the next apply.
  Change those in the template, not the UI.
- Everything else (your UI changes, profiles Terminal generates for VS or a new WSL
  distro) is kept.
- All three are plain JSON on output; comment lines and trailing commas in the
  current file are tolerated where the app itself writes them.

## Platform parity

✅ managed · ➖ not applicable · ⚠️ not managed

| Feature | Windows | WSL | Linux | macOS |
|---|---|---|---|---|
| Terminal app look (colors, font) | ✅ Windows Terminal | ✅ (a Windows Terminal tab) | ✅ Ghostty | ✅ Ghostty |
| Terminal app: highlight copies, right-click pastes | ✅ | ✅ | ✅ Ghostty | ✅ Ghostty |
| Terminal app: pane keys, agent keys, drop-down window | ✅ | ✅ | ✅ Ghostty (drop-down: not on GNOME) | ✅ Ghostty |
| VS Code terminal: colors, font, clipboard, `Ctrl+B`/`J` | ✅ | ✅ (Windows VS Code) | ✅ | ✅ |
| VS Code agent keys | ✅ | ✅ (Windows VS Code) | ✅ desktop | ✅ |
| VS Code Shift+Enter | ✅ win32-input-mode | ✅ (Windows VS Code) | ✅ kitty protocol (default) | ✅ kitty protocol (default) |
| Agent keys in the terminal app | ✅ pwsh, Windows PowerShell | ✅ zsh | ✅ Ghostty, and over SSH | ✅ Ghostty, and over SSH |
| Splits open in the same folder | ✅ pwsh + 5.1 (OSC 9;9) | ✅ zsh (OSC 9;9) | ✅ Ghostty shell integration | ✅ Ghostty shell integration |
| OpenCode Catppuccin theme | ✅ | ✅ | ✅ | ✅ |
| tmux `y` → local clipboard | ➖ | ✅ `clip.exe` | ✅ `xclip` (X) / `wl-copy` (Wayland) | ✅ `pbcopy` |
| tmux / Neovim copy over SSH → your clipboard | ➖ | ✅ OSC 52 | ✅ OSC 52 | ✅ OSC 52 |
| Neovim system clipboard | ✅ | ✅ | ✅ | ✅ |
| Shell `pbcopy` / `pbpaste` | ➖ | ✅ `clip.exe` | ✅ `xclip` / `wl-copy` | ✅ native |
| SSH host tabs (`ssh_hosts` → profiles) | ✅ | ➖ (Windows side) | ⚠️ | ⚠️ |

**The remaining gap:** SSH host tabs are a Windows Terminal feature. In Ghostty, SSH
from a tab (`ssh <alias>`, the same `~/.ssh/config` aliases).

## Ghostty (macOS and Linux)

Ghostty is the Mac/Linux twin of Windows Terminal. `~/.config/ghostty/config` gives it
the same look and behavior:

- **Look:** built-in `Catppuccin Mocha` theme, the Nerd Font (14pt on macOS, which
  matches 12pt on Windows and Linux on screen), 92% opacity with blur, bar cursor.
- **Clipboard:** `copy-on-select = clipboard`, `right-click-action = paste`.
  Shift+right-click pastes in OpenCode.
- **Keys:** the pane keys and agent keys in the tables below, including the split
  variants (chained keybinds, Ghostty 1.3+).
- **Drop-down window:** `toggle_quick_terminal`, on `Super+`` ` on Linux (like
  ``Win+` ``) and `Ctrl+Option+`` ` on macOS (`Cmd+`` ` cycles windows there, and
  `Ctrl+`` ` is VS Code's terminal toggle). macOS asks for Accessibility permission.
  On Linux it needs a compositor with `wlr-layer-shell` (KDE, Hyprland, Sway; not GNOME).
- **SSH:** `shell-integration-features = ssh-terminfo,ssh-env` copies Ghostty's
  terminfo to a host the first time, falling back to `xterm-256color`, so backspace,
  colors and tmux behave on remote machines. tmux knows `xterm-ghostty` supports 24-bit color.

**Installing it:** Ghostty is part of the opt-in `dev_desktop` group, and only
through the platform's package manager (no snap, no third-party repos):

- **macOS:** Homebrew cask.
- **Linux:** `apt install ghostty` where the release has it: Ubuntu 26.04+ ships
  1.3.0 in `universe`. Ubuntu 24.04 doesn't, so the installer skips it with a pointer
  to the [install page](https://ghostty.org/docs/install/binary).

The config is deployed either way and does nothing until Ghostty is installed.

**Using it is your choice.** Nothing sets Ghostty as the default terminal. Keep
Terminal.app, GNOME Terminal or iTerm2 if you prefer; the shell side (prompt,
tmux/Neovim clipboard, agent CLIs) behaves the same in any of them. To make Ghostty the
default: on macOS, open it instead of Terminal (macOS has no system-wide default
terminal); on Linux, set it in your desktop's default-applications settings, or
`sudo update-alternatives --config x-terminal-emulator` on Debian/Ubuntu once it's
registered there.

## Local vs remote: who controls what

When a Windows Terminal (or Ghostty) tab connects to WSL or SSHes into a host, two
machines share the job. **The app you're looking at is always local**; **everything
running inside the tab comes from the other side.**

| Comes from your local terminal app | Comes from WSL / the remote host |
|---|---|
| Font, font size, opacity, cursor | The prompt (zsh + starship config on that machine) |
| The 16 ANSI colors (Catppuccin Mocha palette) | Aliases, shell history, `PATH` |
| Tab colors, SSH tabs, window and pane layout | tmux (its config, status bar, sessions) |
| Keys: panes, drop-down, agent keys (they type text) | Which agent CLIs exist, and their settings (e.g. OpenCode's theme) |
| Highlight-to-copy and right-click paste | Neovim config and colorscheme; delta's syntax theme |
| Accepting OSC 52 copies into your clipboard | Sending OSC 52 (tmux `set-clipboard`, Neovim over `$SSH_TTY`) |

The practical consequences:

- **Colors mostly follow you.** Programs that use the 16 ANSI colors (`ls`, git,
  starship's defaults) get your local Catppuccin palette on any host. Programs that
  pick exact 24-bit colors (OpenCode's theme, Neovim's colorscheme, delta) use *that
  host's* config. The same dotfiles on the host keep them Catppuccin too.
- **Clipboard over SSH needs both ends:** the host sends (its tmux/Neovim config),
  your terminal receives. That's why the host needs these dotfiles.
- **Mouse inside tmux or Neovim:** both capture the mouse (`mouse on`,
  `mouse=a`), so a plain drag selects in *them*: tmux copies through OSC 52, and
  Neovim enters visual mode (press `y`). **Shift+drag** hands the mouse back to your
  terminal, so its own highlight-to-copy works.
- **Nothing is pulled from the host's terminal settings.** A Ghostty config on a Mac
  you SSH into is irrelevant while you're in Windows Terminal: that Mac isn't drawing
  anything.

## Windows Terminal

- **Look:** Catppuccin Mocha scheme and tab-row theme, Nerd Font at 12pt, light
  acrylic (92% opacity), bar cursor, visual bell (window flash + taskbar).
- **Tab color per environment:**

  | Color | Environment |
  |---|---|
  | Blue | PowerShell 7 |
  | Orange | Any WSL distro |
  | Yellow | Ubuntu 20.04 (custom profile) |
  | Green | SSH → Mac (`os = "mac"`) |
  | Red | SSH → Linux (`os = "linux"`) |
  | Purple | SSH, no `os` set |

- **WSL profiles are styled by source, not GUID**, so every distro on every machine
  (Ubuntu-24.04, 26.04, or a new one) gets the look automatically. This also fixes
  WSL's own generated profile, which forces `Ubuntu Mono` and breaks starship icons.
- **SSH profiles:** one `SSH: <name>` profile per `[[data.ssh_hosts]]` entry (see
  [Secrets & SSH Hosts](secrets.md#ssh-hosts-datassh_hosts)). Chezmoi owns these:
  remove a host and its tab goes away on the next apply.
  - `os = "mac"` or `"linux"` sets the tab color and icon.
  - `tmux = true` (or a session name) makes the tab run
    `ssh -t <host> "tmux new-session -A -s main"`. Every tab re-attaches to the same
    remote session, so an agent keeps running after a disconnect.

### Keys

| Keys | Action |
|---|---|
| ``Win+` `` | Drop-down (Quake) window, from any app |
| `Alt+Shift+=` / `Alt+Shift+-` | Split pane right / down |
| `Alt+Shift+D` | Split pane, automatic direction |
| `Alt+Arrows` | Move focus between panes |
| `Alt+Shift+Z` | Zoom current pane |
| `Ctrl+Shift+W` | Close pane |
| `Ctrl+Shift+P` | Command palette |
| `Ctrl+Shift+R` | Rename tab |
| `F11` | Full screen |
| `Alt+Enter` | *Unbound* (was full screen), so it reaches the agent CLIs as a newline |

## Windows, tabs and panes

The intended shape: a few long-lived **windows**, each parked on a monitor, each
holding **tabs**, each tab holding **panes**. Three settings make that stick:

| Setting | Value | Why |
|---|---|---|
| `firstWindowPreference` | `persistedWindowLayout` | Restores the last session: `state.json` keeps one entry per window with its tabs, panes **and position** (verified: 5 windows, positions spanning monitors) |
| `windowingBehavior` | `useNew` | Every launch is a new window. `useExisting` would drop each launch into the most recent window as a tab, making a second window impossible to open by hand |
| `centerOnLaunch` | `false` | Centering fights a restored window's saved position |

To target an existing window on purpose: `wt -w 0 new-tab` (or `-w <name>`);
`wt -w new` always makes another window.

**Panes are not clones.** A split runs whatever profile you give it, so one tab can
hold three environments:

```
wt -w new new-tab -p "PowerShell" ; split-pane -H -p "Ubuntu-24.04" ; split-pane -V -p "SSH: mac-studio"
```

`-H` puts the new pane **below**, `-V` puts it **beside**. Each split halves the
focused pane, so `-H` then `-V` gives one full-width pane on top and two side by
side underneath (the tmux `main-horizontal` shape).

### Pane keys

| Keys | Action |
|---|---|
| `Alt+←/→/↑/↓` | Move focus between panes |
| `Alt+Shift+=` / `Alt+Shift+-` | Split right / down (same profile) |
| `Alt+Shift+D` | Split, automatic direction |
| `Alt+Shift+←/→/↑/↓` | Resize the focused pane |
| `Alt+Shift+Z` | Zoom the focused pane to the whole window (toggle) |
| `Ctrl+Shift+W` | Close the pane |

`Alt+Shift+Z` is the one to remember in a multi-pane tab: zoom in to work, zoom out
to watch.

### Tab and window keys

| Keys | Action |
|---|---|
| `Ctrl+Shift+T` | New tab (default profile) |
| `Ctrl+Shift+Space` | New tab, choose the profile |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous tab (in order, not most-recent: `tabSwitcherMode: inOrder`) |
| `Ctrl+Alt+1…9` | Jump straight to tab N — faster than hunting with the mouse |
| `Ctrl+Shift+R` | Rename the current tab (sticks, unlike an app-set title) |
| ``Win+` `` | Drop-down (Quake) window from anywhere |
| `F11` | Full screen (`Alt+Enter` is deliberately unbound; the agent CLIs use it) |

### Worth knowing

| Keys | Action |
|---|---|
| `Ctrl+Shift+P` | Command palette — everything else lives here |
| `Ctrl+Shift+F` | Search the scrollback |
| `Ctrl+Shift+↑/↓`, `Ctrl+Shift+PgUp/PgDn` | Scroll the buffer without touching the mouse |
| `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | Font size up / down / reset, per pane |
| Highlight / right-click | Copy / paste (see [Clipboard](#clipboard)) |

Terminal can also **broadcast input** to every pane in a tab (type once, all panes
receive it). It has no default chord; find it in the command palette as
"Toggle broadcast input". Useful for running the same command on several hosts,
and worth knowing you've enabled it before typing anything destructive.

## Keys inside the agent CLIs

These belong to each CLI, not to the terminal. Checked against the installed builds:
Claude Code 2.1.278, Codex 0.155.1, OpenCode 1.18.31, agy (September 2026).

### New line vs submit

Enter submits in all four. For a new line:

| Tool | New line | Watch out |
|---|---|---|
| Claude Code | `Shift+Enter`, `Ctrl+J` (also `\` then Enter) | `Ctrl+Enter` **sends** the message |
| Codex | `Ctrl+J`; `Shift+Enter` where the terminal passes it | `Ctrl+Enter` is **not bound** by default - see below |
| OpenCode | `Shift+Enter`, `Ctrl+Enter`, `Alt+Enter`, `Ctrl+J` | |
| agy | `Shift+Enter`, `Alt+Enter`, `Ctrl+J` | |

- **`Ctrl+J` works in all four, in every terminal.** It's the safe habit.
- **Windows Terminal** passes `Shift+Enter` to all four. `Alt+Enter` reaches them
  too, because it's unbound here (full screen is `F11`).
- **VS Code terminal:** `Shift+Enter` relies on `terminal.integrated.enableWin32InputMode`
  (Windows, experimental; set by the installer, active after a VS Code reload).
  `Ctrl+J` works because the installer stops VS Code from grabbing it for its panel.
- **Avoid `Ctrl+Enter`**: it's a newline in OpenCode and agy, *sends* in Claude Code,
  and does nothing in Codex until you bind it. Codex is the only one of the four with
  a configurable keymap; add this to `~/.codex/config.toml` to line it up with the
  others (verified accepted by `codex` 0.155.1 - an invalid value is rejected at
  startup with `data did not match any variant of untagged enum KeybindingsSpec`):

  ```toml
  [tui.keymap.editor]
  insert_newline = ["shift-enter", "ctrl-j", "ctrl-enter", "alt-enter"]
  ```

  Key names are lowercase and hyphenated (`ctrl-a`, `shift-enter`, `page-down`), and
  the full action list lives under `tui.keymap.{global,chat,composer,editor,pager,list,agents,approval,vim_*}`.

  **You don't have to add it by hand** - `dot_codex/modify_config.toml` applies this
  binding on every machine. Like Windows Terminal's `settings.json`, the file is
  *merged, not owned*: Codex rewrites it constantly (per-project trust levels, hook
  hashes, model notices), so the template forces that one key and passes every other
  byte through unchanged. Add more forced keys to its `$forced` map.

> [!WARNING]
> **Don't run Claude Code's `/terminal-setup` in VS Code.** It adds a VS Code
> keybinding that turns `Shift+Enter` into Esc+Enter for *every* program in the
> integrated terminal, not just Claude Code. At a PowerShell prompt, Esc clears the
> line, so `Shift+Enter` would wipe what you typed and then run an empty command.
> `enableWin32InputMode` already gets `Shift+Enter` to the agent CLIs without that
> side effect. In Windows Terminal, `/terminal-setup` has nothing to do: Claude Code
> reports `Shift+Enter` as natively supported there. If you already ran it in VS
> Code, delete the `shift+enter` → `workbench.action.terminal.sendSequence` entry
> from VS Code's `keybindings.json`.

### Esc, Esc Esc, and clearing the box

**Use `Ctrl+U` to clear and `Esc` to stop.** `Ctrl+U` clears the prompt in all four
CLIs (verified by hand in each), through the VS Code terminal, Windows Terminal and
Ghostty alike. It is the only chord that does, and it needs no configuration:

| Tool | `Ctrl+U` | `Esc` | `Esc` `Esc` (quickly) | `Ctrl+C` |
|---|---|---|---|---|
| Claude Code | **clears** | interrupts a response | **with text:** clears ("Esc again to clear"); **empty:** opens `/rewind` | clears |
| Codex | **clears** | interrupts | **empty:** "edit previous message" (backtrack) | clears (draft goes to history; `↑` recalls) |
| OpenCode | **clears** | interrupts (press again to confirm) | same interrupt; never clears | clears (on an empty box it starts exiting) |
| agy | **clears** | interrupts | clears (`cli.escape` binds `esc` AND `ctrl+c`) | ⚠️ does **not** clear - interrupt, then exit |

Why not `Ctrl+C`: it clears in three, but agy hard-intercepts it ("the system always
intercepts ctrl+c to interrupt active operations or exit, regardless of how it is
mapped"), so the text survives and you get "press ctrl+c again to exit".

Why not hunt for a free chord: there isn't one. Across the four CLIs every
`Ctrl+<letter>` is taken except `h`, `i`, `m`, `q`, `x` - and `Ctrl+H/I/M` *are*
Backspace/Tab/Enter in the classic encoding, `Ctrl+Q` is flow control (and Quit in
VS Code), and codex uses `ctrl-x` as a chord prefix.

Three details worth knowing:

- **`Ctrl+U` is "delete to line start"**, not "erase everything". With the cursor at
  the end of a single-line prompt they are the same; on a multi-line prompt it may
  clear only the current line. Claude Code's `Ctrl+L` and agy's `Esc` clear the whole
  box. In Claude Code `Ctrl+U` also scrolls half a page **when the box is empty** -
  the editor wins whenever there is text.
- **Stopping**: one `Esc` is enough in Claude Code, Codex and agy; OpenCode asks for a
  second. If the response already finished, a second `Esc` on an empty box opens
  `/rewind` (Claude Code) or backtrack (Codex) - press `Esc` again to back out.
- **Never double-tap `Ctrl+C`** on an empty box: that is the exit path in all four.

## Agent keys (Windows Terminal and VS Code)

| Keys | Action |
|---|---|
| `Ctrl+Alt+C` / `X` / `O` / `A` | Type `claude` / `codex` / `opencode` / `agy` + Enter in the focused pane |
| `Ctrl+Alt+Shift+C` / `X` / `O` / `A` | Same, in a new split to the right, in the same folder |

- They **type the command** rather than launching a program, so one set of keys
  works in pwsh, WSL zsh, and SSH sessions, as long as the tool is installed there.
  If something is running or half-typed in the pane, the text goes into it.
- Splits open in the same folder because PowerShell 7 and Windows PowerShell 5.1
  (`Invoke-Starship-PreCommand`) and
  WSL zsh (`chpwd` hook) report the current folder to Terminal (OSC 9;9). The same
  report makes `Alt+Shift+D` duplicate panes open where you are. VS Code tracks the
  folder itself (`terminal.integrated.splitCwd`).
- All eight appear in Terminal's command palette as "Agent: …".
- `agy` runs your `agy --dangerously-skip-permissions` alias; that's deliberate.
- `Ctrl+Alt` doubles as AltGr on some keyboard layouts. C, X, O and A don't produce
  characters on the Spanish layouts.

## Clipboard

Same in Windows Terminal and the VS Code terminal:

- **Highlight copies.** Selecting text puts it on the clipboard (`copyOnSelect`,
  `terminal.integrated.copyOnSelection`).
- **Right-click pastes** (`terminal.integrated.rightClickBehavior = paste`).
- **OpenCode** keeps its mouse capture, so its mouse wheel and menus work. The
  terminal never sees those clicks, so paste with **Shift+right-click** (Windows
  Terminal; Shift hands the mouse back to the terminal) or `Ctrl+V`. OpenCode copies
  its own selections.
- **Over SSH**, copies inside the remote session reach your local clipboard through
  OSC 52, see [Remote hosts](#remote-ssh-hosts).

## VS Code integrated terminal

Set by the installer's VS Code step (DEFAULTS tier: a value you set yourself wins):

- Catppuccin Mocha terminal colors (`workbench.colorCustomizations`, terminal keys
  only; your editor theme is untouched) and a 16px font (about 12pt).
- **Shift+Enter** (a newline in claude, codex, opencode): on Windows,
  `terminal.integrated.enableWin32InputMode`. CLIs sit behind ConPTY, which only
  passes the Shift key along in that mode. Windows Terminal always uses it, VS Code
  only with this setting (experimental). On Mac and Linux the kitty keyboard
  protocol, on by default, does the job.
- `Ctrl+B` and `Ctrl+J` go to the agent CLIs (background task, newline) instead of
  toggling VS Code's sidebar and panel while the terminal has focus.
- The agent keys and the clipboard behavior above.

## OpenCode

claude, codex and agy draw with the terminal's colors. OpenCode uses its own themes,
so `tui.json` pins `"theme": "catppuccin"`, whose dark variant is Catppuccin Mocha
(checked against OpenCode 1.18). Its `"system"` theme is not used: it asks the
terminal for its palette and silently falls back to OpenCode's own theme when the
terminal doesn't answer. Only the theme is forced; your keybinds stay. OpenCode 1.x
keeps TUI settings in `tui.json`, not `opencode.json`.

## Remote SSH hosts

To make a Mac or Linux host you SSH into feel like your local tabs:

1. **Install the dotfiles on the host** over SSH with the Linux/macOS one-liner in
   the [README](../README.md#-install). Read `install.sh` first; see the ground rules
   in [testing.md](testing.md). Pick the **standard** preset, plus
   `chatgpt_cli` / `antigravity_cli` if you want every agent key to work there.
   Desktop groups skip themselves on a headless server.
   - **On a server you don't own (for example a customer machine):** choose only
     `core` + `modern_cli`, and leave the git account prompts blank. Your identities
     and signing keys don't belong there.
2. **Add the host on Windows** in `~/.config/chezmoi/chezmoi.toml`: a
   `[[data.ssh_hosts]]` entry with `os = "linux"` or `"mac"` and `tmux = true`, then
   `chezmoi apply`.

What you get in its `SSH: <name>` tab:

- **Same prompt and colors:** zsh + starship (it shows the hostname over SSH) in a
  Catppuccin tab.
- **Agent keys** work, because they only type the command.
- **Sessions survive** with `tmux = true`.
- **Clipboard:** copies on the remote side reach Windows through OSC 52. Windows
  Terminal accepts OSC 52 writes, as do iTerm2, Ghostty, WezTerm and kitty.
  - **tmux:** `set -s set-clipboard on` forwards every copy (`y` in copy mode, mouse
    drag). Locally, `y` also pipes to the OS tool: `clip.exe` (WSL), `pbcopy` (macOS),
    `wl-copy` (Wayland), or `xclip` (only with a real X display; on a headless host it
    exists but fails).
  - **Neovim:** when `$SSH_TTY` is set, yanks to `+` go out as OSC 52. It's
    self-contained, so it also works on Ubuntu's packaged Neovim 0.9. Paste reads
    Neovim's own register, because most terminals refuse OSC 52 reads.

## Troubleshooting

- **Icons show as boxes in a WSL tab:** the WSL profile lost its Nerd Font. Apply the
  Terminal template (`chezmoi apply` on the `settings.json` target).
- **A setting keeps coming back after you changed it in the UI:** the template forces
  it. Change it in the template.
- **Right-click doesn't paste in OpenCode:** expected, use Shift+right-click or
  `Ctrl+V` (see [Clipboard](#clipboard)).
- **A new split opens in your home folder:** the shell isn't reporting its folder.
  pwsh needs starship (the hook is `Invoke-Starship-PreCommand`); WSL zsh needs
  `WT_SESSION` (passed in by default through `WSLENV`) and `wslpath`.
