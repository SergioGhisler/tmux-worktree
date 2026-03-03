#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

tmux_option_or_fallback() {
  local option_value
  option_value="$(tmux show-option -gqv "$1")"
  if [ -z "$option_value" ]; then
    option_value="$2"
  fi
  echo "$option_value"
}

main() {
  local bind popup_width popup_height popup_title

  bind="$(tmux_option_or_fallback "@worktree-bind" "w")"
  popup_width="$(tmux_option_or_fallback "@worktree-popup-width" "60%")"
  popup_height="$(tmux_option_or_fallback "@worktree-popup-height" "20%")"
  popup_title="$(tmux_option_or_fallback "@worktree-popup-title" "Create Worktree")"

  tmux bind-key "$bind" display-popup \
    -E \
    -w "$popup_width" \
    -h "$popup_height" \
    -T "$popup_title" \
    "$SCRIPTS_DIR/tmux-worktree.sh --prompt"
}

main
