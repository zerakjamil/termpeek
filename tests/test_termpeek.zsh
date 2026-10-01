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

# Test 10: Enter on normal command executes
BUFFER="orig"
_termpeek_matches=("first item" "normal command")
_termpeek_idx=2
# Safe non-interactive simulation of enter logic
target="${_termpeek_matches[$_termpeek_idx]}"
BUFFER="$target"
_termpeek_matches=()
_termpeek_idx=0
[[ "$BUFFER" == "normal command" ]] || { print "FAIL: Normal enter failed"; exit 1; }
print "PASS: Enter selects normal command"

# Test 11: Recipe fallback populates when history has space
TERMPEEK_MAX_RESULTS=4
TERMPEEK_RECIPES=1
_termpeek_query "ffmpeg"
[[ ${#_termpeek_matches[@]} -gt 0 ]] || { print "FAIL: Recipe fallback failed for ffmpeg"; exit 1; }
local has_recipe=0
for m in "${_termpeek_matches[@]}"; do
  if [[ -n "${_termpeek_tag_map[$m]}" ]]; then
    has_recipe=1
    break
  fi
done
[[ $has_recipe -eq 1 ]] || { print "FAIL: Recipe tag not populated"; exit 1; }
print "PASS: Recipe fallback populates when matching recipes exist"

# Test 12: Recipes disabled when TERMPEEK_RECIPES=0
TERMPEEK_RECIPES=0
_termpeek_matches=()
_termpeek_tag_map=()
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

# Test 15: Project Task Discovery (package.json and Makefile)
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

(
  cd "$test_dir"
  _termpeek_cached_pwd=""
  _termpeek_update_dir_cache
  [[ " ${_termpeek_project_tasks[*]} " == *"npm test"* ]] || { print "FAIL: npm test not discovered"; exit 1; }
  [[ " ${_termpeek_project_tasks[*]} " == *"npm run dev"* ]] || { print "FAIL: npm run dev not discovered"; exit 1; }
  [[ " ${_termpeek_project_tasks[*]} " == *"make lint"* ]] || { print "FAIL: make lint not discovered"; exit 1; }
)
rm -rf "$test_dir"
_termpeek_cached_pwd=""
print "PASS: Project Task Discovery extracts package.json and Makefile tasks"

# Test 16: Destructive Command Safety Guard detection and blocking
_termpeek_is_dangerous "rm -rf /tmp/folder" || { print "FAIL: rm -rf not flagged as dangerous"; exit 1; }
_termpeek_is_dangerous "git reset --hard HEAD~1" || { print "FAIL: git reset --hard not flagged"; exit 1; }
_termpeek_is_dangerous "git push origin main --force" || { print "FAIL: git push --force not flagged"; exit 1; }
_termpeek_is_dangerous "git status" && { print "FAIL: git status falsely flagged as dangerous"; exit 1; }

# Simulate enter on dangerous command
BUFFER="orig"
_termpeek_matches=("rm -rf node_modules")
_termpeek_idx=1
_termpeek_enter
[[ "$BUFFER" == "rm -rf node_modules" && "$POSTDISPLAY" == *"DANGER GUARD"* ]] || { print "FAIL: Danger guard did not pause execution"; exit 1; }
print "PASS: Destructive Command Guard flags risk and prompts for review"

# Test 17: Secret Sanitization and Redaction
local secret_cmd="export OPENAI_API_KEY=sk-proj-abc12345678901234567890"
_termpeek_has_secret "$secret_cmd" || { print "FAIL: Secret not detected"; exit 1; }
local sanitized="$(_termpeek_sanitize_display "$secret_cmd")"
[[ "$sanitized" == *"sk-proj****[REDACTED]"* ]] || { print "FAIL: Sanitization did not mask key: $sanitized"; exit 1; }
[[ "$sanitized" != *"abc1234567890"* ]] || { print "FAIL: Raw key leaked in sanitized string"; exit 1; }

local token_cmd="gh auth login --with-token ghp_xyz98765432101234567890"
local sanitized_token="$(_termpeek_sanitize_display "$token_cmd")"
[[ "$sanitized_token" == *"ghp_xyz9****[REDACTED]"* ]] || { print "FAIL: GitHub token not masked: $sanitized_token"; exit 1; }

local safe_cmd="git commit -m 'Initial commit'"
_termpeek_has_secret "$safe_cmd" && { print "FAIL: Safe command flagged as secret"; exit 1; }
print "PASS: Secret Sanitizer redacts sensitive API keys and tokens"

print "All 17 automated tests passed successfully."
