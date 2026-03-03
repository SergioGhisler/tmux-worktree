#!/usr/bin/env bash

set -uo pipefail

trim_name() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

sanitize_branch_name() {
  local raw="$1"
  local part cleaned out

  raw="$(trim_name "$raw")"
  out=""

  IFS='/' read -r -a parts <<<"$raw"
  for part in "${parts[@]}"; do
    part="$(trim_name "$part")"
    part="${part// /-}"
    cleaned="$(printf "%s" "$part" | tr -cd '[:alnum:]._-')"
    while [[ "$cleaned" == *--* ]]; do
      cleaned="${cleaned//--/-}"
    done
    cleaned="${cleaned#-}"
    cleaned="${cleaned%-}"
    cleaned="${cleaned#.}"
    cleaned="${cleaned%.}"

    if [[ -n "$cleaned" ]]; then
      if [[ -n "$out" ]]; then
        out+="/"
      fi
      out+="$cleaned"
    fi
  done

  printf "%s" "$out"
}

worktree_dir_name_from_branch() {
  local branch_name="$1"
  local dir_name

  dir_name="${branch_name//\//-}"
  dir_name="${dir_name#.}"
  dir_name="${dir_name%.}"
  dir_name="${dir_name#-}"
  dir_name="${dir_name%-}"

  if [[ -z "$dir_name" ]]; then
    dir_name="worktree"
  fi

  printf "%s" "$dir_name"
}

show_git_error() {
  local message="$1"
  message="${message##*$'\n'}"
  tmux display-message "$message"
}

has_fzf() {
  command -v fzf >/dev/null 2>&1
}

list_local_branches() {
  local repo_root="$1"
  git -C "$repo_root" for-each-ref --format='%(refname:short)' refs/heads
}

branch_exists() {
  local repo_root="$1"
  local branch_name="$2"
  git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch_name"
}

current_branch_name() {
  local repo_root="$1"
  git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$repo_root" rev-parse --short HEAD
}

branch_candidates_for_query() {
  local repo_root="$1"
  local query="${2:-}"
  local branches ranked

  query="$(trim_name "$query")"
  branches="$(list_local_branches "$repo_root")"

  if [[ -n "$query" ]]; then
    printf "%s\n" "$query"
    if [[ -n "$branches" ]]; then
      ranked="$(printf "%s\n" "$branches" | fzf --filter "$query" || true)"
      if [[ -n "$ranked" ]]; then
        printf "%s\n" "$ranked" | awk -v q="$query" 'NF && $0 != q && !seen[$0]++'
      fi
    fi
  else
    printf "%s\n" "$branches"
  fi
}

prompt_target_branch_name() {
  local repo_root="$1"
  local query selected fzf_output script_path_q repo_root_q reload_cmd
  local lines=()

  if has_fzf; then
    script_path_q="$(printf "%q" "${BASH_SOURCE[0]}")"
    repo_root_q="$(printf "%q" "$repo_root")"
    reload_cmd="$script_path_q --branch-candidates $repo_root_q {q}"

    if ! fzf_output="$(fzf --disabled --print-query --height=70% --layout=reverse --border --prompt='Branch> ' --header='First row is exactly what you type. Enter uses it. Move down and Enter to pick existing branch.' --bind "start:reload:$reload_cmd" --bind "change:reload:$reload_cmd" < /dev/null)"; then
      printf ""
      return
    fi

    mapfile -t lines <<<"$fzf_output"
    query="${lines[0]:-}"
    selected="${lines[1]:-}"

    if [[ -n "$selected" ]]; then
      printf "%s" "$selected"
    else
      printf "%s" "$query"
    fi
    return
  fi

  read -r -p "Worktree/branch name: " query
  printf "%s" "$query"
}

select_base_branch() {
  local repo_root="$1"
  local current_branch="$2"
  local selected

  if has_fzf; then
    selected="$(
      {
        printf "%s\n" "$current_branch"
        list_local_branches "$repo_root"
      } | awk 'NF && !seen[$0]++' | fzf --height=70% --layout=reverse --border --prompt='Base> ' --query="$current_branch" --header='Select base branch for new branch (default: current)'
    )"

    if [[ -z "$selected" ]]; then
      printf "%s" "$current_branch"
    else
      printf "%s" "$selected"
    fi
    return
  fi

  read -r -p "Base branch [$current_branch]: " selected
  if [[ -z "$selected" ]]; then
    printf "%s" "$current_branch"
  else
    printf "%s" "$selected"
  fi
}

run_apply_with_spinner() {
  local name="$1"
  local pane_path="$2"
  local base_branch="${3:-}"
  local pid i frame
  local frames=("■□□□□" "■■□□□" "■■■□□" "■■■■□" "■■■■■" "□■■■■" "□□■■■" "□□□■■" "□□□□■")
  local green reset

  green='\033[32m'
  reset='\033[0m'

  "${BASH_SOURCE[0]}" --apply "$name" "$pane_path" "$base_branch" >/dev/null 2>&1 &
  pid=$!
  i=0

  while kill -0 "$pid" 2>/dev/null; do
    frame="${frames[i%${#frames[@]}]}"
    printf "\rProcessing worktree '%s'... ${green}[%s]${reset}" "$name" "$frame"
    sleep 0.1
    i=$((i + 1))
  done

  wait "$pid"
  printf "\r\033[K"
  return $?
}

main() {
  local input_name name pane_path repo_root repo_name worktrees_root worktree_path window_name
  local worktree_dir_name candidate_path path_branch path_try
  local existing_branch_worktree
  local git_err current_branch base_branch
  local mode

  mode="direct"
  if [[ "${1:-}" == "--prompt" ]]; then
    mode="prompt"
    pane_path="$(tmux display-message -p '#{pane_current_path}')"
  elif [[ "${1:-}" == "--apply" ]]; then
    mode="apply"
    input_name="${2:-}"
    pane_path="${3:-$(tmux display-message -p '#{pane_current_path}')}"
    base_branch="${4:-}"
  else
    input_name="${1:-}"
    pane_path="${2:-$(tmux display-message -p '#{pane_current_path}')}"
  fi

  if ! repo_root="$(git -C "$pane_path" rev-parse --show-toplevel 2>/dev/null)"; then
    tmux display-message "Not inside a git repository: $pane_path"
    exit 1
  fi

  current_branch="$(current_branch_name "$repo_root")"

  if [[ "$mode" == "prompt" ]]; then
    input_name="$(prompt_target_branch_name "$repo_root")"
  fi

  input_name="$(trim_name "$input_name")"

  if [[ -z "$input_name" ]]; then
    exit 0
  fi

  name="$(sanitize_branch_name "$input_name")"

  if [[ -z "${input_name//[[:space:]]/}" ]]; then
    tmux display-message "Worktree name is empty"
    exit 0
  fi

  if ! git check-ref-format --branch "$name" >/dev/null 2>&1; then
    tmux display-message "Invalid name: '$input_name'"
    exit 1
  fi

  if [[ "$mode" == "prompt" ]]; then
    if branch_exists "$repo_root" "$name"; then
      base_branch=""
    else
      base_branch="$(select_base_branch "$repo_root" "$current_branch")"
      base_branch="$(sanitize_branch_name "$base_branch")"
      if [[ -z "$base_branch" ]] || ! git check-ref-format --branch "$base_branch" >/dev/null 2>&1; then
        tmux display-message "Invalid base branch: '$base_branch'"
        exit 1
      fi

      if ! branch_exists "$repo_root" "$base_branch"; then
        tmux display-message "Base branch not found: $base_branch"
        exit 1
      fi
    fi

    run_apply_with_spinner "$name" "$pane_path" "$base_branch"
    exit $?
  fi

  repo_name="$(basename "$repo_root")"
  worktrees_root="$(dirname "$repo_root")/${repo_name}-worktrees"
  worktree_dir_name="$(worktree_dir_name_from_branch "$name")"
  worktree_path="$worktrees_root/$worktree_dir_name"
  existing_branch_worktree=""

  mkdir -p "$worktrees_root"

  if [[ -e "$worktree_path" && ! -e "$worktree_path/.git" ]]; then
    tmux display-message "Path exists and is not a worktree: $worktree_path"
    exit 1
  fi

  if [[ -e "$worktree_path/.git" ]]; then
    path_branch="$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$path_branch" != "$name" ]]; then
      path_try=2
      while :; do
        candidate_path="$worktrees_root/${worktree_dir_name}-$path_try"
        if [[ ! -e "$candidate_path" ]]; then
          worktree_path="$candidate_path"
          break
        fi

        if [[ -e "$candidate_path/.git" ]]; then
          path_branch="$(git -C "$candidate_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
          if [[ "$path_branch" == "$name" ]]; then
            worktree_path="$candidate_path"
            break
          fi
        fi

        path_try=$((path_try + 1))
      done
    fi
  fi

  if [[ ! -e "$worktree_path/.git" ]]; then
    if branch_exists "$repo_root" "$name"; then
      existing_branch_worktree="$(git -C "$repo_root" worktree list --porcelain | awk -v branch="refs/heads/$name" '
        /^worktree / { wt=$2 }
        /^branch / && $2 == branch { print wt; exit }
      ')"

      if [[ -n "$existing_branch_worktree" ]]; then
        worktree_path="$existing_branch_worktree"
      elif ! git_err="$(git -C "$repo_root" worktree add "$worktree_path" "$name" 2>&1)"; then
        show_git_error "$git_err"
        exit 1
      fi
    else
      if [[ -z "$base_branch" ]]; then
        base_branch="$current_branch"
      fi

      base_branch="$(sanitize_branch_name "$base_branch")"
      if [[ -z "$base_branch" ]] || ! git check-ref-format --branch "$base_branch" >/dev/null 2>&1; then
        tmux display-message "Invalid base branch: '$base_branch'"
        exit 1
      fi

      if ! branch_exists "$repo_root" "$base_branch"; then
        tmux display-message "Base branch not found: $base_branch"
        exit 1
      fi

      if ! git_err="$(git -C "$repo_root" worktree add -b "$name" "$worktree_path" "$base_branch" 2>&1)"; then
        show_git_error "$git_err"
        exit 1
      fi
    fi
  fi

  window_name="$(basename "$worktree_path")"
  if ! tmux new-window -n "$window_name" -c "$worktree_path"; then
    tmux display-message "Failed to open tmux window '$window_name'"
    exit 1
  fi
}

if [[ "${1:-}" == "--branch-candidates" ]]; then
  branch_candidates_for_query "${2:-}" "${3:-}"
  exit 0
fi

main "$@"
