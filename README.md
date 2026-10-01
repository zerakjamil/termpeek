# termpeek

Live type-ahead command history search for Zsh.

When you type a keyword into your terminal, matching commands from your recent history appear right below your prompt. You can navigate through them, fill the prompt with Tab to tweak flags, run immediately with Enter, or dismiss with Escape.

## Why it exists

Shell history tools usually fall into two categories:

1. **Inline ghost suggestions** (like `zsh-autosuggestions`): Fast, but only match from the start of the command line. If you type `workspace`, it misses `cd workspace` or `python run.py --dir workspace`.
2. **Modal search popups** (like `fzf` or `atuin`): Powerful, but you have to interrupt your typing, hit a hotkey (`Ctrl+R`), search in a separate box, and exit back to the prompt.

`termpeek` bridges the gap. As you type regular commands, it looks through your history for matches containing that keyword and shows up to 4 recent commands underneath.

## How it works

- **Non-destructive browsing**: Moving through suggestions with Down and Up arrow keys never replaces what you typed. Your prompt stays clean, and your undo history stays intact.
- **Tab to complete**: Pressing Tab fills the command line with the selected command and puts your cursor at the end, so you can edit flags or arguments.
- **Enter to run**: Pressing Enter on a selected suggestion runs it immediately. If nothing is selected, it runs what you typed.
- **Escape to dismiss**: Pressing Escape hides the suggestions so you can keep typing without distractions.
- **Normal history untouched**: When your prompt is empty, Up and Down arrows work as standard shell history navigation.

## Controls

| Key | Action |
| :--- | :--- |
| **Type (2+ chars)** | Searches recent history and displays matches below the prompt |
| **Down Arrow (`↓`)** | Move pointer down through suggestions |
| **Up Arrow (`↑`)** | Move pointer up through suggestions |
| **Tab** | Fill prompt with selected command to edit |
| **Enter** | Run selected command immediately |
| **Escape** | Close suggestions and keep typing |
| **Up Arrow (empty prompt)** | Standard shell history |

## Installation

### Manual

Clone this repository:

```bash
git clone https://github.com/zerakjamil/termpeek.git ~/.termpeek
```

Add this line to your `~/.zshrc`:

```bash
source ~/.termpeek/termpeek.zsh
```

Then reload your shell:

```bash
exec zsh
```

### Oh My Zsh

1. Clone into your custom plugins directory:
   ```bash
   git clone https://github.com/zerakjamil/termpeek.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/termpeek
   ```
2. Add `termpeek` to the plugins list in your `~/.zshrc`:
   ```bash
   plugins=(... termpeek)
   ```

### Zinit

Add this to your `~/.zshrc`:

```bash
zinit light zerakjamil/termpeek
```

## History backends

`termpeek` works out of the box with standard Zsh history (`~/.zsh_history`).

If you have [Atuin](https://github.com/atuinsh/atuin) installed, `termpeek` automatically detects its SQLite database (`~/.local/share/atuin/history.db`) for faster lookups and deduplication across terminal tabs.

## Running tests

Run the included test script to verify state machine behavior:

```bash
./tests/test_termpeek.zsh
```

## License

MIT
