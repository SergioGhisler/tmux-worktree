#!/usr/bin/env bash

set -uo pipefail

trim_name() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

truncate_for_column() {
  local value="$1"
  local width="$2"

  if (( width < 4 )); then
    printf "%s" "$value"
    return
  fi

  if (( ${#value} > width )); then
    printf "%s..." "${value:0:$((width - 3))}"
  else
    printf "%s" "$value"
  fi
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

list_worktrees_porcelain() {
  local repo_root="$1"
  git -C "$repo_root" worktree list --porcelain
}

list_worktrees_tsv() {
  local repo_root="$1"
  local include_main="${2:-1}"
  local line worktree_path branch_ref branch_name display_name

  worktree_path=""
  branch_ref=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == worktree\ * ]]; then
      if [[ -n "$worktree_path" ]]; then
        if [[ "$include_main" == "1" || "$worktree_path" != "$repo_root" ]]; then
          branch_name="detached"
          if [[ -n "$branch_ref" ]]; then
            branch_name="${branch_ref#refs/heads/}"
          fi
          display_name="$(basename "$worktree_path")"
          printf "%s\t%s\t%s\n" "$display_name" "$branch_name" "$worktree_path"
        fi
      fi

      worktree_path="${line#worktree }"
      branch_ref=""
      continue
    fi

    if [[ "$line" == branch\ * ]]; then
      branch_ref="${line#branch }"
      continue
    fi

    if [[ -z "$line" ]]; then
      if [[ -n "$worktree_path" ]]; then
        if [[ "$include_main" == "1" || "$worktree_path" != "$repo_root" ]]; then
          branch_name="detached"
          if [[ -n "$branch_ref" ]]; then
            branch_name="${branch_ref#refs/heads/}"
          fi
          display_name="$(basename "$worktree_path")"
          printf "%s\t%s\t%s\n" "$display_name" "$branch_name" "$worktree_path"
        fi
      fi

      worktree_path=""
      branch_ref=""
    fi
  done < <(list_worktrees_porcelain "$repo_root"; printf "\n")
}

select_worktree_row() {
  local repo_root="$1"
  local include_main="${2:-1}"
  local prompt_label="${3:-Worktree> }"
  local rows selected fallback_choice fallback_row
  local display_rows display_line short_name short_branch wt_name wt_branch wt_path
  local name_col_width branch_col_width
  local -a row_list=()

  name_col_width=50
  branch_col_width=40

  rows="$(list_worktrees_tsv "$repo_root" "$include_main")"
  if [[ -z "$rows" ]]; then
    printf ""
    return
  fi

  if has_fzf; then
    display_rows=""
    while IFS=$'\t' read -r wt_name wt_branch wt_path; do
      short_name="$(truncate_for_column "$wt_name" "$name_col_width")"
      short_branch="$(truncate_for_column "$wt_branch" "$branch_col_width")"
      display_line="$(printf "%-50s %-40s" "$short_name" "$short_branch")"

      display_rows+="$display_line"
      display_rows+=$'\t'
      display_rows+="$wt_name"
      display_rows+=$'\t'
      display_rows+="$wt_branch"
      display_rows+=$'\t'
      display_rows+="$wt_path"
      display_rows+=$'\n'
    done <<<"$rows"

    selected="$(printf "%s" "$display_rows" | fzf --delimiter=$'\t' --with-nth=1 --height=70% --layout=reverse --border --prompt="$prompt_label" --header='NAME                                               BRANCH' --preview='printf "Name: %s\nBranch: %s\n" {2} {3}' --preview-window=down:3:wrap)"

    if [[ -z "$selected" ]]; then
      printf ""
      return
    fi

    IFS=$'\t' read -r _ wt_name wt_branch wt_path <<<"$selected"
    printf "%s\t%s\t%s" "$wt_name" "$wt_branch" "$wt_path"
    return
  fi

  mapfile -t row_list <<<"$rows"
  printf "%-3s %-50s %-40s\n" "#" "NAME" "BRANCH"

  for i in "${!row_list[@]}"; do
    IFS=$'\t' read -r wt_name wt_branch wt_path <<<"${row_list[$i]}"
    short_name="$(truncate_for_column "$wt_name" "$name_col_width")"
    short_branch="$(truncate_for_column "$wt_branch" "$branch_col_width")"
    printf "%-3s %-50s %-40s\n" "$((i + 1))" "$short_name" "$short_branch"
  done

  read -r -p "Select worktree number: " fallback_choice
  if [[ -z "$fallback_choice" ]] || ! [[ "$fallback_choice" =~ ^[0-9]+$ ]]; then
    printf ""
    return
  fi

  if (( fallback_choice < 1 || fallback_choice > ${#row_list[@]} )); then
    printf ""
    return
  fi

  fallback_row="${row_list[$((fallback_choice - 1))]}"
  printf "%s" "$fallback_row"
}

dashboard_pick_action() {
  local repo_root="$1"
  local query="${2:-}"
  local list_mode="${3:-worktrees}"
  local script_path_q repo_root_q reload_cmd mode_header prompt_label header_text
  local fzf_output key selected_line type wt_name wt_branch wt_path
  local line_count show_bottom_legend
  local -a lines=()

  script_path_q="$(printf "%q" "${BASH_SOURCE[0]}")"
  repo_root_q="$(printf "%q" "$repo_root")"
  reload_cmd="$script_path_q --dashboard-candidates $repo_root_q {q} $list_mode"

  case "$list_mode" in
    worktrees)
      mode_header="MODE: [WORKTREES] - local - remote"
      prompt_label="Worktrees> "
      ;;
    local)
      mode_header="MODE: worktrees - [LOCAL] - remote"
      prompt_label="Local> "
      ;;
    remote)
      mode_header="MODE: worktrees - local - [REMOTE]"
      prompt_label="Remote> "
      ;;
    *)
      mode_header="MODE: [WORKTREES] - local - remote"
      prompt_label="Worktrees> "
      ;;
  esac
  header_text="$mode_header"
  header_text+=$'\n'
  header_text+="NAME                                               BRANCH"

  line_count="${LINES:-0}"
  show_bottom_legend=1
  if (( line_count > 0 && line_count < 10 )); then
    show_bottom_legend=0
  fi

  if (( show_bottom_legend == 1 )); then
    fzf_output="$(fzf --disabled --print-query --expect=enter,ctrl-d,ctrl-r,[,] --query="$query" --delimiter=$'\t' --with-nth=1 --accept-nth=2,3,4,5 --layout=reverse --border --prompt="$prompt_label" --header="$header_text" --bind "start:reload:$reload_cmd" --bind "change:reload:$reload_cmd" --bind 'enter:accept,ctrl-d:accept,ctrl-r:accept,[:accept,]:accept' --preview='printf "enter open/create | ctrl-d delete | ctrl-r fetch | ] next list | [ prev list\n"' --preview-window='down:1:nowrap')" || true
  else
    fzf_output="$(fzf --disabled --print-query --expect=enter,ctrl-d,ctrl-r,[,] --query="$query" --delimiter=$'\t' --with-nth=1 --accept-nth=2,3,4,5 --layout=reverse --border --prompt="$prompt_label" --header="$header_text" --bind "start:reload:$reload_cmd" --bind "change:reload:$reload_cmd" --bind 'enter:accept,ctrl-d:accept,ctrl-r:accept,[:accept,]:accept')" || true
  fi

  mapfile -t lines <<<"$fzf_output"
  key=""
  query=""
  selected_line=""

  for line in "${lines[@]}"; do
    if [[ -z "$key" && "$line" =~ ^(enter|ctrl-d|ctrl-r|\[|\])$ ]]; then
      key="$line"
      continue
    fi

    if [[ -z "$selected_line" && ( "$line" == create$'\t'* || "$line" == worktree$'\t'* || "$line" == branch$'\t'* ) ]]; then
      selected_line="$line"
      continue
    fi

    if [[ -z "$query" ]]; then
      query="$line"
    fi
  done

  if [[ -z "$key" ]]; then
    printf ""
    return
  fi

  if [[ "$query" == *$'\t'* ]] || [[ "$query" =~ ^(enter|ctrl-d|ctrl-r|tab)$ ]]; then
    query=""
  fi

  type=""
  wt_name=""
  wt_branch=""
  wt_path=""
  if [[ -n "$selected_line" ]]; then
    IFS=$'\t' read -r type wt_name wt_branch wt_path <<<"$selected_line"
  fi

  printf "%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s" "$key" "$query" "$type" "$wt_name" "$wt_branch" "$wt_path"
}

dashboard_candidates_for_query() {
  local repo_root="$1"
  local query="${2:-}"
  local list_mode="${3:-worktrees}"
  local rows
  local wt_name wt_branch wt_path
  local short_name short_branch display_line
  local name_col_width branch_col_width
  local query_lower name_lower branch_lower path_lower
  local -A worktree_branches=()
  local branch remote_branch local_name

  name_col_width=50
  branch_col_width=40
  query="$(trim_name "$query")"
  query_lower="${query,,}"

  if [[ -n "$query" ]]; then
    short_name="$(truncate_for_column "$query" "$name_col_width")"
    display_line="$(printf "%-50s %-40s" "$short_name" "new")"
    printf "%s\t%s\t%s\t%s\t%s\n" "$display_line" "create" "$query" "" ""
  fi

  rows="$(list_worktrees_tsv "$repo_root" "1")"

  if [[ -n "$rows" ]]; then
    while IFS=$'\t' read -r wt_name wt_branch wt_path; do
      worktree_branches["$wt_branch"]=1

      # Only display worktree rows in the worktrees tab
      [[ "$list_mode" == "worktrees" ]] || continue

      if [[ -n "$query_lower" ]]; then
        name_lower="${wt_name,,}"
        branch_lower="${wt_branch,,}"
        path_lower="${wt_path,,}"

        if [[ "$name_lower" != *"$query_lower"* && "$branch_lower" != *"$query_lower"* && "$path_lower" != *"$query_lower"* ]]; then
          continue
        fi
      fi

      short_name="$(truncate_for_column "$wt_name" "$name_col_width")"
      short_branch="$(truncate_for_column "$wt_branch" "$branch_col_width")"
      display_line="$(printf "%-50s %-40s" "$short_name" "$short_branch")"

      printf "%s\t%s\t%s\t%s\t%s\n" "$display_line" "worktree" "$wt_name" "$wt_branch" "$wt_path"
    done <<<"$rows"
  fi

  if [[ "$list_mode" == "worktrees" ]]; then
    return
  fi

  if [[ "$list_mode" == "local" ]]; then
    # Local branches without a worktree
    while IFS= read -r branch; do
      [[ -n "$branch" ]] || continue
      [[ -z "${worktree_branches[$branch]+x}" ]] || continue

      if [[ -n "$query_lower" ]]; then
        branch_lower="${branch,,}"
        if [[ "$branch_lower" != *"$query_lower"* ]]; then
          continue
        fi
      fi

      short_name="$(truncate_for_column "$branch" "$name_col_width")"
      short_branch="$(truncate_for_column "local" "$branch_col_width")"
      display_line="$(printf "%-50s %-40s" "$short_name" "$short_branch")"

      printf "%s\t%s\t%s\t%s\t%s\n" "$display_line" "branch" "$branch" "$branch" ""
    done < <(list_local_branches "$repo_root")

    return
  fi

  # Remote branches without a worktree (skip if local equivalent exists)
  while IFS= read -r remote_branch; do
    [[ -n "$remote_branch" ]] || continue
    # Strip remote prefix (e.g., origin/feature -> feature)
    local_name="${remote_branch#*/}"
    [[ -z "${worktree_branches[$local_name]+x}" ]] || continue

    if [[ -n "$query_lower" ]]; then
      branch_lower="${remote_branch,,}"
      if [[ "$branch_lower" != *"$query_lower"* ]]; then
        continue
      fi
    fi

    short_name="$(truncate_for_column "$local_name" "$name_col_width")"
    short_branch="$(truncate_for_column "$remote_branch" "$branch_col_width")"
    display_line="$(printf "%-50s %-40s" "$short_name" "$short_branch")"

    printf "%s\t%s\t%s\t%s\t%s\n" "$display_line" "branch" "$local_name" "$remote_branch" ""
  done < <(list_remote_branches "$repo_root")
}

run_dashboard() {
  local repo_root="$1"
  local pane_path="$2"
  local current_branch="$3"
  local result action query selected_type selected_name selected_branch selected_path
  local list_mode
  local git_err confirm base_for_new

  if ! has_fzf; then
    tmux display-message "Dashboard mode requires fzf"
    return 1
  fi

  query=""
  list_mode="worktrees"
  while :; do
    result="$(dashboard_pick_action "$repo_root" "$query" "$list_mode")"
    if [[ -z "$result" ]]; then
      return 0
    fi

    IFS=$'\x1f' read -r action query selected_type selected_name selected_branch selected_path <<<"$result"
    if [[ "$query" == *$'\x1f'* ]]; then
      query=""
    fi

    case "$action" in
      "]")
        case "$list_mode" in
          worktrees) list_mode="local" ;;
          local) list_mode="remote" ;;
          remote) list_mode="worktrees" ;;
          *) list_mode="worktrees" ;;
        esac
        ;;
      "[")
        case "$list_mode" in
          worktrees) list_mode="remote" ;;
          local) list_mode="worktrees" ;;
          remote) list_mode="local" ;;
          *) list_mode="worktrees" ;;
        esac
        ;;
      ctrl-r)
        printf "\rFetching remotes..."
        if git_err="$(git -C "$repo_root" fetch --all --prune 2>&1)"; then
          printf "\r\033[KFetch complete."
          sleep 0.5
          printf "\r\033[K"
        else
          printf "\r\033[K"
          show_git_error "$git_err"
        fi
        ;;
      ctrl-d)
        if [[ "$selected_type" != "worktree" || -z "$selected_path" ]]; then
          tmux display-message "Select a worktree to delete"
          continue
        fi

        if [[ "$selected_path" == "$repo_root" ]]; then
          tmux display-message "Cannot delete the main repository worktree"
          continue
        fi

        if [[ "$pane_path" == "$selected_path" || "$pane_path" == "$selected_path"/* ]]; then
          tmux display-message "Cannot delete current worktree from inside it"
          continue
        fi

        read -r -p "Delete worktree '$selected_name' [$selected_branch]? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
          continue
        fi

        if ! git_err="$(git -C "$repo_root" worktree remove "$selected_path" 2>&1)"; then
          show_git_error "$git_err"
          continue
        fi

        query=""
        ;;
      enter)
        if [[ "$selected_type" == "worktree" && -n "$selected_path" ]]; then
          open_worktree_window "$selected_path"
          return $?
        fi

        if [[ "$selected_type" == "branch" && -n "$selected_name" ]]; then
          # If the branch ref differs from the name, it's a remote branch —
          # use the remote ref directly as the base (no picker needed).
          if [[ -n "$selected_branch" && "$selected_branch" != "$selected_name" ]]; then
            run_apply_with_spinner "$selected_name" "$pane_path" "$selected_branch"
            return $?
          fi

          if ! base_for_new="$(resolve_base_branch_for_target "$repo_root" "$current_branch" "$selected_name")"; then
            continue
          fi

          run_apply_with_spinner "$selected_name" "$pane_path" "$base_for_new"
          return $?
        fi

        if [[ -z "${query//[[:space:]]/}" ]]; then
          continue
        fi

        if ! base_for_new="$(resolve_base_branch_for_target "$repo_root" "$current_branch" "$query")"; then
          continue
        fi

        run_apply_with_spinner "$query" "$pane_path" "$base_for_new"
        return $?
        ;;
      *)
        continue
        ;;
    esac
  done
}

open_worktree_window() {
  local worktree_path="$1"
  local window_name
  local existing_window

  window_name="$(basename "$worktree_path")"

  # Check if a tmux window already exists for this worktree path
  existing_window="$(tmux list-windows -F '#{window_index} #{pane_current_path}' \
    | awk -v path="$worktree_path" '$2 == path { print $1; exit }')"

  if [[ -n "$existing_window" ]]; then
    tmux select-window -t "$existing_window"
    return 0
  fi

  if ! tmux new-window -n "$window_name" -c "$worktree_path"; then
    tmux display-message "Failed to open tmux window '$window_name'"
    return 1
  fi

  return 0
}

list_local_branches() {
  local repo_root="$1"
  git -C "$repo_root" for-each-ref --format='%(refname:short)' refs/heads
}

list_remote_branches() {
  local repo_root="$1"
  git -C "$repo_root" for-each-ref --format='%(refname:short)' refs/remotes \
    | grep -v '/HEAD$' \
    | grep '/'
}

branch_exists() {
  local repo_root="$1"
  local branch_name="$2"
  git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch_name"
}

remote_branch_exists() {
  local repo_root="$1"
  local branch_name="$2"
  git -C "$repo_root" show-ref --verify --quiet "refs/remotes/$branch_name"
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
  local selected ref ref_type candidates row
  local -A seen=()

  if has_fzf; then
    candidates=""

    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      [[ -z "${seen[$ref]+x}" ]] || continue
      seen["$ref"]=1
      row="$(printf "%-50s %-7s\t%s\t%s\n" "$ref" "local" "$ref" "local")"
      candidates+="$row"
    done < <(
      {
        printf "%s\n" "$current_branch"
        list_local_branches "$repo_root"
      } | awk 'NF'
    )

    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      [[ -z "${seen[$ref]+x}" ]] || continue
      seen["$ref"]=1
      row="$(printf "%-50s %-7s\t%s\t%s\n" "$ref" "remote" "$ref" "remote")"
      candidates+="$row"
    done < <(list_remote_branches "$repo_root")

    if ! selected="$(printf "%s" "$candidates" | fzf --delimiter=$'\t' --with-nth=1 --accept-nth=2,3 --height=70% --layout=reverse --border --prompt='Base> ' --query="$current_branch" --header='Select base branch for new branch. Esc goes back. Type column shows local/remote.' --bind='esc:abort' --preview='printf "Ref: %s\nType: %s\n" {2} {3}' --preview-window=down:2:wrap)"; then
      return 130
    fi

    IFS=$'\t' read -r ref ref_type <<<"$selected"

    if [[ -z "$ref" ]]; then
      return 130
    fi

    printf "%s" "$ref"
    return
  fi

  read -r -p "Base branch [$current_branch]: " selected
  if [[ -z "$selected" ]]; then
    printf "%s" "$current_branch"
  else
    printf "%s" "$selected"
  fi
}

resolve_base_branch_for_target() {
  local repo_root="$1"
  local current_branch="$2"
  local target_name="$3"
  local target_sanitized selected

  target_sanitized="$(sanitize_branch_name "$target_name")"
  if [[ -z "$target_sanitized" ]] || ! git check-ref-format --branch "$target_sanitized" >/dev/null 2>&1; then
    printf ""
    return 0
  fi

  if branch_exists "$repo_root" "$target_sanitized"; then
    printf ""
    return 0
  fi

  selected="$(select_base_branch "$repo_root" "$current_branch")"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    return $rc
  fi

  selected="$(sanitize_branch_name "$selected")"

  if [[ -z "$selected" ]] || ! git check-ref-format --branch "$selected" >/dev/null 2>&1; then
    tmux display-message "Invalid base branch: '$selected'"
    return 1
  fi

  if ! branch_exists "$repo_root" "$selected" && ! remote_branch_exists "$repo_root" "$selected"; then
    tmux display-message "Base branch not found: $selected"
    return 1
  fi

  printf "%s" "$selected"
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
  local input_name name pane_path repo_root repo_name worktrees_root worktree_path
  local worktree_dir_name candidate_path path_branch path_try
  local existing_branch_worktree
  local git_err current_branch base_branch
  local selected_row selected_name selected_branch selected_path confirm
  local mode

  mode="direct"
  if [[ "${1:-}" == "--prompt" ]]; then
    mode="prompt"
    pane_path="$(tmux display-message -p '#{pane_current_path}')"
  elif [[ "${1:-}" == "--dashboard" ]]; then
    mode="dashboard"
    pane_path="$(tmux display-message -p '#{pane_current_path}')"
  elif [[ "${1:-}" == "--list" ]]; then
    mode="list"
    pane_path="$(tmux display-message -p '#{pane_current_path}')"
  elif [[ "${1:-}" == "--delete" ]]; then
    mode="delete"
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

  if [[ "$mode" == "dashboard" ]]; then
    run_dashboard "$repo_root" "$pane_path" "$current_branch"
    exit $?
  fi

  if [[ "$mode" == "list" ]]; then
    selected_row="$(select_worktree_row "$repo_root" "1" "Worktree> ")"
    if [[ -z "$selected_row" ]]; then
      exit 0
    fi

    IFS=$'\t' read -r selected_name selected_branch selected_path <<<"$selected_row"
    if [[ -z "$selected_path" ]]; then
      tmux display-message "No worktree selected"
      exit 1
    fi

    open_worktree_window "$selected_path"
    exit $?
  fi

  if [[ "$mode" == "delete" ]]; then
    selected_row="$(select_worktree_row "$repo_root" "0" "Delete> ")"
    if [[ -z "$selected_row" ]]; then
      exit 0
    fi

    IFS=$'\t' read -r selected_name selected_branch selected_path <<<"$selected_row"
    if [[ -z "$selected_path" ]]; then
      tmux display-message "No worktree selected"
      exit 1
    fi

    if [[ "$pane_path" == "$selected_path" || "$pane_path" == "$selected_path"/* ]]; then
      tmux display-message "Cannot delete current worktree from inside it"
      exit 1
    fi

    read -r -p "Delete worktree '$selected_name' [$selected_branch]? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      exit 0
    fi

    if ! git_err="$(git -C "$repo_root" worktree remove "$selected_path" 2>&1)"; then
      show_git_error "$git_err"
      exit 1
    fi

    tmux display-message "Deleted worktree: $selected_name"
    exit 0
  fi

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
    base_branch="$(resolve_base_branch_for_target "$repo_root" "$current_branch" "$name")"
    case $? in
      0) ;;
      130) exit 0 ;;
      *) exit 1 ;;
    esac

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

      if ! branch_exists "$repo_root" "$base_branch" && ! remote_branch_exists "$repo_root" "$base_branch"; then
        tmux display-message "Base branch not found: $base_branch"
        exit 1
      fi

      if ! git_err="$(git -C "$repo_root" worktree add -b "$name" "$worktree_path" "$base_branch" 2>&1)"; then
        show_git_error "$git_err"
        exit 1
      fi
    fi
  fi

  open_worktree_window "$worktree_path"
}

if [[ "${1:-}" == "--branch-candidates" ]]; then
  branch_candidates_for_query "${2:-}" "${3:-}"
  exit 0
fi

if [[ "${1:-}" == "--dashboard-candidates" ]]; then
  dashboard_candidates_for_query "${2:-}" "${3:-}" "${4:-0}"
  exit 0
fi

main "$@"
