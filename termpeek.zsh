# termpeek.zsh
# Fast live history keyword suggestions for Zsh
# Zero-fork, asynchronous architecture with native terminal rendering
# Repository: https://github.com/zerakjamil/termpeek
# License: MIT

export KEYTIMEOUT=${KEYTIMEOUT:-10}

typeset -g _TERMPEEK_ROOT="${${(%):-%x}:A:h}"

# User-configurable settings
TERMPEEK_MAX_RESULTS=${TERMPEEK_MAX_RESULTS:-4}
TERMPEEK_POINTER=${TERMPEEK_POINTER:-▶}
TERMPEEK_SHOW_HINTS=${TERMPEEK_SHOW_HINTS:-1}
TERMPEEK_ONLY_SUCCESSFUL=${TERMPEEK_ONLY_SUCCESSFUL:-1}
TERMPEEK_RECIPES=${TERMPEEK_RECIPES:-1}
TERMPEEK_PROJECT_TASKS=${TERMPEEK_PROJECT_TASKS:-1}
TERMPEEK_SAFETY_GUARD=${TERMPEEK_SAFETY_GUARD:-1}
TERMPEEK_MASK_SECRETS=${TERMPEEK_MASK_SECRETS:-1}

# Global state
typeset -ga _termpeek_matches
typeset -ga _termpeek_tags
typeset -ga _termpeek_dangers
typeset -ga _termpeek_displays
typeset -gi _termpeek_preflight_code=0
typeset -g _termpeek_preflight_msg=""
typeset -gi _termpeek_preflight_pid=0
typeset -gi _termpeek_hud_active=0
typeset -gi _termpeek_idx=0
typeset -gi _termpeek_lines_drawn=0
typeset -gi _termpeek_qid=0
typeset -gi _termpeek_target_col=1
typeset -gi _termpeek_extra_rows=0
typeset -gi _termpeek_prompt_len=0
typeset -gi _termpeek_last_cursor=0
typeset -g _termpeek_last_prompt=""
typeset -g _termpeek_prev_cmd=""

typeset -g _termpeek_last_buf=""
typeset -g _termpeek_dismissed_buf=""
typeset -g _termpeek_fifo_in=""
typeset -g _termpeek_fifo_out=""
typeset -gi _termpeek_in_fd=0
typeset -gi _termpeek_out_fd=0
typeset -gi _termpeek_worker_pid=0

# Coexistence with zsh-autosuggestions: protect widgets from being wrapped
typeset -ga ZSH_AUTOSUGGEST_IGNORE_WIDGETS
ZSH_AUTOSUGGEST_IGNORE_WIDGETS+=('_termpeek_*' 'termpeek-*')

typeset -g _termpeek_last_highlight=""

# Clear inline autosuggestion extension (POSTDISPLAY) and pending async requests
_termpeek_clear_autosuggest() {
  POSTDISPLAY=""
  if [[ -n "$_termpeek_last_highlight" ]] && (( $+region_highlight )); then
    region_highlight=("${(@)region_highlight:#$_termpeek_last_highlight}")
    _termpeek_last_highlight=""
  fi
  if (( $+_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT )) && [[ -n "$_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT" ]]; then
    region_highlight=("${(@)region_highlight:#$_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT}")
    unset _ZSH_AUTOSUGGEST_LAST_HIGHLIGHT
  fi
  if [[ -n "$WIDGET" ]] && (( $+widgets[autosuggest-clear] )); then
    zle autosuggest-clear 2>/dev/null
  fi
  if [[ -n "$_ZSH_AUTOSUGGEST_ASYNC_FD" ]] && { true <&$_ZSH_AUTOSUGGEST_ASYNC_FD } 2>/dev/null; then
    builtin exec {_ZSH_AUTOSUGGEST_ASYNC_FD}<&- 2>/dev/null
    if [[ -n "$WIDGET" ]]; then
      zle -F $_ZSH_AUTOSUGGEST_ASYNC_FD 2>/dev/null
    fi
    _ZSH_AUTOSUGGEST_ASYNC_FD=
  fi
}

_termpeek_refresh_prompt_len() {
  setopt localoptions extendedglob
  local p_raw="${PROMPT:-${PS1:-}}"
  p_raw="${p_raw//\%\{[^%]#\%\}/}"
  local expanded="${(%%):-$p_raw}"
  _termpeek_last_prompt="$expanded"
  local last_line="${expanded##*$'\n'}"
  last_line="${last_line//$'\e'\[[0-9;\?:]#[a-zA-Z@]/}"
  last_line="${last_line//$'\e'\][^\a\e]#($'\a'|$'\e'\\)/}"
  last_line="${last_line//$'\e'[78=>MDEHcnop]/}"
  last_line="${last_line//$'\r'/}"
  _termpeek_prompt_len=${#last_line}
}

_termpeek_clear_display() {
  _termpeek_clear_autosuggest
}

# Asynchronous worker response handler (triggered by zle -F)
_termpeek_async_callback() {
  emulate -L zsh
  setopt localoptions extendedglob
  local fd=$1
  local err=$2

  if [[ -n "$err" || ! -o zle ]]; then
    return 0
  fi

  if (( $+modules[zsh/zselect] )) || zmodload zsh/zselect 2>/dev/null; then
    zselect -r $fd -t 0 2>/dev/null || return 0
  fi

  local line=""
  while (( 1 )); do
    if ! read -r -u $fd line; then
      # Worker crashed or closed FIFO: detach callback immediately to prevent 100% CPU spin
      [[ -o zle ]] && zle -F $fd 2>/dev/null
      exec {fd}<&- 2>/dev/null
      _termpeek_out_fd=0
      return 0
    fi
    [[ -z "$line" ]] && return 0

    local resp_qid="${line%%$'\t'*}"
    [[ "$resp_qid" == <-> ]] || break

    # If this response matches our current active query, process it
    if (( resp_qid == _termpeek_qid )); then
      local -a parts=("${(@ps:\t:)line}")
      local buf="${BUFFER:-$_termpeek_last_buf}"
      local trimmed="${buf## #}"
      trimmed="${trimmed%% #}"
      if [[ ${#trimmed} -lt 2 ]]; then
        _termpeek_clear_autosuggest
        return 0
      fi

      local count="${parts[2]}"
      [[ "$count" == <-> ]] || count=0
      _termpeek_matches=()
      _termpeek_tags=()
      _termpeek_dangers=()
      _termpeek_displays=()

      if (( count > 0 )); then
        local -i pidx=3
        repeat $count; do
          _termpeek_matches+=("${parts[pidx++]}")
          _termpeek_tags+=("${parts[pidx++]}")
          _termpeek_dangers+=("${parts[pidx++]}")
          _termpeek_displays+=("${parts[pidx++]}")
        done
        _termpeek_preflight_code="${parts[pidx++]:-0}"
        _termpeek_preflight_msg="${parts[pidx++]:-}"
        _termpeek_preflight_pid="${parts[pidx++]:-0}"
      else
        _termpeek_preflight_code="${parts[3]:-0}"
        _termpeek_preflight_msg="${parts[4]:-}"
        _termpeek_preflight_pid="${parts[5]:-0}"
      fi

      _termpeek_idx=0

      # Clean prior highlight entry to prevent array bloat
      if [[ -n "$_termpeek_last_highlight" ]] && (( $+region_highlight )); then
        region_highlight=("${(@)region_highlight:#$_termpeek_last_highlight}")
        _termpeek_last_highlight=""
      fi

      # Layer 1: Native ZLE inline ghost completion (zero cursor escapes on typing path)
      if [[ ${#trimmed} -ge 2 && ${#_termpeek_matches[@]} -gt 0 ]]; then
        local top_match="${_termpeek_matches[1]}"
        if [[ "$top_match" == "$buf"* && "$top_match" != "$buf" ]]; then
          POSTDISPLAY="${top_match#$buf}"
          if (( $+region_highlight )); then
            _termpeek_last_highlight="$#buf $(($#buf + $#POSTDISPLAY)) fg=8,underline"
            region_highlight+=("$_termpeek_last_highlight")
          fi
        else
          POSTDISPLAY=""
        fi
      else
        POSTDISPLAY=""
      fi
      [[ -o zle ]] && zle -R
      return 0
    fi

    # Stale query response: if more data is immediately ready in FIFO, consume next
    if (( $+modules[zsh/zselect] )) || zmodload zsh/zselect 2>/dev/null; then
      zselect -r $fd -t 0 2>/dev/null || break
    else
      break
    fi
  done
}

# Keystroke hook: 0 forks, 0 subshells, non-blocking query write
_termpeek_pre_redraw() {
  local current="$BUFFER"
  _termpeek_last_cursor=${CURSOR:-${#current}}

  # No-op if buffer hasn't changed
  if [[ "$current" == "$_termpeek_last_buf" ]]; then
    return 0
  fi

  # Invalidate previous query immediately so in-flight responses are dropped
  (( _termpeek_qid++ ))
  _termpeek_last_buf="$current"

  local trimmed="${current## #}"
  trimmed="${trimmed%% #}"

  # Clear ghost text if buffer is empty, single character, or dismissed
  if [[ ${#trimmed} -lt 2 || "$current" == "$_termpeek_dismissed_buf" ]]; then
    POSTDISPLAY=""
    _termpeek_matches=()
    _termpeek_tags=()
    _termpeek_dangers=()
    _termpeek_displays=()
    _termpeek_idx=0
    _termpeek_preflight_code=0
    _termpeek_preflight_msg=""
    _termpeek_preflight_pid=0
    return 0
  fi

  # Dispatch query to background worker via non-blocking FIFO write (0 forks)
  if (( _termpeek_in_fd > 0 )); then
    print -u $_termpeek_in_fd -r -- "$_termpeek_qid"$'\t'"$PWD"$'\t'"$current"$'\t'"$_termpeek_prev_cmd" 2>/dev/null
  fi
}

_termpeek_render_hud() {
  local cur_sel=$1
  local total=${#_termpeek_matches[@]}
  local buf="${BUFFER:-$_termpeek_last_buf}"

  local col_limit=${COLUMNS:-80}
  (( col_limit < 40 )) && col_limit=40
  local box_w=$(( col_limit > 72 ? 68 : col_limit - 4 ))
  local border_dash=""
  local fill_len=$(( box_w - 40 ))
  (( fill_len < 4 )) && fill_len=4
  repeat $fill_len; border_dash+="─"

  local out=$'\e[H\e[2J'
  out+=$'\e[1;36m╭─ termpeek 2.0 pre-flight inspector '"$border_dash"$'\e[0m\r\n'
  out+=$'\e[1;36m│\e[0m \e[2mPrompt:\e[0m \e[1m'"$buf"$'\e[0m\r\n'
  out+=$'\e[1;36m├──────────────────────────────────────────────────────────────────┤\e[0m\r\n'

  local i
  for (( i=1; i<=total; i++ )); do
    local cmd="${_termpeek_displays[i]}"
    local tag="${_termpeek_tags[i]}"
    local styled_tag=""
    if [[ -n "$tag" ]]; then
      if [[ "$tag" == *"[DANGER]"* ]]; then
        styled_tag=$' \e[1;31m[DANGER]\e[0m'
      elif [[ "$tag" == *"[SECRET]"* ]]; then
        styled_tag=$' \e[33m[SECRET]\e[0m'
      elif [[ "$tag" == *"[project]"* ]]; then
        styled_tag=$' \e[36m[project]\e[0m'
      elif [[ "$tag" == *"[recipe]"* ]]; then
        styled_tag=$' \e[35m[recipe]\e[0m'
      else
        styled_tag="  $tag"
      fi
    fi

    if (( i == cur_sel )); then
      out+=$'\e[1;36m│\e[0m \e[1;34m▶\e[0m \e[1;37m'"$i  $cmd"$'\e[0m'"$styled_tag"$'\r\n'
    else
      out+=$'\e[1;36m│\e[0m   \e[2m'"$i  $cmd"$'\e[0m'"$styled_tag"$'\r\n'
    fi
  done

  out+=$'\e[1;36m├──────────────────────────────────────────────────────────────────┤\e[0m\r\n'
  if (( _termpeek_preflight_code == 2 )); then
    out+=$'\e[1;36m│\e[0m \e[1;33m⚠️  '"$_termpeek_preflight_msg"$'\e[0m\r\n'
  elif (( _termpeek_preflight_code == 3 )); then
    out+=$'\e[1;36m│\e[0m \e[1;31m⚠️  '"$_termpeek_preflight_msg"$'\e[0m\r\n'
  elif (( _termpeek_preflight_code == 1 )); then
    out+=$'\e[1;36m│\e[0m \e[36mℹ️  '"$_termpeek_preflight_msg"$'\e[0m\r\n'
  else
    out+=$'\e[1;36m│\e[0m \e[32m✓  Pre-flight checks passed (0 port collisions, clean git worktree)\e[0m\r\n'
  fi
  out+=$'\e[1;36m╰─ \e[2m[↑/↓] Navigate  [Enter/Tab/→] Select  [Alt+K] Kill Port  [Esc] Back\e[0m\e[1;36m ──╯\e[0m\r\n'

  print -n -u 2 -- "$out"
}

_termpeek_kill_port_owner() {
  if (( _termpeek_preflight_pid > 100 && _termpeek_preflight_pid != $$ && _termpeek_preflight_pid != PPID )); then
    if kill -0 "$_termpeek_preflight_pid" 2>/dev/null; then
      kill -15 "$_termpeek_preflight_pid" 2>/dev/null || kill -9 "$_termpeek_preflight_pid" 2>/dev/null
      _termpeek_preflight_msg="[Killed PID $_termpeek_preflight_pid - Port freed!]"
      _termpeek_preflight_code=0
      _termpeek_preflight_pid=0
    fi
  fi
}

_termpeek_preflight_widget() {
  if (( _termpeek_out_fd > 0 )); then
    if (( $+modules[zsh/zselect] )) || zmodload zsh/zselect 2>/dev/null; then
      if zselect -r $_termpeek_out_fd -t 0 2>/dev/null; then
        _termpeek_async_callback $_termpeek_out_fd ""
      fi
    fi
  fi

  local total=${#_termpeek_matches[@]}
  local hud_idx=1
  (( total == 0 )) && hud_idx=0
  _termpeek_hud_active=1

  # Save terminal settings and enter alternate screen buffer
  local old_stty=""
  if [[ -t 0 ]]; then
    old_stty=$(stty -g 2>/dev/null)
    stty raw -echo 2>/dev/null
  fi
  print -n -u 2 -- $'\e[?1049h\e[?25l'

  {
    while true; do
      _termpeek_render_hud "$hud_idx"

      local key=""
      if ! read -k 1 -r key; then
        break
      fi

      if [[ "$key" == $'\e' ]]; then
        local seq=""
        while read -t 0.05 -k 1 -r rest; do
          seq+="$rest"
        done
        if [[ -z "$seq" ]]; then
          break
        elif [[ "$seq" == "[A" || "$seq" == "OA" ]]; then
          if (( hud_idx > 1 )); then
            (( hud_idx-- ))
          elif (( total > 0 )); then
            hud_idx=$total
          fi
        elif [[ "$seq" == "[B" || "$seq" == "OB" ]]; then
          if (( hud_idx < total )); then
            (( hud_idx++ ))
          elif (( total > 0 )); then
            hud_idx=1
          fi
        elif [[ "$seq" == "[C" || "$seq" == "OC" ]]; then
          # Right Arrow confirms selection
          if (( hud_idx > 0 && hud_idx <= total )); then
            BUFFER="${_termpeek_matches[hud_idx]}"
            CURSOR=$#BUFFER
            _termpeek_last_buf="$BUFFER"
            _termpeek_dismissed_buf="$BUFFER"
            _termpeek_clear_autosuggest
          fi
          break
        elif [[ "$seq" == "k" || "$seq" == "K" ]]; then
          _termpeek_kill_port_owner
        fi
      elif [[ "$key" == $'\n' || "$key" == $'\r' ]]; then
        if (( hud_idx > 0 && hud_idx <= total )); then
          BUFFER="${_termpeek_matches[hud_idx]}"
          CURSOR=$#BUFFER
          _termpeek_last_buf="$BUFFER"
          _termpeek_dismissed_buf="$BUFFER"
          _termpeek_clear_autosuggest
        fi
        break
      elif [[ "$key" == $'\t' ]]; then
        if (( hud_idx > 0 && hud_idx <= total )); then
          BUFFER="${_termpeek_matches[hud_idx]}"
          CURSOR=$#BUFFER
          _termpeek_last_buf="$BUFFER"
          _termpeek_dismissed_buf="$BUFFER"
          _termpeek_clear_autosuggest
        fi
        break
      elif [[ "$key" == $'\x03' || "$key" == $'\x04' || "$key" == $'\x1a' || "$key" == "q" || "$key" == "Q" ]]; then
        # Ctrl+C, Ctrl+D, Ctrl+Z, or q cleanly exits HUD
        break
      fi
    done
  } always {
    print -n -u 2 -- $'\e[?1049l\e[?25h'
    if [[ -n "$old_stty" ]]; then
      stty "$old_stty" 2>/dev/null || stty sane 2>/dev/null
    else
      stty sane 2>/dev/null
    fi
    _termpeek_hud_active=0
    [[ -o zle ]] && zle reset-prompt 2>/dev/null
  }
}

# Arrow Down: navigate down suggestion list or open Layer 2 HUD
_termpeek_down() {
  if [[ -o zle ]] && (( ${#_termpeek_matches[@]} > 0 )); then
    _termpeek_preflight_widget
    return 0
  fi
  if (( ${#_termpeek_matches[@]} > 0 )); then
    if (( _termpeek_idx < ${#_termpeek_matches[@]} )); then
      (( _termpeek_idx++ ))
    else
      _termpeek_idx=1
    fi
    _termpeek_clear_autosuggest
    [[ -o zle ]] && zle -R
    return 0
  fi
  [[ -o zle ]] && zle .down-line-or-history
}

# Arrow Up: navigate up suggestion list
_termpeek_up() {
  if (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 1 )); then
    (( _termpeek_idx-- ))
    _termpeek_clear_autosuggest
    [[ -o zle ]] && zle -R
    return 0
  elif (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx == 1 )); then
    _termpeek_idx=0
    if (( $+widgets[autosuggest-fetch] )); then
      [[ -o zle ]] && zle autosuggest-fetch
    fi
    [[ -o zle ]] && zle -R
    return 0
  fi
  [[ -o zle ]] && zle .up-line-or-history
}

# Tab completion: fills selected item or accepts inline ghost completion if present, else standard completion
_termpeek_tab() {
  if (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 0 )); then
    local selected="${_termpeek_matches[$_termpeek_idx]}"
    _termpeek_matches=()
    _termpeek_tags=()
    _termpeek_dangers=()
    _termpeek_displays=()
    _termpeek_idx=0
    _termpeek_clear_autosuggest
    BUFFER="$selected"
    CURSOR=$#BUFFER
    _termpeek_last_buf="$BUFFER"
    _termpeek_dismissed_buf="$BUFFER"
    POSTDISPLAY=""
    [[ -o zle ]] && zle -R
    return 0
  fi
  if [[ -n "$POSTDISPLAY" ]]; then
    BUFFER+="$POSTDISPLAY"
    POSTDISPLAY=""
    _termpeek_clear_autosuggest
    CURSOR=$#BUFFER
    _termpeek_last_buf="$BUFFER"
    [[ -o zle ]] && zle -R
    return 0
  fi
  [[ -o zle ]] && zle expand-or-complete
}

# Right Arrow / Ctrl+F: fills selected item or accepts inline ghost completion at end of line
_termpeek_right() {
  if (( CURSOR == $#BUFFER && ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 0 )); then
    local selected="${_termpeek_matches[$_termpeek_idx]}"
    _termpeek_matches=()
    _termpeek_tags=()
    _termpeek_dangers=()
    _termpeek_displays=()
    _termpeek_idx=0
    _termpeek_clear_autosuggest
    BUFFER="$selected"
    CURSOR=$#BUFFER
    _termpeek_last_buf="$BUFFER"
    _termpeek_dismissed_buf="$BUFFER"
    POSTDISPLAY=""
    [[ -o zle ]] && zle -R
    return 0
  fi

  if [[ -n "$POSTDISPLAY" ]]; then
    if [[ ! -o zle ]] || (( CURSOR == $#BUFFER )); then
      BUFFER+="$POSTDISPLAY"
      POSTDISPLAY=""
      _termpeek_clear_autosuggest
      CURSOR=$#BUFFER
      _termpeek_last_buf="$BUFFER"
      [[ -o zle ]] && zle -R
      return 0
    fi
  fi

  # Pass through to inline autosuggestion accept if available, else standard forward-char
  if (( $+widgets[autosuggest-accept] )); then
    [[ -o zle ]] && zle autosuggest-accept
    return 0
  fi
  [[ -o zle ]] && zle .forward-char
}

# Enter: execute or review destructive command
_termpeek_enter() {
  _termpeek_clear_autosuggest
  (( _termpeek_qid++ ))
  if (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 0 )); then
    local target="${_termpeek_matches[$_termpeek_idx]}"
    local is_danger="${_termpeek_dangers[$_termpeek_idx]}"
    _termpeek_matches=()
    _termpeek_tags=()
    _termpeek_dangers=()
    _termpeek_displays=()
    _termpeek_idx=0
    BUFFER="$target"
    CURSOR=$#BUFFER
    _termpeek_last_buf="$BUFFER"
    _termpeek_dismissed_buf="$BUFFER"
    POSTDISPLAY=""

    if (( is_danger == 1 )); then
      _termpeek_lines_drawn=1
      POSTDISPLAY=" ⚠️  [DANGER GUARD: review before execution]"
      [[ -o zle ]] && zle -R
      return 0
    fi
  else
    _termpeek_matches=()
    _termpeek_tags=()
    _termpeek_dangers=()
    _termpeek_displays=()
    _termpeek_idx=0
    _termpeek_last_buf=""
    _termpeek_dismissed_buf=""
    POSTDISPLAY=""
  fi

  [[ -o zle ]] && zle -R
  [[ -o zle ]] && zle .accept-line
}

# Escape: dismiss preview immediately
_termpeek_escape() {
  _termpeek_clear_autosuggest
  (( _termpeek_qid++ ))
  _termpeek_matches=()
  _termpeek_tags=()
  _termpeek_dangers=()
  _termpeek_displays=()
  _termpeek_idx=0
  _termpeek_dismissed_buf="$BUFFER"
  [[ -o zle ]] && zle -R
  return 0
}

# Cancel: Ctrl+C / Ctrl+G
_termpeek_cancel() {
  _termpeek_clear_autosuggest
  (( _termpeek_qid++ ))
  _termpeek_matches=()
  _termpeek_tags=()
  _termpeek_dangers=()
  _termpeek_displays=()
  _termpeek_idx=0
  _termpeek_last_buf=""
  _termpeek_dismissed_buf=""
  [[ -o zle ]] && zle -R
  [[ -o zle ]] && zle .send-break
}

# Lifecycle hooks
_termpeek_preexec() {
  _termpeek_clear_display
  (( _termpeek_qid++ ))
  _termpeek_matches=()
  _termpeek_tags=()
  _termpeek_dangers=()
  _termpeek_displays=()
  _termpeek_idx=0
  _termpeek_lines_drawn=0
  local cmd="$1"
  local clean_cmd="${cmd//$'\r'/}"
  clean_cmd="${clean_cmd//$'\n'/ && }"
  clean_cmd="${clean_cmd## #}"
  clean_cmd="${clean_cmd%% #}"
  if [[ -n "$clean_cmd" ]]; then
    if (( _termpeek_in_fd > 0 )); then
      print -u $_termpeek_in_fd -r -- "RECORD"$'\t'"$PWD"$'\t'"$_termpeek_prev_cmd"$'\t'"$clean_cmd" 2>/dev/null
    fi
    _termpeek_prev_cmd="$clean_cmd"
  fi
}

_termpeek_precmd() {
  _termpeek_clear_display
  (( _termpeek_qid++ ))
  _termpeek_matches=()
  _termpeek_tags=()
  _termpeek_dangers=()
  _termpeek_displays=()
  _termpeek_idx=0
  _termpeek_last_buf=""
  _termpeek_last_cursor=0
  _termpeek_last_prompt=""
  _termpeek_dismissed_buf=""
  _termpeek_lines_drawn=0
  _termpeek_refresh_prompt_len
}

_termpeek_clear_screen() {
  _termpeek_clear_autosuggest
  zle .clear-screen
}

# Cleanup on shell exit
_termpeek_cleanup() {
  print -n -u 2 -- $'\e[?1049l\e[?25h' 2>/dev/null
  _termpeek_clear_autosuggest
  if (( _termpeek_in_fd > 0 )); then
    print -u $_termpeek_in_fd -r -- "QUIT" 2>/dev/null
    exec {_termpeek_in_fd}>&- 2>/dev/null
    _termpeek_in_fd=0
  fi
  if (( _termpeek_out_fd > 0 )); then
    [[ -o zle ]] && zle -F $_termpeek_out_fd 2>/dev/null
    exec {_termpeek_out_fd}<&- 2>/dev/null
    _termpeek_out_fd=0
  fi
  rm -f "$_termpeek_fifo_in" "$_termpeek_fifo_out" 2>/dev/null
}

# Non-destructive signal traps ensuring emergency alternate-screen buffer exit
if ! (( $+functions[TRAPINT] )); then
  TRAPINT() {
    print -n -u 2 -- $'\e[?1049l\e[?25h' 2>/dev/null
    return $(( 128 + 2 ))
  }
fi

if ! (( $+functions[TRAPQUIT] )); then
  TRAPQUIT() {
    print -n -u 2 -- $'\e[?1049l\e[?25h' 2>/dev/null
    return $(( 128 + 3 ))
  }
fi

if ! (( $+functions[TRAPEXIT] )); then
  TRAPEXIT() {
    print -n -u 2 -- $'\e[?1049l\e[?25h' 2>/dev/null
  }
fi

# Initialize worker and FIFOs
_termpeek_init() {
  local worker_bin="$_TERMPEEK_ROOT/bin/termpeek-worker"

  if [[ ! -x "$worker_bin" ]]; then
    chmod +x "$worker_bin" 2>/dev/null || true
  fi

  # Resolve writable runtime directory across Linux, macOS, Termux (Android), and Windows (WSL/MSYS2)
  local base_tmp="${TMPDIR:-${XDG_RUNTIME_DIR:-${PREFIX:+$PREFIX/tmp}}}"
  if [[ -z "$base_tmp" || ! -d "$base_tmp" || ! -w "$base_tmp" ]]; then
    if [[ -d "/tmp" && -w "/tmp" ]]; then
      base_tmp="/tmp"
    else
      base_tmp="$HOME/.termpeek/tmp"
    fi
  fi
  local rundir="$base_tmp/termpeek-${UID:-$USER}"
  mkdir -m 0700 -p "$rundir" 2>/dev/null || {
    rundir="$HOME/.termpeek/tmp"
    mkdir -m 0700 -p "$rundir" 2>/dev/null
  }

  _termpeek_fifo_in="$rundir/termpeek-$$.in"
  _termpeek_fifo_out="$rundir/termpeek-$$.out"

  rm -f "$_termpeek_fifo_in" "$_termpeek_fifo_out" 2>/dev/null
  mkfifo -m 0600 "$_termpeek_fifo_in" "$_termpeek_fifo_out" 2>/dev/null || {
    # If FIFO creation in temp dir failed (e.g. non-POSIX mount), fallback to home directory
    rundir="$HOME/.termpeek/tmp"
    mkdir -m 0700 -p "$rundir" 2>/dev/null
    _termpeek_fifo_in="$rundir/termpeek-$$.in"
    _termpeek_fifo_out="$rundir/termpeek-$$.out"
    rm -f "$_termpeek_fifo_in" "$_termpeek_fifo_out" 2>/dev/null
    mkfifo -m 0600 "$_termpeek_fifo_in" "$_termpeek_fifo_out" 2>/dev/null || return 1
  }

  # Open both file descriptors in Zsh first with <> (O_RDWR) to prevent any FIFO deadlock
  exec {_termpeek_in_fd}<>"$_termpeek_fifo_in" || return 1
  exec {_termpeek_out_fd}<>"$_termpeek_fifo_out" || return 1

  # Locate python interpreter across all platforms (Termux, Linux, macOS, Windows)
  local py_cmd=""
  if (( $+commands[python3] )); then
    py_cmd="python3"
  elif (( $+commands[python] )); then
    py_cmd="python"
  elif (( $+commands[python3.12] )); then
    py_cmd="python3.12"
  elif (( $+commands[python3.11] )); then
    py_cmd="python3.11"
  fi

  # Spawn worker daemon in background passing FIFO paths
  if [[ -n "$py_cmd" ]]; then
    "$py_cmd" "$worker_bin" "$_termpeek_fifo_in" "$_termpeek_fifo_out" 2>/dev/null &!
  else
    "$worker_bin" "$_termpeek_fifo_in" "$_termpeek_fifo_out" 2>/dev/null &!
  fi
  _termpeek_worker_pid=$!

  # Register async callback with ZLE
  if [[ -o zle ]] || (( $+widgets )); then
    zle -F $_termpeek_out_fd _termpeek_async_callback
  fi
}

# Register widgets and bindings
if [[ -o interactive ]] || [[ -t 0 ]] || (( $+widgets )); then
  zmodload zsh/zle 2>/dev/null
  zle -N _termpeek_down_widget _termpeek_down
  zle -N _termpeek_up_widget _termpeek_up
  zle -N _termpeek_tab_widget _termpeek_tab
  zle -N _termpeek_enter_widget _termpeek_enter
  zle -N _termpeek_escape_widget _termpeek_escape
  zle -N _termpeek_right_widget _termpeek_right
  zle -N _termpeek_cancel_widget _termpeek_cancel
  zle -N _termpeek_clear_screen_widget _termpeek_clear_screen
  zle -N _termpeek_preflight_widget _termpeek_preflight_widget

  bindkey '^[[B' _termpeek_down_widget
  bindkey '^[OB' _termpeek_down_widget
  bindkey '^[[A' _termpeek_up_widget
  bindkey '^[OA' _termpeek_up_widget
  bindkey '^I' _termpeek_tab_widget
  bindkey '^M' _termpeek_enter_widget
  bindkey '^J' _termpeek_enter_widget
  bindkey '\e' _termpeek_escape_widget
  bindkey '^[' _termpeek_escape_widget
  (( KEYTIMEOUT == 40 )) && KEYTIMEOUT=5
  bindkey '^[[C' _termpeek_right_widget
  bindkey '^[OC' _termpeek_right_widget
  bindkey '^F' _termpeek_right_widget
  bindkey '^@' _termpeek_preflight_widget
  bindkey '^[p' _termpeek_preflight_widget
  # Note: Never bind '^C' so native shell SIGINT is preserved for clean prompt abortion
  bindkey '^G' _termpeek_cancel_widget
  bindkey '^L' _termpeek_clear_screen_widget

  # Universal terminfo keybindings (Linux console, Termux, rxvt, putty, xterm)
  if zmodload zsh/terminfo 2>/dev/null; then
    [[ -n "$terminfo[kcud1]" ]] && bindkey "$terminfo[kcud1]" _termpeek_down_widget
    [[ -n "$terminfo[kcuu1]" ]] && bindkey "$terminfo[kcuu1]" _termpeek_up_widget
    [[ -n "$terminfo[kcuf1]" ]] && bindkey "$terminfo[kcuf1]" _termpeek_right_widget
  fi

  autoload -Uz add-zle-hook-widget
  add-zle-hook-widget line-pre-redraw _termpeek_pre_redraw

  autoload -Uz add-zsh-hook
  if [[ -o interactive ]]; then
    add-zsh-hook preexec _termpeek_preexec
    add-zsh-hook precmd _termpeek_precmd
  fi
  add-zsh-hook zshexit _termpeek_cleanup

  _termpeek_init
fi
