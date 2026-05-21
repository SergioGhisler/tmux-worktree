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

canonical_path() {
  local path="$1"
  (
    cd "$path" 2>/dev/null && pwd -P
  )
}

git_repo_root_for_path() {
  local path="$1"
  git -C "$path" rev-parse --show-toplevel 2>/dev/null
}

workspace_root_from_parent() {
  local parent_path="$1"
  local parent_name

  parent_name="$(basename "$parent_path")"
  printf "%s/%s-workspaces" "$(dirname "$parent_path")" "$parent_name"
}

list_child_repo_roots_tsv() {
  local parent_path="$1"
  local child_path repo_root child_real repo_real child_name

  shopt -s nullglob
  for child_path in "$parent_path"/*; do
    [[ -d "$child_path" ]] || continue

    repo_root="$(git_repo_root_for_path "$child_path")"
    [[ -n "$repo_root" ]] || continue

    child_real="$(canonical_path "$child_path")"
    repo_real="$(canonical_path "$repo_root")"
    [[ -n "$child_real" && -n "$repo_real" ]] || continue
    [[ "$child_real" == "$repo_real" ]] || continue

    child_name="$(basename "$child_path")"
    printf "%s\t%s\n" "$child_name" "$repo_real"
  done
  shopt -u nullglob
}

has_child_git_repos() {
  local parent_path="$1"
  [[ -n "$(list_child_repo_roots_tsv "$parent_path")" ]]
}

list_workspace_rows_tsv() {
  local parent_path="$1"
  local workspace_root workspace_path workspace_name

  workspace_root="$(workspace_root_from_parent "$parent_path")"
  [[ -d "$workspace_root" ]] || return 0

  shopt -s nullglob
  for workspace_path in "$workspace_root"/*; do
    [[ -d "$workspace_path" ]] || continue
    workspace_name="$(basename "$workspace_path")"
    printf "%s\t%s\n" "$workspace_name" "$workspace_path"
  done
  shopt -u nullglob
}

maybe_delete_local_branch() {
  local repo_root="$1"
  local branch_name="$2"
  local confirm force_confirm git_err

  if [[ -z "$branch_name" || "$branch_name" == "detached" ]]; then
    return 0
  fi

  if ! branch_exists "$repo_root" "$branch_name"; then
    return 0
  fi

  read -r -p "Also delete local branch '$branch_name'? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    return 0
  fi

  if git_err="$(git -C "$repo_root" branch -d "$branch_name" 2>&1)"; then
    return 0
  fi

  read -r -p "Branch '$branch_name' is not merged. Force delete? [y/N]: " force_confirm
  if [[ ! "$force_confirm" =~ ^[Yy]$ ]]; then
    show_git_error "$git_err"
    return 0
  fi

  if ! git_err="$(git -C "$repo_root" branch -D "$branch_name" 2>&1)"; then
    show_git_error "$git_err"
    return 0
  fi

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

workspace_dashboard_pick_action() {
  local parent_path="$1"
  local query="${2:-}"
  local script_path_q parent_path_q reload_cmd header_text prompt_label fzf_output
  local key selected_line line
  local -a lines=()

  script_path_q="$(printf "%q" "${BASH_SOURCE[0]}")"
  parent_path_q="$(printf "%q" "$parent_path")"
  reload_cmd="$script_path_q --workspace-dashboard-candidates $parent_path_q {q}"
  header_text=$'MODE: [WORKSPACES]\nNAME                                               BRANCH'
  prompt_label="Workspaces> "

  fzf_output="$(fzf --disabled --print-query --expect=enter --query="$query" --delimiter=$'\t' --with-nth=1 --accept-nth=2,3,4,5 --layout=reverse --border --prompt="$prompt_label" --header="$header_text" --bind "start:reload:$reload_cmd" --bind "change:reload:$reload_cmd" --bind 'enter:accept' --preview='printf "enter open/create coordinated workspace\n"' --preview-window='down:1:nowrap')" || true

  mapfile -t lines <<<"$fzf_output"
  key=""
  query=""
  selected_line=""

  for line in "${lines[@]}"; do
    if [[ -z "$key" && "$line" == "enter" ]]; then
      key="$line"
      continue
    fi

    if [[ -z "$selected_line" && ( "$line" == create$'\t'* || "$line" == workspace$'\t'* ) ]]; then
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

  if [[ "$query" == *$'\t'* ]] || [[ "$query" == "enter" ]]; then
    query=""
  fi

  local type name branch path
  type=""
  name=""
  branch=""
  path=""
  if [[ -n "$selected_line" ]]; then
    IFS=$'\t' read -r type name branch path <<<"$selected_line"
  fi

  printf "%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s" "$key" "$query" "$type" "$name" "$branch" "$path"
}

workspace_dashboard_candidates_for_query() {
  local parent_path="$1"
  local query="${2:-}"
  local rows workspace_name workspace_path short_name display_line
  local name_col_width branch_col_width query_lower name_lower path_lower

  name_col_width=50
  branch_col_width=40
  query="$(trim_name "$query")"
  query_lower="${query,,}"

  if [[ -n "$query" ]]; then
    short_name="$(truncate_for_column "$query" "$name_col_width")"
    display_line="$(printf "%-50s %-40s" "$short_name" "new")"
    printf "%s\t%s\t%s\t%s\t%s\n" "$display_line" "create" "$query" "" ""
  fi

  rows="$(list_workspace_rows_tsv "$parent_path")"
  [[ -n "$rows" ]] || return 0

  while IFS=$'\t' read -r workspace_name workspace_path; do
    [[ -n "$workspace_name" ]] || continue

    if [[ -n "$query_lower" ]]; then
      name_lower="${workspace_name,,}"
      path_lower="${workspace_path,,}"
      if [[ "$name_lower" != *"$query_lower"* && "$path_lower" != *"$query_lower"* ]]; then
        continue
      fi
    fi

    short_name="$(truncate_for_column "$workspace_name" "$name_col_width")"
    display_line="$(printf "%-50s %-40s" "$short_name" "$workspace_name")"
    printf "%s\t%s\t%s\t%s\t%s\n" "$display_line" "workspace" "$workspace_name" "$workspace_name" "$workspace_path"
  done <<<"$rows"
}

run_workspace_dashboard() {
  local parent_path="$1"
  local result action query selected_type selected_name selected_branch selected_path

  if ! has_fzf; then
    tmux display-message "Dashboard mode requires fzf"
    return 1
  fi

  query=""
  while :; do
    result="$(workspace_dashboard_pick_action "$parent_path" "$query")"
    if [[ -z "$result" ]]; then
      return 0
    fi

    IFS=$'\x1f' read -r action query selected_type selected_name selected_branch selected_path <<<"$result"
    [[ "$query" == *$'\x1f'* ]] && query=""

    case "$action" in
      enter)
        if [[ "$selected_type" == "workspace" && -n "$selected_path" ]]; then
          open_worktree_window "$selected_path"
          return $?
        fi

        if [[ -z "${query//[[:space:]]/}" ]]; then
          continue
        fi

        run_apply_with_spinner "$query" "$parent_path"
        return $?
        ;;
      *)
        continue
        ;;
    esac
  done
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

        maybe_delete_local_branch "$repo_root" "$selected_branch"

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
            prepare_new_worktree_setup "$repo_root" "$selected_name"
            run_apply_with_spinner "$selected_name" "$pane_path" "$selected_branch" "$WORKTREE_COPY_FILES" "$WORKTREE_USE_CODEX_SETUP"
            return $?
          fi

          if ! base_for_new="$(resolve_base_branch_for_target "$repo_root" "$current_branch" "$selected_name")"; then
            continue
          fi

          prepare_new_worktree_setup "$repo_root" "$selected_name"
          run_apply_with_spinner "$selected_name" "$pane_path" "$base_for_new" "$WORKTREE_COPY_FILES" "$WORKTREE_USE_CODEX_SETUP"
          return $?
        fi

        if [[ -z "${query//[[:space:]]/}" ]]; then
          continue
        fi

        if ! base_for_new="$(resolve_base_branch_for_target "$repo_root" "$current_branch" "$query")"; then
          continue
        fi

        prepare_new_worktree_setup "$repo_root" "$(sanitize_branch_name "$query")"
        run_apply_with_spinner "$query" "$pane_path" "$base_for_new" "$WORKTREE_COPY_FILES" "$WORKTREE_USE_CODEX_SETUP"
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

list_git_ignored_files() {
  local repo_root="$1"
  git -C "$repo_root" ls-files --others --ignored --exclude-standard --directory \
    | sed 's|/$||' \
    | sort
}

select_ignored_files() {
  local repo_root="$1"
  local ignored_files selected
  local -a numbered_files=()
  local i choice

  ignored_files="$(list_git_ignored_files "$repo_root")"

  if [[ -z "$ignored_files" ]]; then
    printf "No ignored files to copy.\n" >&2
    printf ""
    return
  fi

  if has_fzf; then
    selected="$(printf "%s\n" "$ignored_files" \
      | fzf --multi --layout=reverse --border \
        --prompt='Copy to worktree> ' \
        --header='Select ignored files/dirs to copy (TAB toggle, ENTER confirm, ESC skip)' \
        --bind 'ctrl-a:toggle-all' \
      )" || true

    printf "%s" "$selected"
    return
  fi

  # Fallback: numbered list with read prompt
  mapfile -t numbered_files <<<"$ignored_files"
  printf "\nIgnored files/dirs:\n"
  for i in "${!numbered_files[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${numbered_files[$i]}"
  done
  printf "\nEnter numbers to copy (comma-separated, 'a' for all, empty to skip): "
  read -r choice

  if [[ -z "$choice" ]]; then
    printf ""
    return
  fi

  if [[ "$choice" == "a" || "$choice" == "A" ]]; then
    printf "%s" "$ignored_files"
    return
  fi

  local result=""
  IFS=',' read -r -a indices <<<"$choice"
  for i in "${indices[@]}"; do
    i="$(trim_name "$i")"
    if [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#numbered_files[@]} )); then
      if [[ -n "$result" ]]; then
        result+=$'\n'
      fi
      result+="${numbered_files[$((i - 1))]}"
    fi
  done

  printf "%s" "$result"
}

copy_ignored_files_to_worktree() {
  local repo_root="$1"
  local worktree_path="$2"
  local files_list="$3"
  local file target_dir

  if [[ -z "$files_list" ]]; then
    return 0
  fi

  printf "Copying selected ignored files...\n"

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue

    if [[ -d "$repo_root/$file" ]]; then
      target_dir="$worktree_path/$file"
      mkdir -p "$target_dir"
      cp -R "$repo_root/$file/." "$target_dir/"
    elif [[ -f "$repo_root/$file" ]]; then
      target_dir="$(dirname "$worktree_path/$file")"
      mkdir -p "$target_dir"
      cp "$repo_root/$file" "$worktree_path/$file"
    fi
  done <<<"$files_list"
}

extract_codex_setup_script() {
  local env_path="$1"

  awk '
    BEGIN { open = sprintf("%c%c%c", 39, 39, 39) }
    /^[[:space:]]*\[setup\][[:space:]]*(#.*)?$/ { in_setup = 1; next }
    /^[[:space:]]*\[[^]]+\]/ { in_setup = 0 }
    !in_setup { next }

    !in_script && $0 ~ /^[[:space:]]*script[[:space:]]*=/ {
      line = $0
      sub(/^[[:space:]]*script[[:space:]]*=[[:space:]]*/, "", line)
      if (index(line, open) != 1) {
        next
      }

      line = substr(line, 4)
      close_at = index(line, open)
      if (close_at) {
        print substr(line, 1, close_at - 1)
        found = 1
        exit
      }

      print line
      in_script = 1
      next
    }

    in_script {
      close_at = index($0, open)
      if (close_at) {
        print substr($0, 1, close_at - 1)
        found = 1
        exit
      }

      print
    }

    END { if (!found) exit 1 }
  ' "$env_path"
}

run_codex_environment_setup() {
  local repo_root="$1"
  local worktree_path="$2"
  local env_path setup_script

  env_path="$repo_root/.codex/environments/environment.toml"
  if [[ ! -f "$env_path" ]]; then
    return 0
  fi

  if ! setup_script="$(extract_codex_setup_script "$env_path")"; then
    tmux display-message "Codex setup script not found: $env_path" || true
    return 1
  fi

  printf "Running Codex environment setup: %s\n" "$env_path"
  if ! (
    cd "$worktree_path" && \
      CODEX_SOURCE_TREE_PATH="$repo_root" \
      CODEX_WORKTREE_PATH="$worktree_path" \
      bash -c "$setup_script"
  ); then
    tmux display-message "Codex setup failed: $(basename "$worktree_path")" || true
    return 1
  fi

  printf "Codex environment setup completed.\n"
}

has_codex_environment_config() {
  local repo_root="$1"
  [[ -f "$repo_root/.codex/environments/environment.toml" ]]
}

prompt_use_codex_environment_setup() {
  local repo_root="$1"
  local env_path confirm

  env_path="$repo_root/.codex/environments/environment.toml"
  read -r -p "Use Codex environment setup from $env_path? [Y/n]: " confirm
  [[ -z "$confirm" || "$confirm" =~ ^[Yy]$ ]]
}

branch_has_worktree() {
  local repo_root="$1"
  local branch_name="$2"
  local wt

  wt="$(git -C "$repo_root" worktree list --porcelain | awk -v branch="refs/heads/$branch_name" '
    /^worktree / { wt=$2 }
    /^branch / && $2 == branch { print wt; exit }
  ')"

  [[ -n "$wt" ]]
}

prepare_new_worktree_setup() {
  local repo_root="$1"
  local branch_name="$2"

  WORKTREE_USE_CODEX_SETUP=0
  WORKTREE_COPY_FILES=""

  # Skip if branch already has a worktree (nothing new will be created)
  if branch_exists "$repo_root" "$branch_name" && branch_has_worktree "$repo_root" "$branch_name"; then
    return
  fi

  if has_codex_environment_config "$repo_root"; then
    if prompt_use_codex_environment_setup "$repo_root"; then
      WORKTREE_USE_CODEX_SETUP=1
      return
    fi
  else
    printf "No Codex environment config found; showing ignored-files copy picker.\n" >&2
  fi

  WORKTREE_COPY_FILES="$(select_ignored_files "$repo_root")"
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

create_multi_repo_workspace() {
  local parent_path="$1"
  local input_name="$2"
  local name workspace_root workspace_path rows
  local repo_name repo_root current_ref target_path path_branch existing_branch_worktree git_err
  local cleanup_needed=0
  local -a created_repos=() created_paths=()

  input_name="$(trim_name "$input_name")"
  if [[ -z "${input_name//[[:space:]]/}" ]]; then
    tmux display-message "Workspace name is empty"
    return 0
  fi

  name="$(sanitize_branch_name "$input_name")"
  if [[ -z "$name" ]] || ! git check-ref-format --branch "$name" >/dev/null 2>&1; then
    tmux display-message "Invalid name: '$input_name'"
    return 1
  fi

  rows="$(list_child_repo_roots_tsv "$parent_path")"
  if [[ -z "$rows" ]]; then
    tmux display-message "No direct child git repositories found"
    return 1
  fi

  workspace_root="$(workspace_root_from_parent "$parent_path")"
  workspace_path="$workspace_root/$(worktree_dir_name_from_branch "$name")"

  while IFS=$'\t' read -r repo_name repo_root; do
    [[ -n "$repo_name" && -n "$repo_root" ]] || continue
    target_path="$workspace_path/$repo_name"

    if [[ -e "$target_path" && ! -e "$target_path/.git" ]]; then
      tmux display-message "Path exists and is not a worktree: $target_path"
      return 1
    fi

    if [[ -e "$target_path/.git" ]]; then
      path_branch="$(git -C "$target_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
      if [[ "$path_branch" != "$name" ]]; then
        tmux display-message "Path already used by different branch: $target_path"
        return 1
      fi
    fi

    if branch_exists "$repo_root" "$name"; then
      existing_branch_worktree="$(git -C "$repo_root" worktree list --porcelain | awk -v branch="refs/heads/$name" '
        /^worktree / { wt=$2 }
        /^branch / && $2 == branch { print wt; exit }
      ')"

      if [[ -n "$existing_branch_worktree" ]]; then
        existing_branch_worktree="$(canonical_path "$existing_branch_worktree")"
        if [[ "$existing_branch_worktree" != "$target_path" ]]; then
          tmux display-message "Branch '$name' already has a worktree in $repo_name"
          return 1
        fi
      fi
    fi
  done <<<"$rows"

  mkdir -p "$workspace_root" "$workspace_path"

  while IFS=$'\t' read -r repo_name repo_root; do
    [[ -n "$repo_name" && -n "$repo_root" ]] || continue
    target_path="$workspace_path/$repo_name"

    if [[ -e "$target_path/.git" ]]; then
      printf "Using existing worktree for %s: %s\n" "$repo_name" "$target_path"
      continue
    fi

    printf "Creating worktree for %s: %s\n" "$repo_name" "$target_path"
    if branch_exists "$repo_root" "$name"; then
      if ! git_err="$(git -C "$repo_root" worktree add "$target_path" "$name" 2>&1)"; then
        show_git_error "$git_err"
        cleanup_needed=1
        break
      fi
    else
      current_ref="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null || printf "HEAD")"
      if ! git_err="$(git -C "$repo_root" worktree add -b "$name" "$target_path" "$current_ref" 2>&1)"; then
        show_git_error "$git_err"
        cleanup_needed=1
        break
      fi
    fi

    created_repos+=("$repo_root")
    created_paths+=("$target_path")

    if ! run_codex_environment_setup "$repo_root" "$target_path"; then
      cleanup_needed=1
      break
    fi
  done <<<"$rows"

  if [[ "$cleanup_needed" == "1" ]]; then
    local i
    for i in "${!created_paths[@]}"; do
      git -C "${created_repos[$i]}" worktree remove --force "${created_paths[$i]}" >/dev/null 2>&1 || true
    done
    rmdir "$workspace_path" >/dev/null 2>&1 || true
    return 1
  fi

  open_worktree_window "$workspace_path"
}

run_apply_with_spinner() {
  local name="$1"
  local pane_path="$2"
  local base_branch="${3:-}"
  local copy_files="${4:-}"
  local use_codex_setup="${5:-auto}"

  printf "Processing worktree '%s'...\n" "$name"
  "${BASH_SOURCE[0]}" --apply "$name" "$pane_path" "$base_branch" "$copy_files" "$use_codex_setup"
}

main() {
  local input_name name pane_path repo_root repo_name worktrees_root worktree_path
  local worktree_dir_name candidate_path path_branch path_try
  local existing_branch_worktree
  local git_err current_branch base_branch copy_files use_codex_setup
  local selected_row selected_name selected_branch selected_path confirm
  local mode parent_path

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
    copy_files="${5:-}"
    use_codex_setup="${6:-auto}"
  else
    input_name="${1:-}"
    pane_path="${2:-$(tmux display-message -p '#{pane_current_path}')}"
  fi

  repo_root="$(git_repo_root_for_path "$pane_path")"
  if [[ -z "$repo_root" ]]; then
    parent_path="$(canonical_path "$pane_path")"

    if [[ -z "$parent_path" || ! -d "$parent_path" ]]; then
      tmux display-message "Not inside a git repository: $pane_path"
      exit 1
    fi

    if ! has_child_git_repos "$parent_path"; then
      tmux display-message "Not inside a git repository: $pane_path"
      exit 1
    fi

    case "$mode" in
      dashboard)
        run_workspace_dashboard "$parent_path"
        exit $?
        ;;
      prompt)
        read -r -p "Workspace/branch name: " input_name
        ;;
      apply|direct)
        ;;
      *)
        tmux display-message "This action requires being inside a git repository"
        exit 1
        ;;
    esac

    input_name="$(trim_name "$input_name")"
    if [[ -z "$input_name" ]]; then
      exit 0
    fi

    create_multi_repo_workspace "$parent_path" "$input_name"
    exit $?
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

    maybe_delete_local_branch "$repo_root" "$selected_branch"

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

    prepare_new_worktree_setup "$repo_root" "$name"
    run_apply_with_spinner "$name" "$pane_path" "$base_branch" "$WORKTREE_COPY_FILES" "$WORKTREE_USE_CODEX_SETUP"
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
        printf "Branch already has a worktree: %s\n" "$existing_branch_worktree"
        worktree_path="$existing_branch_worktree"
      else
        printf "Creating worktree: %s\n" "$worktree_path"
        if ! git_err="$(git -C "$repo_root" worktree add "$worktree_path" "$name" 2>&1)"; then
          show_git_error "$git_err"
          exit 1
        fi

        copy_ignored_files_to_worktree "$repo_root" "$worktree_path" "${copy_files:-}"
        if [[ "${use_codex_setup:-auto}" != "0" ]] && ! run_codex_environment_setup "$repo_root" "$worktree_path"; then
          exit 1
        fi
      fi
    else
      if [[ -z "${base_branch:-}" ]]; then
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

      printf "Creating worktree: %s from %s\n" "$worktree_path" "$base_branch"
      if ! git_err="$(git -C "$repo_root" worktree add -b "$name" "$worktree_path" "$base_branch" 2>&1)"; then
        show_git_error "$git_err"
        exit 1
      fi

      copy_ignored_files_to_worktree "$repo_root" "$worktree_path" "${copy_files:-}"
      if [[ "${use_codex_setup:-auto}" != "0" ]] && ! run_codex_environment_setup "$repo_root" "$worktree_path"; then
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

if [[ "${1:-}" == "--workspace-dashboard-candidates" ]]; then
  workspace_dashboard_candidates_for_query "${2:-}" "${3:-}"
  exit 0
fi

main "$@"
