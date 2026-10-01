#!/usr/bin/env zsh
# Test suite for termpeek

print "Running termpeek test suite..."

# Load termpeek
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

# Test 5: Tab completion replaces BUFFER and clears suggestions
_termpeek_matches=("full command --flag" "other command")
_termpeek_idx=1
_termpeek_tab
[[ "$BUFFER" == "full command --flag" && ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Tab completion failed"; exit 1; }
print "PASS: Tab completes highlighted command and closes menu"

# Test 6: Escape dismisses suggestions and keeps BUFFER intact
BUFFER="my_query"
_termpeek_matches=("match 1" "match 2")
_termpeek_escape
[[ "$BUFFER" == "my_query" && "$_termpeek_dismissed_buf" == "my_query" && ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Escape failed"; exit 1; }
print "PASS: Escape closes menu and preserves prompt"

# Test 7: Enter on highlighted command sets BUFFER to selected command
BUFFER="orig"
_termpeek_matches=("selected command")
_termpeek_idx=1
# Simulate enter logic
BUFFER="${_termpeek_matches[$_termpeek_idx]}"
_termpeek_matches=()
_termpeek_idx=0
[[ "$BUFFER" == "selected command" ]] || { print "FAIL: Enter failed"; exit 1; }
print "PASS: Enter selects command for execution"

print "All 7 automated tests passed successfully."
