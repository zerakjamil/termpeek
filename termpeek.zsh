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

typeset -ga _termpeek_matches
typeset -gi _termpeek_idx=0
typeset -gA _termpeek_recipe_map
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

_termpeek_get_git_root() {
  if [[ "$PWD" != "$_termpeek_cached_pwd" ]]; then
    _termpeek_cached_pwd="$PWD"
    _termpeek_git_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  fi
  print -r -- "$_termpeek_git_root"
}

_termpeek_render() {
  if (( ${#_termpeek_matches[@]} == 0 )); then
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    return
  fi
  local ghost="${POSTDISPLAY%%$'\n'*}"
  local out=""
  local i
  local max_w=$(( COLUMNS > 25 ? COLUMNS - 15 : 65 ))
  local pointer="${TERMPEEK_POINTER:-▶}"
  local show_hints=${TERMPEEK_SHOW_HINTS:-1}

  for (( i=1; i<=${#_termpeek_matches[@]}; i++ )); do
    local item="${_termpeek_matches[$i]}"
    local tag=""
    if [[ -n "${_termpeek_recipe_map[$item]}" ]]; then
      tag="  [recipe]"
    fi
    local display_item="$item"
    (( $#display_item > max_w )) && display_item="${display_item[1,$max_w]}..."

    if (( i == _termpeek_idx )); then
      local hint=""
      (( show_hints == 1 )) && hint="  (Tab: selected | →: first | Enter: run | Esc: close)"
      out+=$'\n'"$pointer [$i] $display_item$tag$hint"
    else
      local hint=""
      if (( i == 1 && _termpeek_idx == 0 && show_hints == 1 )); then
        hint="  (→: first | Tab: complete)"
      fi
      out+=$'\n'"  [$i] $display_item$tag$hint"
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
    _termpeek_recipe_map=()
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    return
  fi

  _termpeek_matches=()
  _termpeek_recipe_map=()

  local max_res=${TERMPEEK_MAX_RESULTS:-4}
  local only_succ=${TERMPEEK_ONLY_SUCCESSFUL:-1}
  local use_recipes=${TERMPEEK_RECIPES:-1}
  local recipe="" lower_trim="" lower_recipe="" existing="" line=""
  local already=0

  # Strategy 1: Use Atuin SQLite database if available
  if [[ -f "$_termpeek_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local escaped="${trimmed//\"/\"\"}"
    local pwd_escaped="${PWD//\"/\"\"}"
    local git_root="$(_termpeek_get_git_root)"
    local git_escaped="${git_root//\"/\"\"}"

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
        _termpeek_matches+=("$line")
      fi
    done < <(sqlite3 "$_termpeek_db" "$sql" 2>/dev/null)
  else
    # Strategy 2: Fallback to native zsh history
    local -A seen
    while IFS= read -r line; do
      line="${line## #}"
      line="${line%% #}"
      if [[ -n "$line" && "$line" != "$trimmed" && -z "${seen[$line]}" ]]; then
        seen[$line]=1
        _termpeek_matches+=("$line")
        (( ${#_termpeek_matches[@]} >= max_res )) && break
      fi
    done < <(fc -l -n -r 1 2000 2>/dev/null | grep -F -i "$trimmed" 2>/dev/null)
  fi

  # Recipe fallback if fewer matches than max_res
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
          _termpeek_recipe_map[$recipe]=1
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
  _termpeek_recipe_map=()
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
    _termpeek_recipe_map=()
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
    _termpeek_recipe_map=()
    _termpeek_last_buf="$BUFFER"
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    [[ -o zle ]] && zle -R
    return 0
  fi
  [[ -o zle ]] && zle .forward-char
}

_termpeek_enter() {
  if (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 0 )); then
    BUFFER="${_termpeek_matches[$_termpeek_idx]}"
    CURSOR=$#BUFFER
  fi
  _termpeek_matches=()
  _termpeek_idx=0
  _termpeek_recipe_map=()
  _termpeek_last_buf=""
  _termpeek_dismissed_buf=""
  POSTDISPLAY=""
  [[ -o zle ]] && zle -R
  [[ -o zle ]] && zle .accept-line
}

_termpeek_escape() {
  if (( ${#_termpeek_matches[@]} > 0 )); then
    _termpeek_matches=()
    _termpeek_idx=0
    _termpeek_recipe_map=()
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
  _termpeek_recipe_map=()
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
