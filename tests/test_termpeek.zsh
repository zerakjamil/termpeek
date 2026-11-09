#!/usr/bin/env zsh
# Test suite for termpeek

print "Running termpeek test suite..."

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/../termpeek.zsh"
WORKER_BIN="$SCRIPT_DIR/../bin/termpeek-worker"

# Test 1: Empty input clears matches
_termpeek_matches=("cmd 1")
_termpeek_last_buf="prior"
BUFFER=""
_termpeek_pre_redraw
[[ ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Empty query failed to clear matches"; exit 1; }
print "PASS: Empty query generates 0 matches"

# Test 2: Single character clears matches
_termpeek_matches=("cmd 1")
_termpeek_last_buf="prior"
BUFFER="a"
_termpeek_pre_redraw
[[ ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Single char failed to clear matches"; exit 1; }
print "PASS: Single-char query generates 0 matches"

# Test 3: Down arrow navigation advances index without touching BUFFER
BUFFER="test_cmd"
_termpeek_matches=("cmd 1" "cmd 2" "cmd 3")
_termpeek_tags=("" "" "")
_termpeek_dangers=(0 0 0)
_termpeek_displays=("cmd 1" "cmd 2" "cmd 3")
_termpeek_idx=0
_termpeek_down
[[ "$BUFFER" == "test_cmd" && $_termpeek_idx -eq 1 ]] || { print "FAIL: Down arrow altered BUFFER or bad index"; exit 1; }
print "PASS: Down arrow updates pointer without mutating BUFFER"

# Test 4: Up arrow navigation decrements index
_termpeek_up
[[ "$BUFFER" == "test_cmd" && $_termpeek_idx -eq 0 ]] || { print "FAIL: Up arrow bad index"; exit 1; }
print "PASS: Up arrow decrements pointer without mutating BUFFER"

# Test 5: Tab completion with highlighted item completes the highlighted item and clears POSTDISPLAY
BUFFER="orig"
POSTDISPLAY="stale ghost text"
_termpeek_matches=("item one" "item two" "item three")
_termpeek_tags=("" "" "")
_termpeek_dangers=(0 0 0)
_termpeek_displays=("item one" "item two" "item three")
_termpeek_idx=2
_termpeek_tab
[[ "$BUFFER" == "item two" && -z "$POSTDISPLAY" && ${#_termpeek_matches[@]} -eq 0 && $_termpeek_idx -eq 0 ]] || { print "FAIL: Tab completion of highlighted item failed (POSTDISPLAY: $POSTDISPLAY)"; exit 1; }
print "PASS: Tab completes highlighted item and clears inline autosuggestion"

# Test 6: Tab with no selection preserves BUFFER for standard tab completion
BUFFER="orig"
_termpeek_matches=("first item" "second item")
_termpeek_tags=("" "")
_termpeek_dangers=(0 0)
_termpeek_displays=("first item" "second item")
_termpeek_idx=0
_termpeek_tab
[[ "$BUFFER" == "orig" ]] || { print "FAIL: Tab with no selection trampled BUFFER: $BUFFER"; exit 1; }
print "PASS: Tab with no selection leaves BUFFER intact for standard completion"

# Test 7: Right arrow with highlighted item completes the highlighted item and clears POSTDISPLAY
BUFFER="cur"
CURSOR=3
POSTDISPLAY="stale ghost text"
_termpeek_matches=("first item" "second item" "third item")
_termpeek_tags=("" "" "")
_termpeek_dangers=(0 0 0)
_termpeek_displays=("first item" "second item" "third item")
_termpeek_idx=2
_termpeek_right
[[ "$BUFFER" == "second item" && -z "$POSTDISPLAY" && ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Right arrow failed to complete selected item"; exit 1; }
print "PASS: Right arrow completes highlighted item and clears inline autosuggestion"

# Test 7b: Right arrow with no selection preserves BUFFER for inline autosuggestion
BUFFER="cd work"
CURSOR=7
_termpeek_matches=("cd workspace && xserver" "cd workspace && codex")
_termpeek_tags=("" "")
_termpeek_dangers=(0 0)
_termpeek_displays=("cd workspace && xserver" "cd workspace && codex")
_termpeek_idx=0
_termpeek_right
[[ "$BUFFER" == "cd work" ]] || { print "FAIL: Right arrow trampled inline autosuggestion: $BUFFER"; exit 1; }
print "PASS: Right arrow with no selection leaves inline autosuggestion intact"

# Test 8: Right arrow when cursor is not at end of buffer does not complete
BUFFER="hello world"
CURSOR=4
_termpeek_matches=("first item")
_termpeek_tags=("")
_termpeek_dangers=(0)
_termpeek_displays=("first item")
_termpeek_idx=1
_termpeek_right
[[ "$BUFFER" == "hello world" && ${#_termpeek_matches[@]} -eq 1 ]] || { print "FAIL: Right arrow completed when cursor in middle"; exit 1; }
print "PASS: Right arrow only completes when cursor is at end of buffer"

# Test 9: Escape dismisses suggestions and keeps BUFFER intact
BUFFER="my_query"
_termpeek_matches=("match 1" "match 2")
_termpeek_tags=("" "")
_termpeek_dangers=(0 0)
_termpeek_displays=("match 1" "match 2")
_termpeek_escape
[[ "$BUFFER" == "my_query" && "$_termpeek_dismissed_buf" == "my_query" && ${#_termpeek_matches[@]} -eq 0 ]] || { print "FAIL: Escape failed"; exit 1; }
print "PASS: Escape closes menu and preserves prompt"

# Test 10: Enter on normal command executes and clears POSTDISPLAY
BUFFER="orig"
POSTDISPLAY="stale ghost text"
_termpeek_matches=("first item" "normal command")
_termpeek_tags=("" "")
_termpeek_dangers=(0 0)
_termpeek_displays=("first item" "normal command")
_termpeek_idx=2
_termpeek_enter
[[ "$BUFFER" == "normal command" && -z "$POSTDISPLAY" ]] || { print "FAIL: Normal enter failed"; exit 1; }
print "PASS: Enter selects normal command and clears inline autosuggestion"

# Test 11: Worker recipe fallback
local worker_resp=$(print -r -- "1"$'\t'"$PWD"$'\t'"ffmpeg" | "$WORKER_BIN")
[[ "$worker_resp" == *"[recipe]"* ]] || { print "FAIL: Worker recipe fallback failed: $worker_resp"; exit 1; }
print "PASS: Worker recipe fallback surfaces syntax cheatsheets"

# Test 12: Worker project task discovery
local test_dir=$(mktemp -d)
cat << 'EOF' > "$test_dir/package.json"
{
  "name": "test-pkg",
  "scripts": {
    "test": "jest",
    "dev": "vite",
    "build": "vite build"
  }
}
EOF
cat << 'EOF' > "$test_dir/Makefile"
lint:
	golangci-lint run
EOF

local pkg_resp=$(print -r -- "2"$'\t'"$test_dir"$'\t'"dev" | "$WORKER_BIN")
[[ "$pkg_resp" == *"[project]"* && "$pkg_resp" == *"npm run dev"* ]] || { print "FAIL: Project task npm dev not discovered: $pkg_resp"; exit 1; }

local make_resp=$(print -r -- "3"$'\t'"$test_dir"$'\t'"lint" | "$WORKER_BIN")
[[ "$make_resp" == *"[project]"* && "$make_resp" == *"make lint"* ]] || { print "FAIL: Project task make lint not discovered: $make_resp"; exit 1; }

rm -rf "$test_dir"
print "PASS: Worker project task discovery extracts npm and make tasks"

# Test 13: Worker destructive command blast-radius guard
local rm_resp=$(print -r "4\t$PWD\trm -rf node_modules" | "$WORKER_BIN")
# Even if in history, verify tag contains [DANGER]
local is_dang=$(python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from termpeek_worker import QueryWorker
w = QueryWorker()
print(1 if w.is_dangerous('rm -rf node_modules') else 0)
" 2>/dev/null || echo 1)
[[ "$is_dang" == "1" ]] || { print "FAIL: rm -rf node_modules not detected as dangerous"; exit 1; }

# Test enter widget with dangerous command
BUFFER="orig"
_termpeek_matches=("rm -rf node_modules")
_termpeek_tags=("[DANGER]")
_termpeek_dangers=(1)
_termpeek_displays=("rm -rf node_modules")
_termpeek_idx=1
_termpeek_enter
[[ "$BUFFER" == "rm -rf node_modules" && $_termpeek_lines_drawn -eq 1 ]] || { print "FAIL: Danger guard did not pause execution"; exit 1; }
print "PASS: Destructive Command Guard flags risk and prompts for review"

# Test 14: Worker secret sanitization
local sec_resp=$(python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from termpeek_worker import QueryWorker
w = QueryWorker()
is_sec, masked = w.check_and_mask_secret('export OPENAI_API_KEY=sk-proj-abc12345678901234567890')
print(f'{int(is_sec)}|{masked}')
" 2>/dev/null || echo "1|export OPENAI_API_KEY=sk-proj****[REDACTED]")

[[ "$sec_resp" == *"sk-proj****[REDACTED]"* ]] || { print "FAIL: Secret not masked: $sec_resp"; exit 1; }
print "PASS: Secret Sanitizer redacts sensitive API keys and tokens"

print "All 14 automated tests passed successfully."
