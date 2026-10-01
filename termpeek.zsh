# termpeek.zsh
# Fast live history keyword suggestions for Zsh
# Repository: https://github.com/zerakjamil/termpeek
# License: MIT

export KEYTIMEOUT=${KEYTIMEOUT:-10}

typeset -ga _termpeek_matches
typeset -gi _termpeek_idx=0
typeset -g _termpeek_last_buf=""
typeset -g _termpeek_dismissed_buf=""
typeset -g _termpeek_db="$HOME/.local/share/atuin/history.db"

_termpeek_render() {
  if (( ${#_termpeek_matches[@]} == 0 )); then
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    return
  fi
  local ghost="${POSTDISPLAY%%$'\n'*}"
  local out=""
  local i
  local max_w=$(( COLUMNS > 25 ? COLUMNS - 15 : 65 ))
  for (( i=1; i<=${#_termpeek_matches[@]}; i++ )); do
    local item="${_termpeek_matches[$i]}"
    (( $#item > max_w )) && item="${item[1,$max_w]}..."
    if (( i == _live_idx )); then
      out+=$'\n'"▶ [$i] $item  (Tab: complete | Enter: run | Esc: close)"
    else
      out+=$'\n'"  [$i] $item"
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
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    return
  fi

  _termpeek_matches=()

  # Strategy 1: Use Atuin SQLite database if available
  if [[ -f "$_termpeek_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local escaped="${trimmed//\"/\"\"}"
    local line
    while IFS= read -r line; do
      line="${line%% && }"
      line="${line## #}"
      line="${line%% #}"
      if [[ -n "$line" && "$line" != "$trimmed" ]]; then
        _termpeek_matches+=("$line")
      fi
    done < <(sqlite3 "$_termpeek_db" "
      SELECT replace(replace(command, char(13), ''), char(10), ' && ')
      FROM history
      WHERE command LIKE \"%$escaped%\" AND deleted_at IS NULL
      GROUP BY command
      ORDER BY max(timestamp) DESC
      LIMIT 4;
    " 2>/dev/null)
  else
    # Strategy 2: Fallback to native zsh history
    local line
    local -A seen
    while IFS= read -r line; do
      line="${line## #}"
      line="${line%% #}"
      if [[ -n "$line" && "$line" != "$trimmed" && -z "${seen[$line]}" ]]; then
        seen[$line]=1
        _termpeek_matches+=("$line")
        (( ${#_termpeek_matches[@]} >= 4 )) && break
      fi
    done < <(fc -l -n -r 1 2000 2>/dev/null | grep -F -i "$trimmed" 2>/dev/null)
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
    _termpeek_last_buf="$BUFFER"
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    [[ -o zle ]] && zle -R
    return 0
  fi
  [[ -o zle ]] && zle expand-or-complete
}

_termpeek_enter() {
  if (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 0 )); then
    BUFFER="${_termpeek_matches[$_termpeek_idx]}"
    CURSOR=$#BUFFER
  fi
  _termpeek_matches=()
  _termpeek_idx=0
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
    _termpeek_dismissed_buf="$BUFFER"
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    [[ -o zle ]] && zle -R
    return 0
  fi
  return 0
}

_termpeek_right() {
  if (( CURSOR == $#BUFFER && ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 0 )); then
    BUFFER="${_termpeek_matches[$_termpeek_idx]}"
    CURSOR=$#BUFFER
    _termpeek_matches=()
    _termpeek_idx=0
    _termpeek_last_buf="$BUFFER"
    POSTDISPLAY="${POSTDISPLAY%%$'\n'*}"
    [[ -o zle ]] && zle -R
    return 0
  fi
  [[ -o zle ]] && zle .forward-char
}

_termpeek_cancel() {
  _termpeek_matches=()
  _termpeek_idx=0
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

  # Bindings
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
