# Termpeek 2.0: Dual-Layer Shell Architecture & Live Pre-Flight Engine

*   **Author:** zerak jamil
*   **Status:** Approved
*   **Date:** 2026-11-19

--------------------------------------------------------------------------------

## Overview

Termpeek 2.0 re-architects the terminal suggestion engine from an out-of-band VT100 prompt manipulator into a dual-layer shell runtime. It eliminates terminal corruption by decoupling inline ghost completion (handled natively by ZLE via `POSTDISPLAY`) from a high-utility, transient pre-flight inspector (rendered via the terminal alternate screen buffer `\e[?1049h`).

Beyond passive history matching, Termpeek introduces **Live System Pre-Flight Inspection**: an execution-safety and environment-aware engine that peeks at live system preconditions (port availability, git sync status, and file blast-radius) before the user presses Enter.

## The Problem

In Termpeek 1.x, multi-line command suggestions were drawn directly underneath the active prompt line by printing ANSI cursor escapes (`\r\n\e[2K`, `\e[B`, `\e[A`) to `stderr`. This design created a fundamental conflict with Zsh's Line Editor (ZLE):
1. **Uncoordinated Dual Renderers**: ZLE maintains an internal 2D screen buffer tracking prompt length, line wrapping across `$COLUMNS`, and syntax highlighting. Termpeek's out-of-band cursor movements modified physical hardware terminal positions without updating ZLE's internal state.
2. **Line Wrapping Desynchronization**: When commands or prompts exceed `$COLUMNS` (e.g. long file paths like `/Users/.../Crucial_Conversations_Academic_Blueprint.pdf` or dynamic prompt expansions like `%1~`), terminal soft-wrap buffers (`xenl`) were fractured by raw VT100 linefeeds, causing text collisions (e.g., `ueprint.pdfde --continue`) and preventing reverse-wrapping on backspace.
3. **Control Signal Hijacking**: Binding terminal control keys such as `Ctrl+C` (`^C`) to custom widgets trapped the user on corrupted lines instead of delivering standard kernel `SIGINT` prompt aborts.

Termpeek 2.0 solves this by strictly separating inline completion from multi-line inspection, moving all keystroke-time rendering into ZLE's native `POSTDISPLAY` primitive and delegating deep inspection to an isolated alternate screen buffer.

## Goals

*   **100% Screen Integrity**: Zero line splitting, prompt duplication, cursor misplacement, or ghost text on any command length or terminal width.
*   **Native Control Signals**: Absolute preservation of standard shell signal behaviors (`Ctrl+C`, `Ctrl+Z`, `Escape`).
*   **Sub-1ms Keystroke Latency**: Layer 1 inline completion runs entirely in memory with 0 subprocess forks on keystroke events.
*   **Sub-5ms Pre-Flight Diagnostics**: Asynchronous background socket and filesystem checks delivering port collision and git status indicators without blocking user typing.
*   **Failsafe Alternate Buffer Trapping**: Unconditional terminal restoration handlers on `TRAPINT`, `TRAPQUIT`, `TRAPEXIT`, and `zshexit`.
*   **Universal Shell Compatibility**: Seamless operation across macOS, Linux, and Termux (Android).

## Non-Goals

*   Replacing Zsh with an external standalone shell binary (e.g. Nushell, Fish, Warp).
*   Blocking or forcing confirmation prompts (`Are you sure? [y/N]`) before command execution.
*   Integrating network-dependent cloud LLM lookups on the interactive shell keystroke path.

## Resolved Design Decisions

*   **Decision 1 (Layer 2 Invocations)**: Layer 2 Pre-Flight Inspector is summoned exclusively via explicit user chords (`Ctrl+Space`, `Alt+P`, or `Down Arrow`). Spontaneous auto-triggering on typing pauses was rejected to preserve predictable, distraction-free shell typing without unwanted screen buffer flips.
*   **Decision 2 (One-Key Port Killer)**: `Alt+K` port killing is approved with strict defensive safety bounds: `PID > 100`, `PID != $$`, `PID != PPID`, and pre-verification via `kill -0` before issuing signals.

## Critical User Journeys (CUJs)

### CUJ 1: Frictionless Keystroke Completion (Layer 1)

*   **Given**: User is in a git repository or project directory.
*   **When**: User types a command prefix (e.g., `git ch` or `npm run`).
*   **Then**: Termpeek sets `POSTDISPLAY` to the highest-ranked Markov completion in subtle dim styling. ZLE handles line wrapping natively. Keystroke latency is < 1ms. Pressing Right Arrow, Ctrl+F, or Tab accepts completion with zero screen flicker.

### CUJ 2: Live Port Collision Pre-Flight (Layer 2)

*   **Given**: Port `8081` is currently occupied by an orphaned Node process, and user types `xlan` or `npx expo start`.
*   **When**: User presses `Ctrl+Space`, `Alt+P`, or `Down Arrow`.
*   **Then**: Termpeek detects port 8081 collision in < 0.1ms via non-blocking dual-stack socket probe (`127.0.0.1` and `::1`). The transient alternate screen HUD displays: `⚠️ [Port 8081 LOCKED by node (PID 51203) - Press Alt+K to kill process]`. User can press `Alt+K` to terminate the blocker or press Escape to dismiss.

### CUJ 3: Destructive Command Blast-Radius Audit

*   **Given**: User enters a destructive command pattern (e.g., `rm -rf build/` or `git reset --hard HEAD~2`).
*   **When**: User triggers the Pre-Flight Inspector via `Ctrl+Space` or `Alt+P`.
*   **Then**: The Inspector calculates target scope and displays: `⚠️ [BLAST RADIUS: 142 files (12.4 MB) in 'build/' will be deleted]`. User executes with full awareness or cancels cleanly.

--------------------------------------------------------------------------------

## Technical Plan (Architecture)

### Architectural Overview & Decoupling

Termpeek 2.0 decomposes command assistance into three decoupled components:
1. **ZLE Native Frontend (`termpeek.zsh`)**: Operates inside Zsh Line Editor using official hooks (`line-pre-redraw`, `zle -F`, `precmd`, `preexec`).
2. **Asynchronous Daemon Worker (`bin/termpeek-worker`)**: Standalone Python daemon communicating over non-blocking Unix FIFOs. Evaluates Markov frecency ranking and performs live Pre-Flight checks (ports, git divergence, blast radius).
3. **Transient Pre-Flight Viewport (`_termpeek_preflight`)**: Modal terminal view instantiated on the alternate screen buffer (`\e[?1049h`), freezing primary shell state and presenting interactive HUD cards.

```mermaid
flowchart TD
    subgraph Primary Terminal Buffer
        UserKeystroke["User Keystroke / Paste"] --> LinePreRedraw["ZLE hook: line-pre-redraw"]
        LinePreRedraw --> Invalidate["Check & Update FIFO Query"]
        Invalidate -. Non-blocking write .-> WorkerFIFO["In-FIFO: termpeek-$$.in"]
        
        Callback["zle -F Async Callback"] <-- Non-blocking read --- WorkerOutFIFO["Out-FIFO: termpeek-$$.out"]
        Callback --> NativeGhost["Set POSTDISPLAY & region_highlight (Layer 1)"]
        NativeGhost --> ZLERedraw["ZLE Native Screen Redraw (Zero Glitch)"]
    end

    subgraph Alternate Screen Buffer (\e[?1049h)
        TriggerInspection["User Chord: Ctrl+Space / Alt+P / Down Arrow"] --> EnterAltScreen["Switch: \e[?1049h\e[?25l"]
        EnterAltScreen --> ModalHUD["Render Interactive Pre-Flight HUD (Layer 2)"]
        ModalHUD --> UserNav{"User Action"}
        UserNav -- "Alt+K" --> KillProcess["Send SIGTERM to Locking Port PID"]
        UserNav -- "Enter / Tab / Right" --> SelectCmd["BUFFER=$selected; Exit \e[?1049l\e[?25h"]
        UserNav -- "Escape / Ctrl+C / q" --> DismissHUD["Exit \e[?1049l\e[?25h; Reset Prompt"]
    end

    subgraph Background Daemon (termpeek-worker)
        WorkerFIFO --> Dispatcher["Worker Dispatcher"]
        Dispatcher --> MarkovRanker["Markov-Frecency Command Index"]
        Dispatcher --> PreflightInspector["Pre-Flight Engine"]
        PreflightInspector --> SocketProbe["Dual-Stack Socket Check (<0.08ms)"]
        PreflightInspector --> GitProbe[".git/HEAD, refs & packed-refs Probe (<0.5ms)"]
        PreflightInspector --> BlastProbe["Blast-Radius Pattern Evaluator"]
        MarkovRanker & PreflightInspector --> ResponseFormatter["Serialize IPC Payload"]
        ResponseFormatter --> WorkerOutFIFO
    end
```

### Component Breakdown & Contracts

#### 1. Layer 1: Inline Ghost Engine (`POSTDISPLAY`)
* **Mechanism**: On every `line-pre-redraw`, if `BUFFER` changed and length $\ge 2$, dispatch query. When worker responds via `zle -F`, extract top candidate completion suffix:
  ```zsh
  local top_match="${_termpeek_matches[1]}"
  if [[ "$top_match" == "$BUFFER"* ]]; then
    POSTDISPLAY="${top_match#$BUFFER}"
    region_highlight+=("$#BUFFER $(($#BUFFER + $#POSTDISPLAY)) fg=8,underline")
  else
    POSTDISPLAY=""
  fi
  zle -R
  ```
* **Invariants**:
  * Emits **zero** ANSI cursor movement escapes (`\e7`, `\e8`, `\e[B`, `\e[A`) to `stderr` or `stdout`.
  * Allows ZLE to manage 100% of line wrapping, backspacing, and cursor positions.
  * Pressing `Right Arrow` or `Ctrl+F` runs `BUFFER+=$POSTDISPLAY; POSTDISPLAY=""; CURSOR=$#BUFFER`.

#### 2. Layer 2: Sandboxed Alternate-Screen Viewport (`\e[?1049h`)
* **Mechanism**: Bound to `Tab` (when suggestion active) and `Ctrl+Space`:
  1. Save current tty state: `stty -g`.
  2. Send `\e[?1049h\e[?25l` (activate alternate screen buffer, hide cursor).
  3. Enter isolated read loop: read raw keystrokes via `read -k 1`.
  4. Render floating card: prompt reflection at top, numbered candidate completions in middle, Pre-Flight diagnostic badge at bottom.
  5. On `Enter` / completion: populate `BUFFER`, restore screen with `\e[?1049l\e[?25h`, call `zle reset-prompt`.
  6. On `Escape` / `Ctrl+C`: restore screen with `\e[?1049l\e[?25h`, call `zle reset-prompt`.
* **Signal & TTY Resilience**:
  * An `always { ... }` block guarantees that `\e[?1049l\e[?25h` and `stty "$old_stty" 2>/dev/null || stty sane` are unconditionally restored on any exit, signal, or abort.
  * Shell exit hook `add-zsh-hook zshexit _termpeek_cleanup` guarantees FIFO removal and terminal restoration.

#### 3. Pre-Flight Engine in Background Worker (`termpeek-worker`)
* **High-Speed Dual-Stack Socket Prober**:
  * Scans input command for port numbers (explicit `:PORT` or command names like `xlan`, `expo`, `artisan`, `vite`, `uvicorn`, `flask`).
  * Executes non-blocking TCP connect checks across both IPv4 (`127.0.0.1:<port>`) and IPv6 (`[::1]:<port>`).
  * If locked: resolves PID and executable name via targeted `lsof` with Linux/Termux `/proc/net/tcp` fallback.
* **Git Worktree & Ref Prober**:
  * Supports both `.git` directories and `.git` file pointers (for Git worktrees and submodules).
  * Inspects `HEAD`, `refs/heads/<branch>`, `refs/remotes/origin/<branch>`, and `.git/packed-refs` without spawning git child processes.
* **Pattern Blast-Radius Calculator**:
  * Detects patterns: `rm -rf <path>`, `git reset --hard`, `git clean -fd`, `git branch -D`, `docker system prune`.
  * Computes item count and byte size of target path within a 40ms / 1000-item cap.

#### 4. Extended IPC Protocol
* The FIFO frame format carries structured Pre-Flight diagnostics and PID alongside candidate rankings:
  ```text
  QUERY:  <QID>\t<CWD>\t<BUFFER>\t<PREV_CMD>
  RECORD: RECORD\t<CWD>\t<PREV_CMD>\t<EXECUTED_CMD>
  RESPONSE: <QID>\t<COUNT>\t<CMD_1>\t<TAG_1>\t<DANGER_1>\t<DISPLAY_1>...\t<PREFLIGHT_STATUS_CODE>\t<PREFLIGHT_MESSAGE>\t<PREFLIGHT_PID>
  ```
  Preflight status codes:
  * `0`: Clean / No issue.
  * `1`: Warning / Pre-Flight Notice (e.g. Git branch out of sync with origin).
  * `2`: Conflict / Action Required (e.g. Port locked by PID).
  * `3`: High Risk / Destructive Blast Radius.

--------------------------------------------------------------------------------

## Alternatives Considered

### Alternative A: In-Band Multi-Line VT100 Manipulation (Status Quo)

*   **Pros**: Keeps suggestions visible directly below the prompt without switching terminal screen buffers.
*   **Cons**: Unresolvable race conditions with ZLE's internal 2D line editor, line-wrapping calculations across `$COLUMNS`, and terminal auto-wrap flags (`xenl`). Causes prompt duplication on directory change (`%1~`) and destroys reverse-wrapping on backspace.
*   **Reason for Rejection**: Rejected by author. Mathematical impossibility of coordinating two independent screen-writing engines without terminal flicker or corruption.

### Alternative B: Full-Screen TUI Takeover (Atuin / Fzf Default)

*   **Pros**: Complete control over the entire terminal canvas using libraries like `curses` or `prompt_toolkit`.
*   **Cons**: High cognitive disruption during normal typing. Developers typing quick repetitive commands do not want a full-screen window takeover on every keystroke.
*   **Reason for Rejection**: Rejected by author. Intrusive to standard shell flow; reserved exclusively as an on-demand Layer 2 inspector.

### Alternative C: Cloud / LLM-Based Command Predictor

*   **Pros**: Can synthesize novel multi-command scripts from natural language intent.
*   **Cons**: Unacceptable network latency (200ms–2000ms), privacy concerns with local bash histories and secret tokens, cost overhead, and offline failure.
*   **Reason for Rejection**: Rejected by author. Violates the strict sub-2ms local keystroke latency and 100% offline operational invariants.

--------------------------------------------------------------------------------

## Non-Functional Requirements

### 1. Performance & Latency Budgets
* **Keystroke-to-Ghost Redraw (Layer 1)**: Must complete within **< 1.0 ms** on standard laptops. Pure in-memory dictionary lookup; zero forks, zero subshells, zero disk I/O.
* **Pre-Flight Diagnostics (Layer 2)**: Background socket and git ref probes must complete within **< 2.0 ms** inside `termpeek-worker`.
* **Daemon Memory Footprint**: Python worker process memory must remain under **25 MB** RSS after indexing 10,000 history entries.

### 2. Reliability & Terminal Invariants
* **Signal Resilience**: Native `Ctrl+C` (`SIGINT`) must unconditionally abort the current command line and draw a fresh prompt within 10ms.
* **Alternate Screen Cleanup**: Under any exit scenario (normal exit, SIGINT, SIGQUIT, shell exit, daemon crash), the primary terminal screen and cursor visibility (`\e[?25h`) must be restored immediately.
* **Zero Dependency Footprint**: Shell frontend requires only standard Zsh ($\ge 5.8$); worker daemon requires standard Python ($\ge 3.8$) standard library (`socket`, `sqlite3`, `re`, `os`). Zero pip dependencies.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

### Target Files to Create/Modify

#### 1. `termpeek.zsh` (Modify)
*   **Type / Scope**: Zsh Shell Integration & ZLE Line Editor Driver
*   **Proposed Changes**:
    *   **Layer 1 Migration**: Deprecate and remove out-of-band VT100 rendering (`_termpeek_render_display` using `\r\n\e[2K`, `\e[B`, `\e[A`). Implement native `POSTDISPLAY` inline ghosting and `region_highlight` (`fg=8,underline`) inside `_termpeek_async_callback` and `_termpeek_pre_redraw`.
    *   **Layer 2 Pre-Flight Inspector Widget**: Implement `_termpeek_preflight_widget` bound to `Tab` (when suggestion active) and `Ctrl+Space`. It activates the alternate screen buffer (`\e[?1049h\e[?25l`), renders an interactive 6-line card (prompt reflection, candidate completions, live Pre-Flight diagnostic badge), processes raw keystroke events (`Up`, `Down`, `Enter`, `Escape`, `Alt+K`), and cleanly restores the primary buffer (`\e[?1049l\e[?25h`) with `zle reset-prompt`.
    *   **Unconditional Signal Safety**: Register emergency cleanup handlers on `TRAPINT`, `TRAPQUIT`, `TRAPEXIT`, and `zshexit` ensuring terminal state and cursor visibility are always restored.
    *   **Extended IPC Parsing**: Parse tab-delimited pre-flight status codes and diagnostic strings returned by the daemon.

#### 2. `bin/termpeek-worker` (Modify)
*   **Type / Scope**: Asynchronous Background Python Daemon
*   **Proposed Changes**:
    *   **`PreflightInspector` Module**: Add a lightweight pre-flight engine inside `termpeek-worker`.
    *   **Native Socket Prober**: Implement `probe_ports(cmd)` using Python's `socket.connect_ex` on loopback `127.0.0.1:<port>` for ports found in commands (e.g. 8081, 3000, 8000, 8080, 5000). Resolves locking PID and process name asynchronously.
    *   **Git Ref Prober**: Implement `probe_git(cwd, cmd)` by inspecting `.git/HEAD`, `.git/refs/heads/`, and `.git/FETCH_HEAD` directly via file stat to detect ahead/behind divergence and dirty worktree flags without spawning git CLI processes.
    *   **Blast-Radius Evaluator**: Implement `probe_blast_radius(cwd, cmd)` to calculate affected target file counts and directory sizes for destructive patterns (`rm -rf`, `git reset --hard`).
    *   **IPC Payload Update**: Append pre-flight diagnostic status code and message to serialized responses.

#### 3. `tests/test_harness.py` (Modify)
*   **Type / Scope**: Headless PTY 2D VT100 Framebuffer Test Suite
*   **Proposed Changes**:
    *   **Test 12 (Layer 1 Pure `POSTDISPLAY` Oracle)**: Asserts that typing keystrokes emits zero cursor repositioning escape sequences (`\e[A`, `\e[B`, `\r\n\e[2K`) on `stderr` and populates native `POSTDISPLAY`.
    *   **Test 13 (Layer 2 Alternate Buffer Trapping & HUD Oracle)**: Asserts that triggering `_termpeek_preflight` sends `\e[?1049h`, displays the pre-flight card, and cleanly exits with `\e[?1049l` on Escape or Ctrl+C.
    *   **Test 14 (Live Port Collision Pre-Flight Oracle)**: Binds a mock TCP socket on port `8081`, types `xlan`, triggers pre-flight, and proves the HUD displays `[Port 8081: LOCKED by python3 (PID ...)]` within < 2ms.

#### 4. `tests/test_termpeek.zsh` (Modify)
*   **Type / Scope**: Shell Unit Test Suite
*   **Proposed Changes**:
    *   Add automated unit tests verifying `POSTDISPLAY` suffix calculation, tab completion behavior, and signal trap registration.

#### 5. `README.md` (Modify)
*   **Type / Scope**: User Documentation & Architecture Reference
*   **Proposed Changes**:
    *   Document the Dual-Layer Shell Architecture, keybindings (`Tab`, `Ctrl+Space`, `Alt+K`), and Pre-Flight capabilities.

--------------------------------------------------------------------------------

## Verification Plan

### Automated Test Suite Execution
1. **Unit Test Pass**:
   * Command: `zsh tests/test_termpeek.zsh`
   * Requirement: All unit tests pass with zero errors.
2. **2D VT100 Framebuffer PTY Suite Pass**:
   * Command: `python3 tests/test_harness.py`
   * Requirement: All 14 PTY verification suites pass. P99 keystroke latency must remain **< 2.5 ms**.
3. **Chronological Ranking Benchmark Pass**:
   * Command: `python3 tests/benchmark_ranking.py`
   * Requirement: Hit@1 > 90%, Hit@4 > 90%, MRR > 0.900, P99 query latency **< 1.0 ms**.
4. **Clean Code & Comment Hygiene Audit**:
   * Command: `! grep -rn $'\xe2\x80\x94' termpeek.zsh bin/termpeek-worker tests/`
   * Requirement: Zero em dashes, zero AI comment fluff, clean idiomatic code.

--------------------------------------------------------------------------------

*Drafted with EGM*
