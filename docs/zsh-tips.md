# 🐚 ZSH Tips & Tricks

A guide to getting the most out of your Zsh setup.

## Your Plugins

### Always Loaded

| Plugin | What It Does | How to Use |
|--------|--------------|------------|
| `zsh-autosuggestions` | Shows command history hints | Type, then → or End to accept |
| `zsh-syntax-highlighting` | Colors commands (green=valid, red=invalid) | Automatic |
| `zsh-history-substring-search` | Search history by typing | ↑/↓ arrows after typing |
| `zsh-completions` | Extra completions for many tools | Automatic |
| `zoxide` | Smarter cd command | `z project` jumps to ~/projects |
| `zsh-you-should-use` | Reminds you about aliases | Automatic |
| `fzf` | Fuzzy finder | `Ctrl+R` for history, `Ctrl+T` for files |
| `git` | Git aliases | `gst`, `gco`, `gp`, etc. |
| `history` | History management | `h` to show history |
| `dirhistory` | Navigate dirs with Alt+arrows | `Alt+Left/Right` |
| `alias-finder` | Find existing aliases | `alias-finder git status` |
| `copypath` | Copy current directory path | `copypath` |
| `copyfile` | Copy file contents to clipboard | `copyfile script.sh` |
| `fzf-tab` | Replaces the default tab-completion list with a fuzzy-searchable one | Press `Tab` as usual, then type to filter |

### Host-Only (Not in Devcontainers)

| Plugin | What It Does |
|--------|--------------|
| `docker` | Docker completions and aliases |
| `docker-compose` | Docker Compose aliases |
| `ssh` | SSH completions |
| `ssh-agent` | Auto-starts/reuses an SSH agent, loads keys |
| `ubuntu` | Ubuntu-specific commands |

## Modern CLI Tools (`install_modern`)

Installed alongside the plugins above, not part of Oh-My-Zsh itself:

| Tool | What it does | Try it |
|------|--------------|--------|
| `gh` | GitHub CLI (installed under `install_core`, not `install_modern` - it's needed for basic repo access) | `gh auth login`, `gh pr create`, `gh repo clone owner/repo` |
| `tealdeer` (`tldr`) | Example-based cheatsheets instead of full man pages | `tldr tar` |
| `dust` | Visual `du` replacement - aliased over `du` automatically when installed | `du` (now runs `dust`) |
| `duf` | Colorized `df` replacement - aliased over `df` automatically when installed | `df` (now runs `duf`) |
| `procs` | Colorized, tree-aware `ps` replacement - aliased over `ps` automatically when installed | `ps` (now runs `procs`) |

## Essential Shortcuts

### Navigation

| Shortcut | Action |
|----------|--------|
| `Ctrl+A` | Beginning of line |
| `Ctrl+E` | End of line |
| `Ctrl+U` | Clear line before cursor |
| `Ctrl+K` | Clear line after cursor |
| `Ctrl+W` | Delete word before cursor |
| `Alt+B` | Move back one word |
| `Alt+F` | Move forward one word |

### History

| Shortcut | Action |
|----------|--------|
| `Ctrl+R` | Fuzzy search history (with fzf) |
| `↑` / `↓` | Navigate history (or substring search) |
| `!!` | Repeat last command |
| `!$` | Last argument of previous command |
| `!*` | All arguments of previous command |

### Productivity

| Shortcut | Action |
|----------|--------|
| `Ctrl+L` | Clear screen |
| `Ctrl+Z` | Suspend process (use `fg` to resume) |
| `Tab` | Autocomplete |
| `Tab Tab` | Show all completions |

## Directory Navigation

```bash
# Go back
cd -          # Previous directory
..            # One level up (alias)
...           # Two levels up (alias)

# zoxide (smarter cd)
z proj        # Jump to most-used directory matching "proj"
z foo bar     # Jump to matching 'foo' and 'bar'
zi            # Interactive selection (using fzf)

# Standard cd still works
cd ~/projects

```

## Globbing (Pattern Matching)

Zsh has powerful pattern matching:

```bash
# Recursive glob
ls **/*.js              # All .js files in all subdirs

# Qualifiers
ls *(.)                 # Only files
ls *(/)                 # Only directories
ls *(.m-7)              # Files modified in last 7 days
ls *(Lm+10)            # Files larger than 10MB

# Extended glob
ls ^*.txt               # Everything except .txt files
ls *.txt~important.txt  # .txt files except important.txt
```

## Useful Aliases (Included)

### Git & Identity
Git status/log/branch aliases come from the Oh-My-Zsh `git` plugin - see
the [Oh-My-Zsh Git Aliases](#oh-my-zsh-git-aliases) section below (`gst`,
`glo`, `glg`, etc). You usually don't need to check or switch identity
manually at all - it's already selected automatically by which folder a
repo lives in. When you do (a repo outside any mapped folder, or just to
double-check), use `devprofile` (aliased to `dp` here; no equivalent alias
exists in PowerShell yet, see [windows.md](windows.md)) - full annotated
example output is in [devprofile](devprofile.md#example-outputs):
```bash
dp             # Show current repo's git identity (bare devprofile)
dp list        # List all configured identities
dp use NAME    # Switch identity for the current repo
dp verify      # Sanity-check the active identity against this repo's folder
```

### Docker
```bash
dc          # docker compose
dcu         # docker compose up -d
dcd         # docker compose down
dcl         # docker compose logs -f
```

### General
```bash
ll          # List with details (eza)
la          # List all (eza)
lt          # Tree view
reload      # Reload .zshrc
zshrc       # Edit .zshrc
aliases     # Edit aliases file
```

## Oh-My-Zsh Git Aliases

Your `git` plugin provides many aliases:

```bash
# Status
gst         # git status
gss         # git status -s

# Branches
gco         # git checkout
gcb         # git checkout -b
gb          # git branch
gba         # git branch -a

# Commits
gc          # git commit
gcmsg       # git commit -m
gca         # git commit --amend

# Push/Pull
gp          # git push
gl          # git pull
gf          # git fetch

# Diffs
gd          # git diff
gds         # git diff --staged

# Log
glg         # git log --stat
glo         # git log --oneline
```

Run `alias | grep git` to see all git aliases.

## Customizing Your Prompt

To configure **Starship**, edit `~/.config/starship.toml`.

See [Starship Documentation](https://starship.rs/config/) for all options.


## Adding Custom Aliases

1. Edit `~/.aliases.zsh`
2. Add your alias: `alias myalias='my command'`
3. Reload: `source ~/.zshrc` or `reload`

## Learn More

- Type `alias` to see all defined aliases
- Type `alias-finder <command>` to find relevant aliases
- History: `h` or `history` shows recent commands
- Path: `path` shows your PATH directories

## Troubleshooting

### Slow shell startup?

Profile it:
```bash
time zsh -i -c exit
```

If slow, check:
1. Number of plugins
2. Network-dependent plugins (nvm, etc.)
3. Large `.zsh_history`

### Command not found?

```bash
# Check if command exists
which <command>
type <command>

# Check PATH
echo $PATH | tr ':' '\n'
```

If it's an AI coding tool specifically (`claude`, `codex`, `agy`,
`opencode`) that's missing, check whether the installer was run with `sudo` -
see the entry right below.

### Files owned by root, or weird permission errors on `.zshrc`/plugins?

This almost always means `install.sh` was run with `sudo` in front of it at
some point. Don't do that - run it as your normal user; the script elevates
internally (its own `$SUDO` handling) only for the specific steps that
actually need root. Running the whole thing as root/sudo writes `$HOME`
files (including `~/.zshrc`, `~/.oh-my-zsh`, `~/.aliases.zsh`) as root
instead of you, which is exactly what causes plugins to silently fail to
load or history/completions to stop writing - the same symptoms as the two
Troubleshooting entries above, just with a different root cause than a slow
shell or a genuinely-missing plugin. It also breaks specific installers
outright: Claude Code's official installer detects and refuses to run under
sudo entirely (`Error: do not run this installer with sudo`).

Fix: re-run `install.sh` as yourself (no `sudo`), then reclaim ownership of
anything sudo wrote as root:
```bash
sudo chown -R "$(whoami)" ~/.zshrc ~/.oh-my-zsh ~/.aliases.zsh ~/.config/chezmoi
```

### Plugin not working?

```bash
# Verify it's loaded
echo $plugins

# Check install location
ls $ZSH/custom/plugins/
```
