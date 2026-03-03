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

clamp_percent_min() {
  local value="$1"
  local min="$2"
  local raw

  if [[ "$value" =~ ^([0-9]+)%$ ]]; then
    raw="${BASH_REMATCH[1]}"
    if (( raw < min )); then
      printf "%s%%" "$min"
      return
    fi
  fi

  printf "%s" "$value"
}

main() {
  local bind
  local popup_width popup_height popup_title

  bind="$(tmux_option_or_fallback "@worktree-bind" "w")"
  popup_width="$(tmux_option_or_fallback "@worktree-popup-width" "80%")"
  popup_height="$(tmux_option_or_fallback "@worktree-popup-height" "70%")"
  popup_title="$(tmux_option_or_fallback "@worktree-popup-title" "Worktrees")"
  popup_width="$(clamp_percent_min "$popup_width" "70")"
  popup_height="$(clamp_percent_min "$popup_height" "55")"

  tmux bind-key "$bind" display-popup \
    -E \
    -w "$popup_width" \
    -h "$popup_height" \
    -T "$popup_title" \
    "$SCRIPTS_DIR/tmux-worktree.sh --dashboard"
}

main
