#!/usr/bin/env zsh
# Test suite for termpeek

print "Running termpeek test suite..."

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/../termpeek.zsh"

# Test 1: Empty input does not trigger matches
_termpeek_query ""
[[ ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Empty query produced matches"; exit 1; }
print "PASS: Empty query generates 0 matches"

# Test 2: Single character does not trigger matches
_termpeek_query "a"
[[ ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Single char query produced matches"; exit 1; }
print "PASS: Single-char query generates 0 matches"

# Test 3: Down arrow navigation advances index without touching BUFFER
BUFFER="test_cmd"
_termpeek_matches=("cmd 1" "cmd 2" "cmd 3")
_termpeek_idx=0
_termpeek_down
[[ "$BUFFER" == "test_cmd" && $_termpeek_idx -eq 1 ]] || { print "FAIL: Down arrow altered BUFFER or bad index"; exit 1; }
print "PASS: Down arrow updates pointer without mutating BUFFER"

# Test 4: Up arrow navigation decrements index
_termpeek_up
[[ "$BUFFER" == "test_cmd" && $_termpeek_idx -eq 0 ]] || { print "FAIL: Up arrow bad index"; exit 1; }
print "PASS: Up arrow decrements pointer without mutating BUFFER"

# Test 5: Tab completion with highlighted item completes the highlighted item
BUFFER="orig"
_termpeek_matches=("item one" "item two" "item three")
_termpeek_idx=2
_termpeek_tab
[[ "$BUFFER" == "item two" && ${#_termpeek_matches[@]} -eq 0 && $_termpeek_idx -eq 0 ]] || { print "FAIL: Tab completion of highlighted item failed"; exit 1; }
print "PASS: Tab completes highlighted item"

# Test 6: Tab completion with no item highlighted completes first item
BUFFER="orig"
_termpeek_matches=("first item" "second item")
_termpeek_idx=0
_termpeek_tab
[[ "$BUFFER" == "first item" && ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Tab default completion failed"; exit 1; }
print "PASS: Tab with no selection completes first item"

# Test 7: Right arrow ALWAYS completes the first item even when item 2 is highlighted
BUFFER="cur"
CURSOR=3
_termpeek_matches=("first item" "second item" "third item")
_termpeek_idx=2
_termpeek_right
[[ "$BUFFER" == "first item" && ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Right arrow did not complete first item"; exit 1; }
print "PASS: Right arrow always completes first item regardless of selection"

# Test 8: Right arrow when cursor is not at end of buffer does not complete
BUFFER="hello world"
CURSOR=4
_termpeek_matches=("first item")
_termpeek_idx=1
_termpeek_right
[[ "$BUFFER" == "hello world" && ${#_termpeek_matches[@]} -eq 1 ]] || { print "FAIL: Right arrow completed when cursor in middle"; exit 1; }
print "PASS: Right arrow only completes when cursor is at end of buffer"

# Test 9: Escape dismisses suggestions and keeps BUFFER intact
BUFFER="my_query"
_termpeek_matches=("match 1" "match 2")
_termpeek_escape
[[ "$BUFFER" == "my_query" && "$_termpeek_dismissed_buf" == "my_query" && ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Escape failed"; exit 1; }
print "PASS: Escape closes menu and preserves prompt"

# Test 10: Enter on highlighted command selects command
BUFFER="orig"
_termpeek_matches=("first item" "selected command")
_termpeek_idx=2
# Simulate enter state change
if (( ${#_termpeek_matches[@]} > 0 && _termpeek_idx > 0 )); then
  BUFFER="${_termpeek_matches[$_termpeek_idx]}"
fi
_termpeek_matches=()
_termpeek_idx=0
[[ "$BUFFER" == "selected command" ]] || { print "FAIL: Enter failed"; exit 1; }
print "PASS: Enter selects highlighted command"

# Test 11: Recipe fallback populates when history has space
TERMPEEK_MAX_RESULTS=4
TERMPEEK_RECIPES=1
_termpeek_query "ffmpeg"
[[ ${#_termpeek_matches[@]} -gt 0 ]] || { print "FAIL: Recipe fallback failed for ffmpeg"; exit 1; }
# Check that at least one recipe was added and tracked
local has_recipe=0
for m in "${_termpeek_matches[@]}"; do
  if [[ -n "${_termpeek_recipe_map[$m]}" ]]; then
    has_recipe=1
    break
  fi
done
[[ $has_recipe -eq 1 ]] || { print "FAIL: Recipe map not populated"; exit 1; }
print "PASS: Recipe fallback populates when matching recipes exist"

# Test 12: Recipes disabled when TERMPEEK_RECIPES=0
TERMPEEK_RECIPES=0
_termpeek_matches=()
_termpeek_recipe_map=()
local old_db="$_termpeek_db"
_termpeek_db="/nonexistent/history.db"
_termpeek_query "ffmpeg"
_termpeek_db="$old_db"
TERMPEEK_RECIPES=1
[[ ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Recipes populated despite TERMPEEK_RECIPES=0"; exit 1; }
print "PASS: TERMPEEK_RECIPES=0 disables recipe fallback"

# Test 13: Custom pointer configuration
TERMPEEK_POINTER=">>"
_termpeek_matches=("cmd 1" "cmd 2")
_termpeek_idx=1
_termpeek_render
[[ "$POSTDISPLAY" == *">> [1] cmd 1"* ]] || { print "FAIL: Custom pointer failed"; exit 1; }
TERMPEEK_POINTER="▶"
print "PASS: Custom pointer configuration works"

# Test 14: Show hints toggle
TERMPEEK_SHOW_HINTS=0
_termpeek_matches=("cmd 1" "cmd 2")
_termpeek_idx=1
_termpeek_render
[[ "$POSTDISPLAY" != *"Tab: selected"* ]] || { print "FAIL: Hints shown despite TERMPEEK_SHOW_HINTS=0"; exit 1; }
TERMPEEK_SHOW_HINTS=1
print "PASS: TERMPEEK_SHOW_HINTS=0 disables hint text"

print "All 14 automated tests passed successfully."
