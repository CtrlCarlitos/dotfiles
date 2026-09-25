# Neovim Guide for Beginners

**Neovim (nvim)** is a hyper-extensible text editor based on Vim. This configuration is designed to be friendly for new users while powerful enough for daily work.

## 🚀 core Concepts

*   **Modes**:
    *   **Normal Mode** (Default): For navigation and commands. Press `Esc` to return here.
    *   **Insert Mode**: For typing text. Press `i` to enter.
    *   **Visual Mode**: For selecting text. Press `v` to enter.
    *   **Command Mode**: For editor commands (save, quit). Press `:` to enter.

*   **The Leader Key**:
    The "Leader" key is a special trigger for your custom shortcuts.
    **Leader Key is set to: `Space`**

## ⚡ Essential Shortcuts

### File Management
| Action | Key Binding | Description |
| :--- | :--- | :--- |
| **Open Explorer** | `Space` `e` | Toggle file tree on the left |
| **Find File** | `Space` `f` `f` | Fuzzy search files by name (Telescope) |
| **Search Text** | `Space` `f` `g` | Search text inside any file (Live Grep) |
| **Save File** | `Space` `w` | Write (save) buffer |
| **Quit** | `Space` `q` | Quit current window |

### Navigation
| Action | Key Binding |
| :--- | :--- |
| **Move Cursor** | `h` (left), `j` (down), `k` (up), `l` (right) |
| **Window Split** | `Ctrl + h/j/k/l` to move between splits |
| **Resize Split** | `Ctrl + Arrow` (Up/Down change height, Left/Right change width) |
| **Next Buffer** | `Shift + l` (next tab) |
| **Prev Buffer** | `Shift + h` (previous tab) |
| **Close Buffer** | `Space` `b` `d` |

### Editing
| Action | Key Binding |
| :--- | :--- |
| **Undo** | `u` |
| **Redo** | `Ctrl + r` |
| **Comment Line** | `gcc` |
| **Comment Block** | Select text with `v`, then `gc` |
| **Auto-Indent** | `=` |
| **Move Line(s) Down/Up** | `J` / `K` in visual mode (auto re-indents) |
| **Clear Search Highlight** | `Esc` (after a `/` search) |

**On save:** trailing whitespace is stripped from the whole buffer
(`BufWritePre`), and yanks flash briefly (`TextYankPost` highlight).

## 🔌 Plugins Included

*   **Lazy.nvim**: Plugin manager — installs plugins on first launch; run
    `:Lazy update` yourself to pull updates (no automatic checker).
*   **Catppuccin**: Color scheme (Mocha flavor).
*   **lualine.nvim**: Status line at the bottom.
*   **Telescope**: Powerful fuzzy finder for everything (`Space f f` files, `Space f g` live grep, `Space f b` buffers, `Space f h` help tags).
*   **Nvim-Tree**: File explorer sidebar (`Space e`).
*   **Treesitter**: Better syntax highlighting and indenting.
*   **gitsigns.nvim**: Git change markers in the gutter.
*   **nvim-autopairs**: Auto-close brackets/quotes.
*   **Comment.nvim**: The `gcc` / `gc` commenting.
*   **Which-Key**: Pop-up helper that shows you available keys if you wait a second after pressing `Space`.
*   **indent-blankline**: Indent guides.
*   **nvim-surround**: Add/change/delete surrounding quotes and brackets (`ys`/`cs`/`ds`).

## 📋 Clipboard
`y` (yank) and `p` (paste) use the system clipboard (`clipboard = unnamedplus`), so
what you yank in Neovim pastes anywhere, and the other way round.

*   **Locally:** Neovim finds the OS tool itself: `clip.exe` in WSL, `pbcopy` on macOS,
    `xclip` / `wl-copy` on a Linux desktop.
*   **Over SSH:** a server has no clipboard tool, so `init.lua` sends yanks to your
    *local* terminal as OSC 52 when `$SSH_TTY` is set, and they land on your laptop's
    clipboard. Paste there with right-click or your terminal's paste key; `p` inside
    Neovim pastes what Neovim itself yanked. Works on Neovim 0.9+. See
    [Terminal Experience](terminal.md#remote-ssh-hosts).

## 💡 Tips for Learning
1.  **Don't use arrow keys**: Force yourself to use `h j k l`. It's faster once you get used to it.
2.  **Use `Space`**: Wait a second after pressing `Space` to see the *Which-Key* menu with all available options.
3.  **Run `:checkhealth`**: If something feels broken, run this command to see a diagnostic report.
