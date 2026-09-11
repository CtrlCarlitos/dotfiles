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

## 🔌 Plugins Included

*   **Lazy.nvim**: Plugin manager (updates plugins automatically).
*   **Telescope**: Powerful fuzzy finder for everything.
*   **Nvim-Tree**: File explorer sidebar.
*   **Treesitter**: Better syntax highlighting.
*   **Which-Key**: Pop-up helper that shows you available keys if you wait a second after pressing `Space`.

## 💡 Tips for Learning
1.  **Don't use arrow keys**: Force yourself to use `h j k l`. It's faster once you get used to it.
2.  **Use `Space`**: Wait a second after pressing `Space` to see the *Which-Key* menu with all available options.
3.  **Run `:checkhealth`**: If something feels broken, run this command to see a diagnostic report.
