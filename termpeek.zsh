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

# Clear inline autosuggestion extension (POSTDISPLAY) and pending async requests
_termpeek_clear_autosuggest() {
  POSTDISPLAY=""
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

# Compute exact 1-indexed horizontal cursor column and wrapped buffer line offset
# in pure Zsh integer arithmetic (0 forks, 0 regexes on hot keystroke path).
_termpeek_compute_cursor() {
  local p_raw="${PROMPT:-${PS1:-}}"
  p_raw="${p_raw//\%\{[^%]#\%\}/}"
  local p_exp="${(%%):-$p_raw}"
  if [[ "$p_exp" != "$_termpeek_last_prompt" ]]; then
    _termpeek_refresh_prompt_len
  fi
  local col_limit=${COLUMNS:-80}
  (( col_limit < 1 )) && col_limit=80

  local buf="${BUFFER:-$_termpeek_last_buf}"
  local cur_idx=${CURSOR:-0}
  if (( cur_idx == 0 && ${#BUFFER} == 0 )); then
    cur_idx=$(( _termpeek_last_cursor > 0 ? _termpeek_last_cursor : ${#buf} ))
  fi

  local cur_pos=$(( _termpeek_prompt_len + cur_idx ))
  local end_pos=$(( _termpeek_prompt_len + ${#buf} + ${#POSTDISPLAY} ))

  local cur_row_off=$(( cur_pos / col_limit ))
  local end_row_off=$(( end_pos > 0 ? (end_pos - 1) / col_limit : 0 ))
  (( end_row_off < cur_row_off )) && end_row_off=$cur_row_off

  _termpeek_target_col=$(( (cur_pos % col_limit) + 1 ))
  _termpeek_extra_rows=$(( end_row_off - cur_row_off ))
}

# Clean display engine using ECMA-48 relative viewport addressing
_termpeek_clear_display() {
  if (( _termpeek_lines_drawn > 0 )); then
    _termpeek_compute_cursor
    local seq=$'\e7'
    if (( _termpeek_extra_rows > 0 )); then
      seq+=$'\e['${_termpeek_extra_rows}'B'
    fi
    local i
    for (( i=1; i<=_termpeek_lines_drawn; i++ )); do
      seq+=$'\r\n\e[2K'
    done
    local up_rows=$(( _termpeek_lines_drawn + _termpeek_extra_rows ))
    seq+=$'\e['${up_rows}$'A\e['${_termpeek_target_col}'G\e7\e8'
    print -n -u 2 -- "$seq"
    _termpeek_lines_drawn=0
  fi
}

_termpeek_render_display() {
  local total=${#_termpeek_matches[@]}
  local buf="${BUFFER:-$_termpeek_last_buf}"
  local trimmed="${buf## #}"
  trimmed="${trimmed%% #}"

  if [[ ${#trimmed} -lt 2 || "$buf" == "$_termpeek_dismissed_buf" || total == 0 ]]; then
    _termpeek_clear_display
    return 0
  fi

  # Respect terminal boundary limits
  local term_lines=${LINES:-24}
  local max_allowed=$(( term_lines > 4 ? term_lines - 2 : 2 ))
  (( total > max_allowed )) && total=$max_allowed

  local max_drawn=$total
  (( _termpeek_lines_drawn > max_drawn )) && max_drawn=$_termpeek_lines_drawn

  _termpeek_compute_cursor

  local pointer="${TERMPEEK_POINTER:-▶}"
  local col_limit=${COLUMNS:-80}
  local safe_w=$(( col_limit > 12 ? col_limit - 7 : 15 ))
  local seq=$'\e7'
  if (( _termpeek_extra_rows > 0 )); then
    seq+=$'\e['${_termpeek_extra_rows}'B'
  fi

  local i
  for (( i=1; i<=max_drawn; i++ )); do
    local line=""
    if (( i <= total )); then
      local display_cmd="${_termpeek_displays[$i]}"
      local tag="${_termpeek_tags[$i]}"

      # Prevent line wrapping on narrow terminals (Termux on phones, split panes)
      local tag_len=${#tag}
      local avail_cmd_w=$safe_w
      if (( tag_len > 0 )); then
        avail_cmd_w=$(( safe_w - tag_len - 2 ))
      fi
      (( avail_cmd_w < 10 )) && avail_cmd_w=10
      if (( $#display_cmd > avail_cmd_w )); then
        local cut_len=$(( avail_cmd_w > 3 ? avail_cmd_w - 3 : avail_cmd_w ))
        display_cmd="${display_cmd[1,$cut_len]}..."
      fi

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

      if (( i == _termpeek_idx )); then
        line=$'\e[1;34m'"$pointer"$'\e[0m \e[1m'"$i"$'\e[0m  \e[1m'"$display_cmd"$'\e[0m'"$styled_tag"
      else
        line="  "$'\e[2m'"$i"$'\e[0m  '"$display_cmd$styled_tag"
      fi
    fi
    seq+=$'\r\n\e[2K'"$line"
  done

  local up_rows=$(( max_drawn + _termpeek_extra_rows ))
  seq+=$'\e['${up_rows}$'A\e['${_termpeek_target_col}'G\e7\e8'
  print -n -u 2 -- "$seq"
  _termpeek_lines_drawn=$total
}

# Asynchronous worker response handler (triggered by zle -F)
_termpeek_async_callback() {
  local fd=$1
  local err=$2

  if [[ -n "$err" || ! -o zle ]]; then
    return 0
  fi

  local line=""
  while (( 1 )); do
    if ! read -r -u $fd line; then
      return 0
    fi
    [[ -z "$line" ]] && return 0

    local -a parts=("${(@ps:\t:)line}")
    local resp_qid="${parts[1]}"

    # If this response matches our current active query, process it
    if (( resp_qid == _termpeek_qid )); then
      local buf="${BUFFER:-$_termpeek_last_buf}"
      local trimmed="${buf## #}"
      trimmed="${trimmed%% #}"
      if [[ ${#trimmed} -lt 2 ]]; then
        _termpeek_clear_display
        return 0
      fi

      local count="${parts[2]}"
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
      fi

      _termpeek_idx=0
      _termpeek_render_display
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

  # Clear display if buffer is empty or 1 character
  if [[ ${#trimmed} -lt 2 || "$current" == "$_termpeek_dismissed_buf" ]]; then
    _termpeek_clear_display
    _termpeek_matches=()
    _termpeek_tags=()
    _termpeek_dangers=()
    _termpeek_displays=()
    _termpeek_idx=0
    return 0
  fi

  # Dispatch query to background worker via non-blocking FIFO write (0 forks)
  if (( _termpeek_in_fd > 0 )); then
    print -u $_termpeek_in_fd -r -- "$_termpeek_qid"$'\t'"$PWD"$'\t'"$current"$'\t'"$_termpeek_prev_cmd" 2>/dev/null
  fi
}

# Arrow Down: navigate down suggestion list
_termpeek_down() {
  if (( ${#_termpeek_matches[@]} > 0 )); then
    if (( _termpeek_idx < ${#_termpeek_matches[@]} )); then
      (( _termpeek_idx++ ))
    else
      _termpeek_idx=1
    fi
    _termpeek_clear_autosuggest
    [[ -o zle ]] && zle -R
    _termpeek_render_display
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
    _termpeek_render_display
    return 0
  elif (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx == 1 )); then
    _termpeek_idx=0
    if (( $+widgets[autosuggest-fetch] )); then
      [[ -o zle ]] && zle autosuggest-fetch
    fi
    [[ -o zle ]] && zle -R
    _termpeek_render_display
    return 0
  fi
  [[ -o zle ]] && zle .up-line-or-history
}

# Tab completion: fills selected item if actively navigating, else normal tab completion
_termpeek_tab() {
  if (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 0 )); then
    _termpeek_clear_display
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
  [[ -o zle ]] && zle expand-or-complete
}

# Right Arrow: fills selected item if actively navigating, else accepts inline autosuggestion
_termpeek_right() {
  if (( CURSOR == $#BUFFER && ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 0 )); then
    _termpeek_clear_display
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

  # Pass through to inline autosuggestion accept if available, else standard forward-char
  if (( $+widgets[autosuggest-accept] )); then
    [[ -o zle ]] && zle autosuggest-accept
    return 0
  fi
  [[ -o zle ]] && zle .forward-char
}

# Enter: execute or review destructive command
_termpeek_enter() {
  _termpeek_clear_display
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
    _termpeek_lines_drawn=0
    POSTDISPLAY=""

    if (( is_danger == 1 )); then
      [[ -o zle ]] && zle -R
      _termpeek_compute_cursor
      local dseq=$'\e7'
      if (( _termpeek_extra_rows > 0 )); then
        dseq+=$'\e['${_termpeek_extra_rows}'B'
      fi
      dseq+=$'\r\n\e[2K⚠️  [DANGER GUARD] Destructive command loaded to prompt for review. Press Enter to run.'
      local up_rows=$(( 1 + _termpeek_extra_rows ))
      dseq+=$'\e['${up_rows}$'A\e['${_termpeek_target_col}'G\e7\e8'
      print -n -u 2 -- "$dseq"
      _termpeek_lines_drawn=1
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
    _termpeek_lines_drawn=0
  fi

  [[ -o zle ]] && zle -R
  [[ -o zle ]] && zle .accept-line
}

# Escape: dismiss preview immediately
_termpeek_escape() {
  _termpeek_clear_display
  _termpeek_clear_autosuggest
  (( _termpeek_qid++ ))
  _termpeek_matches=()
  _termpeek_tags=()
  _termpeek_dangers=()
  _termpeek_displays=()
  _termpeek_idx=0
  _termpeek_dismissed_buf="$BUFFER"
  _termpeek_lines_drawn=0
  [[ -o zle ]] && zle -R
  return 0
}

# Cancel: Ctrl+C / Ctrl+G
_termpeek_cancel() {
  _termpeek_clear_display
  _termpeek_clear_autosuggest
  (( _termpeek_qid++ ))
  _termpeek_matches=()
  _termpeek_tags=()
  _termpeek_dangers=()
  _termpeek_displays=()
  _termpeek_idx=0
  _termpeek_last_buf=""
  _termpeek_dismissed_buf=""
  _termpeek_lines_drawn=0
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
}

_termpeek_clear_screen() {
  _termpeek_clear_display
  zle .clear-screen
}

# Handle terminal resize
TRAPWINCH() {
  _termpeek_clear_display
  if (( ${#_termpeek_matches[@]} > 0 )); then
    _termpeek_render_display
  fi
}

# Cleanup on shell exit
_termpeek_cleanup() {
  _termpeek_clear_display
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
  bindkey '^C' _termpeek_cancel_widget
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
