# tmux-worktree

A tmux plugin to create and switch to git worktrees from a floating popup, powered by fzf.

Press the bind key to open a popup where you can type a branch name. If the branch exists, a worktree for it is created (or reused) and opened in a new window. If it doesn't exist, you're prompted to pick a base branch and a new branch + worktree are created together.

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
2. Press `prefix + w` (or your configured bind)
3. Type a branch name in the popup:
   - If the branch **exists**: a worktree for it is created and opened
   - If it **doesn't exist**: you'll be prompted to pick a base branch, then the new branch + worktree are created
4. A new tmux window opens at the worktree path

Worktrees are created at `../<repo>-worktrees/<branch-name>/` relative to the repo root.

## Configuration

All options are optional. Defaults are shown below.

```tmux
set -g @worktree-bind 'w'                  # key to trigger the popup (with prefix)
set -g @worktree-popup-width '60%'         # popup width
set -g @worktree-popup-height '20%'        # popup height
set -g @worktree-popup-title 'Create Worktree'  # popup border title
```

## How it works

- **Existing branch**: runs `git worktree add <path> <branch>` and opens the result
- **New branch**: asks for a base branch, runs `git worktree add -b <branch> <path> <base>`, opens the result
- **Already checked out**: if the branch already has a worktree, switches to its existing path instead of creating a duplicate
- **Collision handling**: if a path is already used by a different branch, a numbered suffix (`-2`, `-3`, ...) is tried

## License

MIT
