# tmux-worktree

A tmux plugin to create, list, switch to, and delete git worktrees from a single floating popup, powered by fzf.

Press the main bind key to open a dashboard popup. From there you can open an existing worktree, create one from your query, delete one, and toggle the path column.

Worktrees are placed in a `<repo>-worktrees/` directory next to your repo root, keeping your workspace tidy.

## Requirements

- tmux >= 3.2 (for `display-popup`)
- git >= 2.5 (for `git worktree`)
- [fzf](https://github.com/junegunn/fzf) (optional but recommended — falls back to `read` prompts without it)

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm)

Add to your `tmux.conf`:

```tmux
set -g @plugin 'SergioGhisler/tmux-worktree'
```

Then press `prefix + I` to install.

### Manual

```bash
git clone https://github.com/SergioGhisler/tmux-worktree ~/.config/tmux/plugins/tmux-worktree
```

Add to your `tmux.conf`:

```tmux
run '~/.config/tmux/plugins/tmux-worktree/worktree.tmux'
```

## Usage

1. Open any tmux pane inside a git repository
2. Press `prefix + w` (or your configured `@worktree-bind`) to open the dashboard
3. In the dashboard popup:
   - Your current query is always shown as the first `new` row
   - Existing worktrees stay visible in the list while you type
   - `Enter`: open selected worktree (or create/open from query if nothing selected)
   - `Ctrl-N`: create/open from current query
   - `Ctrl-D`: delete selected linked worktree
   - `Ctrl-P`: toggle PATH column on/off
4. Shortcuts are shown in a dedicated hint line at the very bottom of the popup
5. A new tmux window opens at the worktree path

Worktrees are created at `../<repo>-worktrees/<branch-name>/` relative to the repo root.

## Configuration

All options are optional. Defaults are shown below.

```tmux
set -g @worktree-bind 'w'                  # key to trigger the popup (with prefix)
set -g @worktree-popup-width '80%'         # popup width (minimum effective: 70%)
set -g @worktree-popup-height '70%'        # popup height (minimum effective: 55%)
set -g @worktree-popup-title 'Worktrees'   # popup border title
set -g @worktree-show-path 'on'            # show PATH column in dashboard (on/off)
```

## How it works

- **Existing branch**: runs `git worktree add <path> <branch>` and opens the result
- **New branch**: in dashboard mode, runs `git worktree add -b <branch> <path> <current-branch>`
- **Dashboard mode**: one popup for open/create/delete actions with keyboard shortcuts
- **Already checked out**: if the branch already has a worktree, switches to its existing path instead of creating a duplicate
- **Collision handling**: if a path is already used by a different branch, a numbered suffix (`-2`, `-3`, ...) is tried

## License

MIT
