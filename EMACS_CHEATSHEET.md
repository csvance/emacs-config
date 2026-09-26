# Emacs Cheat Sheet

Key notation: `C-` is Ctrl, `M-` is Alt (Meta), `S-` is Shift. `C-x g` means press Ctrl+x, release, then press g. Anywhere in Emacs, `C-g` cancels the current command.

## Function keys

| Key | Action |
|---|---|
| `F7` | Toggle inline type hints (in buffers with a language server) |
| `F8` | Toggle the Treemacs sidebar |
| `F9` | Open this cheat sheet, or return to the previous buffer |
| `F10` | Open the menus (the menu bar is hidden) |
| `F12` | Open the project's terminal, or return to the previous buffer |

## Terminal (vterm)

A full terminal emulator, good for SSH and TUI programs such as coding agents. Keys go to the program running in it, except the `C-c`, `C-x`, `M-x`, `F8`, `F9` and `F12` prefixes.

| Key | Action |
|---|---|
| `F12` | Open the project's terminal (in the project root), or go back |
| `C-u F12` | Open another terminal for the same project |
| Session keys | Keys set in `my/vterm-sessions` (in `local.el`) open a persistent terminal running a fixed command, such as an SSH session; press again to return, and it reopens if the command exits |
| `C-S-v` | Paste |
| `C-c C-t` | Copy mode: move and select with the usual keys, `RET` copies and exits |
| `C-c C-c` | Send Ctrl+C to the program (a single `C-c` waits for a second key) |
| `C-c C-g` | Send Ctrl+G to the program (`C-g` alone cancels in Emacs) |
| `C-c C-l` | Clear the scrollback |

## Magit

Open the status buffer with `C-x g`. Almost everything starts there. Keys open a menu ("transient"), so you can press the first key and read the options. Press `?` in the status buffer to see every menu.

### Status buffer basics

| Key | Action |
|---|---|
| `g` | Refresh |
| `q` | Close the Magit buffer |
| `n` / `p` | Next / previous section |
| `TAB` | Expand or collapse a section (shows the diff of a file) |
| `RET` | Visit the file or commit at point |
| `?` | Show all available commands |
| `$` | Show the raw Git output (useful when something fails) |

### Staging

| Key | Action |
|---|---|
| `s` | Stage file or hunk at point |
| `u` | Unstage file or hunk at point |
| `S` | Stage all changes |
| `U` | Unstage all changes |
| `k` | Discard changes at point (asks first) |

To stage only a few lines, expand the file with `TAB`, select the lines with Shift+arrows, then press `s`.

### Committing

| Key | Action |
|---|---|
| `c c` | Commit (opens a message buffer) |
| `C-c C-c` | Finish the commit (in the message buffer) |
| `C-c C-k` | Cancel the commit |
| `M-p` / `M-n` | Cycle through previous commit messages |
| `c a` | Amend the last commit (edit message too) |
| `c e` | Extend the last commit with staged changes, keep message |
| `c w` | Reword the last commit message only |
| `c F` | Instant fixup: fold staged changes into an older commit |

### Branches

| Key | Action |
|---|---|
| `b b` | Check out an existing branch |
| `b c` | Create a new branch and check it out |
| `b n` | Create a new branch without checking it out |
| `b s` | Spin off: move unpushed commits to a new branch |
| `b m` | Rename a branch |
| `b k` | Delete a branch |

### Pushing, pulling and fetching

| Key | Action |
|---|---|
| `P p` | Push to the push remote |
| `P u` | Push to upstream (on a new branch, Magit asks which remote branch to set) |
| `F p` / `F u` | Pull from the push remote / upstream |
| `f a` | Fetch all remotes |
| `M a` | Add a remote |

Typical new branch workflow: `b c` to create the branch, make changes, `s` to stage, `c c` then `C-c C-c` to commit, `P u` to push and set the upstream.

### Worktrees

The status buffer lists every worktree under **Worktrees** when there is more than one. `RET` on a worktree opens its status, `k` deletes it (asks first).

| Key | Action |
|---|---|
| `Z b` | New worktree for an existing branch or commit |
| `Z c` | New branch and a worktree for it |
| `Z g` | Visit another worktree's status |
| `Z m` | Move a worktree |
| `Z k` | Delete a worktree |

### History, diffs and more

| Key | Action |
|---|---|
| `l l` | Log of the current branch |
| `l a` | Log of all branches |
| `d d` | Diff of the thing at point |
| `z z` | Stash changes |
| `z p` | Pop a stash |
| `m m` | Merge a branch into the current one |
| `r u` | Rebase onto upstream |
| `r i` | Interactive rebase |
| `A A` | Cherry-pick a commit |
| `V V` | Revert a commit |
| `X` | Reset menu (`X s` soft, `X m` mixed, `X h` hard) |
| `t t` | Create a tag |
| `!` | Run any Git command |

### From any file buffer

| Key | Action |
|---|---|
| `C-c M-g` | Magit menu for the current file (blame, log of this file, stage this file) |
| `C-x M-g` | Magit menu for the whole repository |

## Treemacs

`F8` toggles the Treemacs sidebar. The keys below work inside the Treemacs window. Press `?` there for the full list.

### Navigating and opening

| Key | Action |
|---|---|
| `n` / `p` | Next / previous line |
| `TAB` | Expand or collapse a folder |
| `RET` | Open the file |
| `ov` | Open in a vertical split |
| `oh` | Open in a horizontal split |
| `P` | Toggle peek mode (preview files as you move) |
| `w` | Set sidebar width |
| `q` | Hide the sidebar |

### Files

| Key | Action |
|---|---|
| `cf` | Create a file |
| `cd` | Create a directory |
| `R` | Rename |
| `m` | Move |
| `d` | Delete (asks first) |

### Projects and workspaces

| Key | Action |
|---|---|
| `C-c C-p a` | Add a project |
| `C-c C-p d` | Remove a project from the sidebar (files are untouched) |
| `C-c C-p r` | Rename a project |
| `C-c C-w a` | Create a workspace |
| `C-c C-w s` | Switch workspace |
| `C-c C-w r` | Rename a workspace |
| `C-c C-w d` | Delete a workspace |
| `C-c C-w e` | Edit all workspaces and projects as a text file |

Suggested setup: one workspace per mono repo, plus one workspace for your smaller repos.

## Projects (project.el)

Works in any file buffer, no sidebar needed. Uses Git to list files, so it stays fast in large repos.

| Key | Action |
|---|---|
| `C-x p p` | Switch to another project |
| `C-x p f` | Find a file in the current project |
| `C-x p g` | Search the project with a regular expression |
| `C-x p b` | Switch between buffers of this project |
| `C-x p k` | Close all buffers of this project |
| `C-x p d` | Open the project directory (Dired) |
| `C-x p s` | Open a shell in the project root |
| `C-x p !` | Run a shell command in the project root |
| `C-x p c` | Run a compile command in the project root |

## Code navigation (Eglot)

Works for Julia (JETLS) and Python (basedpyright). Shell, Go and Rust use tree-sitter highlighting only, with no language server.

| Key | Action |
|---|---|
| `M-.` | Go to definition |
| `M-,` | Go back |
| `M-?` | Find references |
| Ctrl+click | Go to definition |
| Mouse back / forward buttons | Go back / forward |
| `C-M-.` | Search for a symbol by name |
| `F7` | Toggle inline type hints (`M-x eglot-inlay-hints-mode`) |
| `M-x eglot-rename` | Rename symbol across the project |
| `M-x eglot-code-actions` | Quick fixes and refactorings |
| `M-x eglot-format` | Format the buffer or selection |
| `M-x flymake-show-buffer-diagnostics` | List all errors and warnings in the file |
| `M-x eglot-reconnect` | Restart the language server |

## Everyday editing

With CUA mode, the familiar keys work whenever text is selected.

| Key | Action |
|---|---|
| `C-c` / `C-x` / `C-v` | Copy / cut / paste (with a selection) |
| `C-z` | Undo |
| `C-S-z` | Redo |
| Shift+arrows | Select text |
| `C-x C-s` | Save |
| `C-x C-f` | Open a file |
| `C-x b` | Switch buffer |
| `C-x k` | Close buffer |
| `M-x recentf-open` | Open a recently used file |
| `C-s` / `C-r` | Search forward / backward (repeat to jump) |
| `M-%` | Search and replace |
| `M-x` | Run any command by name |

If a selection is active and you need a `C-x` command (such as `C-x C-s`), press `S-C-x` or tap `C-x` twice quickly.

### Windows

| Key | Action |
|---|---|
| `C-x 2` | Split horizontally |
| `C-x 3` | Split vertically |
| `C-x o` | Move to the other window |
| `C-x 1` | Close all other windows |
| `C-x 0` | Close this window |

### Getting help

| Key | Action |
|---|---|
| `C-h k` | Describe what a key does |
| `C-h f` | Describe a function |
| `C-h v` | Describe a variable |
| `C-h m` | Show keys for the current mode |

## Custom setup

### revise-sync

| Command | Action |
|---|---|
| `M-x revise-sync-status` | Show running watchers |
| `M-x revise-sync-restart` | Restart the watcher for the current project |
| `M-x revise-sync-stop-all` | Stop every watcher |

Opening a file in a configured project starts `bin/revise-watch.sh` for it, which forwards each saved `.jl` file to the REPL host as a `touch` so Revise picks it up. Closing the project's last buffer stops it. Output appears in buffers named like `*revise-sync:MyProject.jl*`, one `touched` line per save. Projects and the host are set in `local.el`.

### One-time setup commands

| Command | Action |
|---|---|
| `M-x nerd-icons-install-fonts` | Install the Treemacs icon font (restart afterward) |
| `M-x treesit-auto-install-all` | Install all configured tree-sitter grammars at once |
| `M-x package-refresh-contents` | Refresh the package list before updating |
| `M-x package-upgrade-all` | Update all installed packages |
