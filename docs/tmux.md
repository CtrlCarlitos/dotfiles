# Tmux Guide for Beginners

**Tmux (Terminal Multiplexer)** lets you manage multiple terminal sessions, windows, and panes within a single window. It's incredibly useful for remote work (your session stays alive even if you disconnect) and organizing your workspace.

## 🚀 Getting Started

Start a new session:
```bash
tmux
```

Start a named session (easier to find later):
```bash
tmux new -s my-project
```

Attach to an existing session:
```bash
tmux attach -t my-project
```
(Or just `tmux a` to attach to the last one)

## 🔑 Key Bindings

**The Prefix Key**
In this config, the "Command Key" (Prefix) has been changed from `Ctrl+b` (default) to **`Ctrl+a`**. safely easier to reach!
You must press `Ctrl+a`, **release it**, and then press the command key.

| Action | Key Binding | Mnemonic |
| :--- | :--- | :--- |
| **Split Vertically** | `Ctrl+a` then `\|` | (Visual split) |
| **Split Horizontally** | `Ctrl+a` then `-` | (Visual split) |
| **New Window** | `Ctrl+a` then `c` | **C**reate |
| **Close Pane** | `Ctrl+d` (or `exit`) | Standard shell exit |
| **Detach Session** | `Ctrl+a` then `d` | **D**etach |
| **Send real Ctrl+A** | `Ctrl+a` then `Ctrl+a` | Passes a literal `Ctrl+A` (beginning-of-line) to the program in the pane |

### Navigation (Vim-style)
Move between panes using `h` `j` `k` `l` (Left, Down, Up, Right):
*   `Ctrl+a` then `h` → Left
*   `Ctrl+a` then `j` → Down
*   `Ctrl+a` then `k` → Up
*   `Ctrl+a` then `l` → Right

### Windows (Tabs)
*   `Ctrl+a` then `n` → **N**ext window
*   `Ctrl+a` then `p` → **P**revious window
*   `Ctrl+Shift + Left/Right` → **Swap** the current window with its neighbour (no prefix needed!)

### Resizing Panes
*   `Ctrl+a` then `H` / `J` / `K` / `L` (capitalized) to resize.

## 📝 Copy Mode (Scrolling)
To scroll up or copy text:
1.  Press `Ctrl+a` then `[` to enter **Copy Mode**.
2.  Use arrow keys or `PageUp`/`PageDown` (or `k`/`j`) to scroll.
3.  Press `v` to start selecting text.
4.  Press `y` to copy text to your system clipboard.
5.  Press `q` to quit copy mode.

Dragging with the mouse copies too. Where the copy lands:

- **WSL:** `clip.exe`, the Windows clipboard.
- **macOS:** `pbcopy`.
- **Linux desktop:** `wl-copy` on Wayland, `xclip` on X (only when a display is present).
- **Everywhere, including over SSH:** `set -s set-clipboard on` also sends each copy to
  your *local* terminal as OSC 52, so a copy in tmux on a remote server reaches your
  laptop's clipboard. Windows Terminal, iTerm2, Ghostty, WezTerm and kitty accept it.
  See [Terminal Experience](terminal.md#remote-ssh-hosts).

## 🔌 Plugins
We use **TPM (Tmux Plugin Manager)**.
*   `Ctrl+a` then `I` (capital i) → **I**nstall new plugins listed in `tmux.conf`.
*   `Ctrl+a` then `r` → **R**eload configuration file.

## 🆘 Troubleshooting
*   **Colors look wrong?** Ensure your terminal supports True Color (most modern ones like Alacritty, iTerm2, or Windows Terminal do).
*   **Mouse not working?** Mouse support is enabled by default. You can click panes to focus and drag borders to resize.
