# termpeek.zsh
# Fast live history keyword suggestions for Zsh
# Repository: https://github.com/zerakjamil/termpeek
# License: MIT

export KEYTIMEOUT=${KEYTIMEOUT:-10}

# User-configurable settings
TERMPEEK_MAX_RESULTS=${TERMPEEK_MAX_RESULTS:-4}
TERMPEEK_POINTER=${TERMPEEK_POINTER:-▶}
TERMPEEK_SHOW_HINTS=${TERMPEEK_SHOW_HINTS:-1}
TERMPEEK_ONLY_SUCCESSFUL=${TERMPEEK_ONLY_SUCCESSFUL:-1}
TERMPEEK_RECIPES=${TERMPEEK_RECIPES:-1}
TERMPEEK_PROJECT_TASKS=${TERMPEEK_PROJECT_TASKS:-1}
TERMPEEK_SAFETY_GUARD=${TERMPEEK_SAFETY_GUARD:-1}
TERMPEEK_MASK_SECRETS=${TERMPEEK_MASK_SECRETS:-1}

typeset -ga _termpeek_matches
typeset -gi _termpeek_idx=0
typeset -gA _termpeek_tag_map
typeset -ga _termpeek_project_tasks
typeset -g _termpeek_last_buf=""
typeset -g _termpeek_dismissed_buf=""
typeset -g _termpeek_db="$HOME/.local/share/atuin/history.db"
typeset -g _termpeek_cached_pwd=""
typeset -g _termpeek_git_root=""

typeset -ga _termpeek_curated_recipes=(
  "tar -czvf archive.tar.gz <folder>"
  "tar -xzvf archive.tar.gz"
  "rsync -avz --progress <src>/ <dest>/"
  "ffmpeg -i input.mp4 -c:v libx264 -crf 23 output.mp4"
  "ffmpeg -i input.mp4 -vn -c:a copy output.aac"
  "find . -type f -name '*.log' -delete"
  "find . -type f -size +100M"
  "docker stop \$(docker ps -aq)"
  "docker system prune -a --volumes"
  "git log --oneline --graph --decorate --all"
  "git commit --amend --no-edit"
  "git reset --soft HEAD~1"
  "curl -fsSL <url> | bash"
  "chmod +x <file>"
  "python3 -m http.server 8000"
  "lsof -i :8000"
  "kill -9 \$(lsof -t -i :8000)"
  "grep -rnw . -e 'pattern'"
  "ssh -i ~/.ssh/key.pem user@host"
  "du -sh * | sort -hr"
)

_termpeek_load_project_tasks() {
  _termpeek_project_tasks=()
  (( ${TERMPEEK_PROJECT_TASKS:-1} == 1 )) || return 0

  local runner="npm" script="" target=""

  # Node / JavaScript / TypeScript projects
  if [[ -f package.json ]]; then
    [[ -f pnpm-lock.yaml ]] && runner="pnpm"
    [[ -f yarn.lock ]] && runner="yarn"
    [[ -f bun.lockb || -f bun.lock ]] && runner="bun"
    while IFS= read -r script; do
      [[ -n "$script" ]] || continue
      if [[ "$runner" == "npm" && ("$script" == "test" || "$script" == "start") ]]; then
        _termpeek_project_tasks+=("npm $script")
      else
        _termpeek_project_tasks+=("$runner run $script")
      fi
    done < <(awk -F'"' '/"scripts": *\{/{flag=1; next} flag && /\}/{flag=0} flag && /"[^"]+":/{print $2}' package.json 2>/dev/null)
  fi

  # Makefiles
  if [[ -f Makefile || -f makefile ]]; then
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      _termpeek_project_tasks+=("make $target")
    done < <(awk -F':' '/^[a-zA-Z0-9_-]+:/ && !/^\.PHONY/ && !/^all/ {print $1}' Makefile makefile 2>/dev/null)
  fi

  # Rust projects
  if [[ -f Cargo.toml ]]; then
    _termpeek_project_tasks+=("cargo build" "cargo test" "cargo run" "cargo check")
  fi

  # Docker compose
  if [[ -f docker-compose.yml || -f compose.yaml ]]; then
    _termpeek_project_tasks+=("docker compose up" "docker compose down" "docker compose ps")
  fi

  # Python projects
  if [[ -f pyproject.toml || -f Pipfile || -f requirements.txt ]]; then
    _termpeek_project_tasks+=("pytest" "ruff check .")
  fi
}

_termpeek_update_dir_cache() {
  if [[ "$PWD" != "$_termpeek_cached_pwd" ]]; then
    _termpeek_cached_pwd="$PWD"
    _termpeek_git_root="$(git rev-parse --show-toplevel 2>/dev/null)"
    _termpeek_load_project_tasks
  fi
}

_termpeek_is_dangerous() {
  local cmd="$1"
  (( ${TERMPEEK_SAFETY_GUARD:-1} == 1 )) || return 1
  case "$cmd" in
    rm\ *-[a-zA-Z0-9]*r*|rm\ *--recursive*|rm\ *-[a-zA-Z0-9]*f*) return 0 ;;
    git\ reset\ --hard*|git\ clean\ *-[a-zA-Z0-9]*f*|git\ branch\ -D*) return 0 ;;
    git\ push\ *--force*|git\ push\ *-f*|git\ push\ *+*:*) return 0 ;;
    git\ checkout\ --\ .|git\ restore\ .) return 0 ;;
    kubectl\ delete*|helm\ uninstall*) return 0 ;;
    docker\ system\ prune*|docker\ rm\ *-[a-zA-Z0-9]*f*) return 0 ;;
    *drop\ database*|*drop\ table*|*DROP\ DATABASE*|*DROP\ TABLE*) return 0 ;;
    mkfs*|dd\ if=*) return 0 ;;
    killall\ *|kill\ -9\ -1*) return 0 ;;
    chmod\ *-R\ 777*) return 0 ;;
  esac
  return 1
}

_termpeek_has_secret() {
  local cmd="$1"
  (( ${TERMPEEK_MASK_SECRETS:-1} == 1 )) || return 1
  if [[ "$cmd" == *(sk-|ghp_|gho_|github_pat_|Bearer|AKIA|password=|token=|secret=)* ]]; then
    return 0
  fi
  return 1
}

_termpeek_sanitize_display() {
  local cmd="$1"
  if _termpeek_has_secret "$cmd"; then
    print -r -- "$cmd" | sed -E \
      -e 's/(sk-[a-zA-Z0-9_\-]{4})[a-zA-Z0-9_\-]+/\1****[REDACTED]/g' \
      -e 's/(gh[po]_[a-zA-Z0-9]{4})[a-zA-Z0-9]+/\1****[REDACTED]/g' \
      -e 's/(Bearer )[a-zA-Z0-9_\.\-]{8,}/\1****[REDACTED]/g' \
      -e 's/(AKIA[0-9A-Z]{4})[0-9A-Z]+/\1****[REDACTED]/g' \
      -e 's/((password|token|secret)=)[^ &"'\''`]+/\1****[REDACTED]/g'
  else
    print -r -- "$cmd"
  fi
}

_termpeek_get_tags() {
  local item="$1"
  local tags=""
  if [[ -n "${_termpeek_tag_map[$item]}" ]]; then
    tags+=" ${_termpeek_tag_map[$item]}"
  fi
  if _termpeek_is_dangerous "$item"; then
    tags+=" [DANGER]"
  fi
  if _termpeek_has_secret "$item"; then
    tags+=" [SECRET]"
  fi
  print -r -- "$tags"
}

_termpeek_render() {
  if (( ${#_termpeek_matches[@]} == 0 )); then
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    return
  fi
  local ghost="${POSTDISPLAY%%$'\n'*}"
  local out=""
  local i=1
  local max_w=$(( COLUMNS > 25 ? COLUMNS - 15 : 65 ))
  local pointer="${TERMPEEK_POINTER:-▶}"
  local show_hints=${TERMPEEK_SHOW_HINTS:-1}

  for (( i=1; i<=${#_termpeek_matches[@]}; i++ )); do
    local item="${_termpeek_matches[$i]}"
    local tags="$(_termpeek_get_tags "$item")"
    local display_item="$(_termpeek_sanitize_display "$item")"
    (( $#display_item > max_w )) && display_item="${display_item[1,$max_w]}..."

    if (( i == _termpeek_idx )); then
      local hint=""
      if (( show_hints == 1 )); then
        if _termpeek_is_dangerous "$item"; then
          hint="  (Tab: edit | Enter: review | Esc: close)"
        else
          hint="  (Tab: selected | →: first | Enter: run | Esc: close)"
        fi
      fi
      out+=$'\n'"$pointer [$i] $display_item$tags$hint"
    else
      local hint=""
      if (( i == 1 && _termpeek_idx == 0 && show_hints == 1 )); then
        hint="  (→: first | Tab: complete)"
      fi
      out+=$'\n'"  [$i] $display_item$tags$hint"
    fi
  done
  POSTDISPLAY="${ghost}${out}"
}

_termpeek_query() {
  local buf="$1"
  local trimmed="${buf## #}"
  trimmed="${trimmed%% #}"

  if [[ ${#trimmed} -lt 2 || "$buf" == "$_termpeek_dismissed_buf" ]]; then
    _termpeek_matches=()
    _termpeek_idx=0
    _termpeek_tag_map=()
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    return
  fi

  _termpeek_matches=()
  _termpeek_tag_map=()

  local max_res=${TERMPEEK_MAX_RESULTS:-4}
  local only_succ=${TERMPEEK_ONLY_SUCCESSFUL:-1}
  local use_recipes=${TERMPEEK_RECIPES:-1}
  local recipe="" lower_trim="" lower_recipe="" existing="" line="" task="" lower_task=""
  local already=0

  _termpeek_update_dir_cache

  # Step 1: Matching project tasks (package.json, Makefile, etc.)
  if (( ${#_termpeek_project_tasks[@]} > 0 )); then
    lower_trim="${(L)trimmed}"
    for task in "${_termpeek_project_tasks[@]}"; do
      lower_task="${(L)task}"
      if [[ "$lower_task" == *"$lower_trim"* ]]; then
        _termpeek_matches+=("$task")
        _termpeek_tag_map[$task]="[project]"
        (( ${#_termpeek_matches[@]} >= max_res )) && break
      fi
    done
  fi

  # Step 2: History lookup if slots remain
  if (( ${#_termpeek_matches[@]} < max_res )); then
    if [[ -f "$_termpeek_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
      local escaped="${trimmed//\"/\"\"}"
      local pwd_escaped="${PWD//\"/\"\"}"
      local git_escaped="${_termpeek_git_root//\"/\"\"}"

      local exit_clause=""
      if (( only_succ == 1 )); then
        exit_clause="AND (exit <= 0)"
      fi

      local git_clause="0"
      if [[ -n "$git_escaped" ]]; then
        git_clause="CASE WHEN cwd LIKE \"$git_escaped%\" THEN 432000 ELSE 0 END"
      fi

      local sql="
        SELECT replace(replace(command, char(13), ''), char(10), ' && ') AS clean_cmd
        FROM history
        WHERE command LIKE \"%$escaped%\" AND deleted_at IS NULL $exit_clause
        GROUP BY clean_cmd
        ORDER BY ((CASE WHEN cwd = \"$pwd_escaped\" THEN 864000 ELSE $git_clause END) +
                  (count(*) * 86400) +
                  (max(timestamp) / 1000000000)) DESC
        LIMIT $max_res;
      "

      while IFS= read -r line; do
        line="${line%% && }"
        line="${line## #}"
        line="${line%% #}"
        if [[ -n "$line" && "$line" != "$trimmed" ]]; then
          already=0
          for existing in "${_termpeek_matches[@]}"; do
            if [[ "$existing" == "$line" ]]; then
              already=1
              break
            fi
          done
          if (( already == 0 )); then
            _termpeek_matches+=("$line")
            (( ${#_termpeek_matches[@]} >= max_res )) && break
          fi
        fi
      done < <(sqlite3 "$_termpeek_db" "$sql" 2>/dev/null)
    else
      # Native zsh history fallback
      local -A seen
      while IFS= read -r line; do
        line="${line## #}"
        line="${line%% #}"
        if [[ -n "$line" && "$line" != "$trimmed" && -z "${seen[$line]}" ]]; then
          seen[$line]=1
          already=0
          for existing in "${_termpeek_matches[@]}"; do
            if [[ "$existing" == "$line" ]]; then
              already=1
              break
            fi
          done
          if (( already == 0 )); then
            _termpeek_matches+=("$line")
            (( ${#_termpeek_matches[@]} >= max_res )) && break
          fi
        fi
      done < <(fc -l -n -r 1 2000 2>/dev/null | grep -F -i "$trimmed" 2>/dev/null)
    fi
  fi

  # Step 3: Recipe fallback if slots still remain
  if (( use_recipes == 1 && ${#_termpeek_matches[@]} < max_res )); then
    lower_trim="${(L)trimmed}"
    for recipe in "${_termpeek_curated_recipes[@]}"; do
      lower_recipe="${(L)recipe}"
      if [[ "$lower_recipe" == *"$lower_trim"* ]]; then
        already=0
        for existing in "${_termpeek_matches[@]}"; do
          if [[ "$existing" == "$recipe" ]]; then
            already=1
            break
          fi
        done
        if (( already == 0 )); then
          _termpeek_matches+=("$recipe")
          _termpeek_tag_map[$recipe]="[recipe]"
          (( ${#_termpeek_matches[@]} >= max_res )) && break
        fi
      fi
    done
  fi

  _termpeek_idx=0
  _termpeek_render
}

_termpeek_pre_redraw() {
  if [[ "$BUFFER" != "$_termpeek_last_buf" ]]; then
    _termpeek_last_buf="$BUFFER"
    if [[ "$BUFFER" != "$_termpeek_dismissed_buf" ]]; then
      _termpeek_dismissed_buf=""
      _termpeek_query "$BUFFER"
    fi
  fi
  if (( ${#_termpeek_matches[@]} > 0 )); then
    _termpeek_render
  fi
}

_termpeek_down() {
  if (( ${#_termpeek_matches[@]} > 0 )); then
    if (( _termpeek_idx < ${#_termpeek_matches[@]} )); then
      (( _termpeek_idx++ ))
    else
      _termpeek_idx=1
    fi
    _termpeek_render
    [[ -o zle ]] && zle -R
    return 0
  fi
  [[ -o zle ]] && zle .down-line-or-history
}

_termpeek_up() {
  if (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 1 )); then
    (( _termpeek_idx-- ))
    _termpeek_render
    [[ -o zle ]] && zle -R
    return 0
  elif (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx == 1 )); then
    _termpeek_idx=0
    _termpeek_render
    [[ -o zle ]] && zle -R
    return 0
  fi
  _termpeek_matches=()
  _termpeek_idx=0
  _termpeek_tag_map=()
  POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
  [[ -o zle ]] && zle .up-line-or-history
}

_termpeek_tab() {
  if (( ${#_termpeek_matches[@]} > 0 )); then
    if (( _termpeek_idx > 0 )); then
      BUFFER="${_termpeek_matches[$_termpeek_idx]}"
    else
      BUFFER="${_termpeek_matches[1]}"
    fi
    CURSOR=$#BUFFER
    _termpeek_matches=()
    _termpeek_idx=0
    _termpeek_tag_map=()
    _termpeek_last_buf="$BUFFER"
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    [[ -o zle ]] && zle -R
    return 0
  fi
  [[ -o zle ]] && zle expand-or-complete
}

_termpeek_right() {
  if (( CURSOR == $#BUFFER && ${#_termpeek_matches[@]} > 0 )); then
    BUFFER="${_termpeek_matches[1]}"
    CURSOR=$#BUFFER
    _termpeek_matches=()
    _termpeek_idx=0
    _termpeek_tag_map=()
    _termpeek_last_buf="$BUFFER"
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    [[ -o zle ]] && zle -R
    return 0
  fi
  [[ -o zle ]] && zle .forward-char
}

_termpeek_enter() {
  local target=""
  if (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 0 )); then
    target="${_termpeek_matches[$_termpeek_idx]}"
  fi

  if [[ -n "$target" ]]; then
    BUFFER="$target"
    CURSOR=$#BUFFER
    _termpeek_matches=()
    _termpeek_idx=0
    _termpeek_tag_map=()
    _termpeek_last_buf="$BUFFER"
    _termpeek_dismissed_buf=""

    # Destructive command safety guard
    if _termpeek_is_dangerous "$target"; then
      POSTDISPLAY=$'\n'"⚠️  [DANGER GUARD] Destructive command loaded to prompt for review. Press Enter to run."
      [[ -o zle ]] && zle -R
      return 0
    fi
  else
    _termpeek_matches=()
    _termpeek_idx=0
    _termpeek_tag_map=()
    _termpeek_last_buf=""
    _termpeek_dismissed_buf=""
    POSTDISPLAY=""
  fi

  [[ -o zle ]] && zle -R
  [[ -o zle ]] && zle .accept-line
}

_termpeek_escape() {
  if (( ${#_termpeek_matches[@]} > 0 )); then
    _termpeek_matches=()
    _termpeek_idx=0
    _termpeek_tag_map=()
    _termpeek_dismissed_buf="$BUFFER"
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    [[ -o zle ]] && zle -R
    return 0
  fi
  return 0
}

_termpeek_cancel() {
  _termpeek_matches=()
  _termpeek_idx=0
  _termpeek_tag_map=()
  _termpeek_last_buf=""
  _termpeek_dismissed_buf=""
  POSTDISPLAY=""
  [[ -o zle ]] && zle -R
  [[ -o zle ]] && zle .send-break
}

# Register named ZLE widgets
if [[ -o zle ]] || (( $+widgets )); then
  zle -N _termpeek_down_widget _termpeek_down
  zle -N _termpeek_up_widget _termpeek_up
  zle -N _termpeek_tab_widget _termpeek_tab
  zle -N _termpeek_enter_widget _termpeek_enter
  zle -N _termpeek_escape_widget _termpeek_escape
  zle -N _termpeek_right_widget _termpeek_right
  zle -N _termpeek_cancel_widget _termpeek_cancel

  # Keybindings
  bindkey '^[[B' _termpeek_down_widget
  bindkey '^[OB' _termpeek_down_widget
  bindkey '^[[A' _termpeek_up_widget
  bindkey '^[OA' _termpeek_up_widget
  bindkey '^I' _termpeek_tab_widget
  bindkey '^M' _termpeek_enter_widget
  bindkey '^J' _termpeek_enter_widget
  bindkey '\e' _termpeek_escape_widget
  bindkey '^[' _termpeek_escape_widget
  bindkey '^[[C' _termpeek_right_widget
  bindkey '^[OC' _termpeek_right_widget
  bindkey '^C' _termpeek_cancel_widget
  bindkey '^G' _termpeek_cancel_widget

  autoload -Uz add-zle-hook-widget
  add-zle-hook-widget line-pre-redraw _termpeek_pre_redraw
fi
