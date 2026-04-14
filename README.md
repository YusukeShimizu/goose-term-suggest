# goose-term-suggest

Warp-like command prefills for `zsh`, powered by Goose and McFly history.

When a new terminal opens, or when you `cd` into another directory, this project asks Goose for the most likely next shell command based on:

- the current `pwd`
- the current git repository root
- the last command you ran and its exit status
- successful and recent commands from McFly history

The suggested command is inserted into the input buffer, but it is never executed automatically.

## Requirements

- `zsh`
- `goose`
- `mcfly` with a populated history database
- `python3`

## Install

```bash
git clone <repo-url> ~/Desktop/goose-term-suggest
cd ~/Desktop/goose-term-suggest
./install.sh
exec zsh
```

If you already copied the project manually, just run:

```bash
cd ~/Desktop/goose-term-suggest
./install.sh
exec zsh
```

## Behavior

- Runs `eval "$(goose term init zsh)"` automatically if the current shell does not already have `AGENT_SESSION_ID`.
- On shell start and after `cd`, queries Goose for a single command suggestion.
- Reads command history from `~/Library/Application Support/McFly/history.db`.
- Passes the last shell command and its exit status to Goose on each refresh.
- If the last command exited with status `1`, it prefers a fix-oriented follow-up such as verbose reruns or targeted inspection for that command.
- Falls back to a history-based command if Goose does not return a valid single-line command.
- Press `Ctrl+G` to refresh the suggestion manually. If you already typed a partial command, Goose is asked to continue that prefix.
- If you press Enter on a simple unknown command such as `s`, the shell first asks Goose for a matching completion and replaces the buffer instead of immediately failing with `command not found`.

## Configuration

Optional environment variables:

```bash
export GOOSE_TERM_SUGGEST_MODEL="gpt-5.4-nano-medium"
export GOOSE_TERM_SUGGEST_MCFLY_DB="$HOME/Library/Application Support/McFly/history.db"
```

Set them before sourcing `lib/goose-terminal-suggest.zsh`.

## Uninstall

Remove the block between:

```bash
# >>> goose-term-suggest >>>
# <<< goose-term-suggest <<<
```

from `~/.zshrc`, then delete the project directory.
