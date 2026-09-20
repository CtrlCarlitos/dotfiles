# 🖥️ Zsh, tmux & Neovim: A Beginner's Tutorial

Three layers that turn a terminal into a workstation: **Zsh** is the shell you're probably already
sitting in — this setup adds a stack of tools on top of it you may not have found yet. **tmux**
keeps your terminal sessions alive and organized. **Neovim** is a text editor that never leaves
the keyboard. Together they're the standard toolkit for anyone spending real time SSH'd into a
remote box — and once the first-week awkwardness passes, they're faster than almost anything with
a mouse in it.

Part 1 assumes you already know your way around a shell and want to get more out of what's
already installed. Parts 2 and 3 assume you've never opened tmux or Neovim before. Every command
below is the *actual* one from this repo's config (`dot_zshrc`, `dot_aliases.zsh`, `dot_tmux.conf`,
`dot_config/nvim/init.lua`) — for the full reference once you're past the basics, see
[`docs/zsh-tips.md`](zsh-tips.md), [`docs/tmux.md`](tmux.md), and [`docs/nvim.md`](nvim.md).

- **Zsh** — your shell, with modern tooling layered in: a fast prompt, fuzzy history/file search,
  a smarter `cd`, and a set of Rust-based replacements for `ls`/`cat`/`find`/`grep`/`diff`.
- **tmux** — terminal multiplexer. Runs your shell inside a window manager for the terminal.
  Split panes, multiple windows, and — the killer feature — sessions that survive you closing
  your laptop.
- **Neovim** — modal text editor. A code editor that runs entirely in the terminal, controlled
  almost entirely without moving your hands off the home row. Steeper start, much higher ceiling.

---

## Part 1: Zsh — leveling up

You already know `cd`, pipes, and `.bashrc`-style config. This part is a tour of what this setup
adds on top of vanilla Zsh — most of it silent until you know it's there.

### The modern CLI replacements

Same commands you already type, faster and more readable. All of them are optional — the plain
originals still work — but the aliases below make the modern versions the default.

| Instead of | You get | Why |
|---|---|---|
| `ls` | `eza --icons` (aliased) | Icons, git status inline, `lt` for a tree view |
| `cat` | `bat` (`batcat` on Debian/Ubuntu, symlinked to `bat`) | Syntax highlighting, line numbers |
| `find` | `fd` (`fdfind` on Debian/Ubuntu, aliased to `fd`) | Simpler syntax, respects `.gitignore` |
| `grep` | `ripgrep` (`rg`) | Much faster on large trees, respects `.gitignore` |
| `git diff` | `delta` | Side-by-side, syntax-highlighted diffs (wired in as git's pager) |
| `du -h` | `dust` (aliased) | Visual, sorted disk usage tree |
| `df -h` | `duf` (aliased) | Colorized, easier-to-scan disk-free view |
| `ps` | `procs` (aliased) | Colorized, tree-aware process list |
| `man <cmd>` | `tldr <cmd>` | Example-based cheatsheet instead of a full man page |

Try it: `ll` (aliased to `eza -la --icons --git`) in any git repo — file listing with inline git
status, not just permissions.

### Prompt, navigation, search

| Tool | What it gives you | Try it |
|---|---|---|
| **Starship** | A fast, informative prompt (git branch/status, language versions, etc.), configured in `~/.config/starship.toml` | Just look at your prompt — it's already running |
| **zoxide** | A `cd` that learns your habits | `z proj` jumps to your most-used directory matching "proj"; `zi` opens an interactive picker |
| **fzf** | Fuzzy-find anything | `Ctrl+R` fuzzy-searches your command history; `Ctrl+T` fuzzy-finds files to insert at the cursor |
| **direnv** | Per-directory environment variables | Drop a `.envrc` in a project, `direnv allow`, and it auto-loads/unloads as you `cd` in and out |
| **lazygit** | A full git TUI | Run `lazygit` in any repo — stage, commit, branch, and resolve conflicts without memorizing flags |
| **GitHub CLI (`gh`)** | GitHub from the terminal | `gh pr create`, `gh repo clone owner/repo`, `gh auth login` for repo access |

### Already-loaded plugins worth knowing about

| Plugin | What it does |
|---|---|
| `zsh-autosuggestions` | Ghost-text suggests the rest of a command from history — `→` or `End` to accept |
| `zsh-syntax-highlighting` | Commands turn green (valid) or red (invalid) as you type, before you hit enter |
| `zsh-history-substring-search` | Type part of a past command, then `↑`/`↓` to cycle matching history entries |
| `zsh-you-should-use` | Nags you when you type something out longhand that already has an alias |
| `alias-finder` | `alias-finder git status` tells you if an alias already covers a command you just typed |
| `dirhistory` | `Alt+←`/`Alt+→` walks back and forward through directories you've `cd`'d into |
| `fzf-tab` | Replaces the default tab-completion list with a fuzzy-searchable one — press `Tab`, then type to filter |

### Aliases already set up for you

| Alias | Expands to |
|---|---|
| `dc` / `dcu` / `dcd` / `dcl` | `docker compose` / `up -d` / `down` / `logs -f` |
| `dp` (or `devprofile`) | Show/switch which git identity is active — bare `dp` shows the current one |
| `reload` / `zshrc` / `aliases` | Reload `.zshrc` / edit `.zshrc` / edit `.aliases.zsh` |
| `dot up` | `chezmoi update --apply` + config re-init — pull and apply the latest dotfiles (never upgrades) |
| `dot upgrade` | upgrade all tooling (packages + AI tools, session-gated) |

Oh-My-Zsh's `git` plugin also loads a full set of git shortcuts (`gst`, `gco`, `gcmsg`, `gp`, `gl`,
`gd`, `glo`, ...) — see [`docs/zsh-tips.md`](zsh-tips.md) for the full list.

### Practice drill

1. In any git repo, run `ll` and notice the inline git status per file.
2. `cd` somewhere a few times, then anywhere else, type `z <part of a name>`, and watch it jump
   straight there.
3. Type a command you've run before (even a few characters), hit `Ctrl+R`, and search your history
   instead of pressing `↑` repeatedly.
4. Run `lazygit` in a repo with uncommitted changes and stage a file with `Space` instead of typing
   `git add`.
5. Type out a full command that has an alias (e.g. `docker compose up -d`) and watch
   `zsh-you-should-use` remind you that `dcu` exists.

---

## Part 2: tmux

Your prefix key is remapped to **`Ctrl+a`** in this setup (the tmux default is `Ctrl+b` — `Ctrl+a`
is easier to reach). Every binding below is pressed *after* the prefix unless marked otherwise.

### Why bother?

Open a normal terminal, SSH into a server, start a long build — then your laptop sleeps, your wifi
drops, or you accidentally close the window. The process dies with it. tmux solves this by running
your shell *inside* a session that lives on the server independently of whether anything is
looking at it. Close your laptop, walk away, come back an hour later, and `tmux attach` puts you
right back where you left off, scrollback and all.

The second reason people use it even locally: one terminal window, many panes and tabs, all
reachable without touching the mouse.

### The mental model

tmux has three nested layers. You'll live mostly in the bottom two.

| Layer | What it is |
|---|---|
| **Session** | A named workspace, e.g. `work` or `deploy`. This is the thing that survives disconnection. You can have several, and jump between them. |
| **Window** | Like a browser tab. A session can have several — one per project, one for logs, etc. |
| **Pane** | A split within a window — the editor on the left, a running server on the right, for example. |

### Your first session

```sh
tmux new -s work        # create + enter a session named "work"

# ... you're now inside tmux. Try a split:
Ctrl+a  |                # split the pane vertically (side by side)
Ctrl+a  h                # move to the pane on the left
Ctrl+a  d                # detach — the session keeps running

tmux ls                  # see it's still alive
tmux attach -t work      # jump right back in
```

That loop — **attach, work, detach** — is 90% of daily tmux use. Everything else is refinement on
top of it.

### Core moves

| Keys | What it does |
|---|---|
| `Ctrl+a` | Prefix — press first, release, then press the next key. |
| `Ctrl+a` → `\|` | Split pane vertically (side by side). |
| `Ctrl+a` → `-` | Split pane horizontally (stacked). |
| `Ctrl+a` → `h j k l` | Move between panes (vim directions: left/down/up/right). |
| `Ctrl+a` → `c` | New window, same directory you're already in. |
| `Shift` + `←`/`→` | Switch windows — no prefix needed. |
| `Ctrl+a` → `H J K L` | Resize the current pane (holdable — keep pressing). |
| `Ctrl+a` → `d` | Detach — leaves everything running in the background. |
| `Ctrl+a` → `[` | Enter copy/scroll mode. `v` starts a selection, `y` copies it (goes to your system clipboard). |
| `Ctrl+a` → `r` | Reload the config after editing it. |

> **Already on by default:** the mouse works — click a pane to focus it, drag a border to resize,
> scroll to see history. Nothing above is mandatory on day one; it's there so you can go faster
> once splits and panes stop feeling new.

### Practice drill

1. Start a session: `tmux new -s practice`.
2. Split it twice — once vertically (`Ctrl+a |`), once horizontally (`Ctrl+a -`) — until you have
   three panes.
3. Move between all three using only `Ctrl+a` + `hjkl` — no mouse.
4. Run something long-lived in one pane (`ping google.com` works fine), then detach with
   `Ctrl+a d`.
5. Close the terminal window entirely. Reopen a new one, run `tmux attach -t practice`, and watch
   the ping still running.

Step 5 is the moment tmux clicks for most people — do it for real, not hypothetically.

> **Already configured for you:** this setup ships `tmux-resurrect` and `tmux-continuum`, which
> checkpoint your sessions automatically and restore them even after a full reboot — not just a
> detach. Installed via TPM; press `Ctrl+a I` (capital i) once inside tmux to install/update
> plugins.

---

## Part 3: Neovim

Your leader key is **`Space`** in this setup (most custom commands below start with it).

### The one new idea: modes

Every other editor you've used has one mode: type, and letters appear. Neovim has several, and
switching between them is the entire learning curve. Once it's automatic, everything else is just
vocabulary.

| Mode | Enter with | What it's for |
|---|---|---|
| **NORMAL** | start here / `Esc` | Keys are commands, not letters. Move, delete, copy, search. This is home base. |
| **INSERT** | `i` | Types letters like every other editor. Press `Esc` to leave. |
| **VISUAL** | `v` | Select text by moving, like holding Shift in any other editor — then act on the selection. |
| **COMMAND** | `:` | Type a command at the bottom bar — `:w` saves, `:q` quits. |

### Your first five minutes

```sh
nvim notes.txt

# you land in NORMAL mode — typing does nothing yet, and that's correct
i             # enter INSERT mode
Hello, this is real typing now.
Esc           # back to NORMAL mode
Space w       # save (<leader>w — leader is Space)
Space q       # quit
```

If you only remember one thing: **`Esc` always gets you back to NORMAL mode.** When in doubt, hit
it.

### Core moves

| Keys | What it does |
|---|---|
| `Space` → `e` | Toggle the file tree sidebar. |
| `Space` → `f f` | Find files by name, fuzzy — the fast way to open anything. |
| `Space` → `f g` | Live grep — search text across the whole project. |
| `Space` → `f b` | List open buffers (files) and jump to one. |
| `Ctrl` + `h j k l` | Move between split windows. |
| `Shift` + `h` / `l` | Previous / next open buffer. |
| `Space` → `b d` | Close the current buffer. |
| `Space` → `w` / `q` | Save / quit. |
| `u` | Undo. Undo history is persistent — it survives closing the file. |
| `gcc` | Toggle a comment on the current line (visual mode: `gc` on a selection). |

### The real unlock: verbs + objects

This is the idea that separates "knows some vim keys" from actually fast. Commands compose like a
tiny grammar: an **operator** (what to do) plus a **text object** (what to do it to). Learn the
pieces once, and they combine in dozens of useful ways you never had to memorize individually.

| Operator | + | Object | Result |
|---|---|---|---|
| `c` | + | `iw` | change — the cursor sits inside a word |
| `d` | + | `i"` | delete — cursor is inside a "quoted string" |
| `d` | + | `ap` | delete — a whole paragraph, blank line included |
| `y` | + | `i{` | yank (copy) — everything inside `{ curly braces }` |
| `c` | + | `it` | change — inside an HTML/JSX tag |

Add `.` to the list — it repeats whatever change you just made. Make one edit deliberately, then
mash `.` to repeat it at the next spot instead of redoing the whole motion. This single habit is
worth more than any other tip here.

> **Surround, for free:** this config adds one more layer on top: `ys` + a motion + a character
> wraps text in it. `ysiw"` wraps the word under the cursor in quotes. `ds"` deletes surrounding
> quotes. `cs"'` swaps `"` for `'`. Same grammar, new operator.

### What's already installed

You don't need to configure any of this — it's part of the setup already:

| Plugin | What it does |
|---|---|
| **Telescope** | fuzzy file/text search |
| **nvim-tree** | file sidebar |
| **Treesitter** | real syntax highlighting |
| **gitsigns** | git changes in the gutter |
| **which-key** | press `Space` and wait — it shows you what's next |
| **Comment.nvim** | `gcc` / `gc` |
| **nvim-surround** | `ys` / `ds` / `cs` |
| **autopairs** | auto-closes `(` `[` `"` |
| **lualine** | status line |

> **Don't memorize — discover:** press `Space` and pause for a second. Which-key pops up a menu of
> every leader binding available. Use this instead of re-reading the table above — it's how you'll
> actually retain the bindings.

### Practice drill

1. Run `:Tutor` inside Neovim. ~30 minutes, interactive, built in. Do this before anything else
   below.
2. Open a real file with `Space ff` instead of arguing with a file tree.
3. Find a word in it, delete it with `diw`, undo with `u`.
4. Make one small edit, then find three more identical spots and fix each with `.` instead of
   repeating the motion.
5. Search your whole project for a string with `Space fg`.

---

## Putting it together

Neither tool is that interesting alone. Together, they're most of what a remote dev setup needs.

```sh
ssh myserver
tmux new -s project
Ctrl+a |            # split: editor on the left
nvim .
Ctrl+a l            # move right
npm run dev         # server stays visible while you edit

# wifi drops, laptop sleeps, doesn't matter —
tmux attach -t project   # everything is exactly as you left it
```

That's the entire pitch: one persistent session, an editor that never needs a mouse, and a server
process you can keep an eye on in the next pane over.

### A realistic path to fluent

| When | Focus |
|---|---|
| **Day 1** | tmux basics, nvim's Tutor. Run the practice drills above for real. Run `:Tutor` once, start to finish. |
| **Week 1** | Make tmux the default. Attach to a tmux session every time you open a terminal, instead of only when you remember to. Habit beats study here. |
| **Weeks 2–4** | Verb + object, on repeat. This is where nvim fluency actually happens — not more keybindings, but making `ciw`, `di"`, `dap`, and `.` automatic through real editing, not drills. |
| **Ongoing** | Let which-key teach the rest. Stop trying to memorize the full binding list. Press Space, read the menu, and the gaps fill in on their own over the following weeks. |

## Where to go next

- [`docs/zsh-tips.md`](zsh-tips.md) — the full shell reference: every plugin, every alias, git
  shortcuts, globbing patterns, and troubleshooting for a slow or misbehaving shell.
- [`docs/tmux.md`](tmux.md) and [`docs/nvim.md`](nvim.md) — the full, exact keybinding reference
  for this setup, kept in sync with the real config files.
