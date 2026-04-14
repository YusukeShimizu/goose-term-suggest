# goose-term-suggest

Minimal command prefills for `zsh`, powered by Goose.

On shell start and after `cd`, this project asks Goose for a single shell command suggestion for the current directory and prefills it into an empty prompt buffer. The command is never executed automatically.

## Requirements

- `zsh`
- `goose`
- Goose terminal integration already initialized in your shell, for example:

```bash
eval "$(goose term init zsh)"
```

This project does not run Goose init for you, and it does not define or modify `@g` / `@goose`.

By default, suggestions use `gpt-5.4-nano-low`. You can override that with:

```bash
export GOOSE_TERM_SUGGEST_MODEL="gpt-5.4-nano-low"
```

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

- On shell start, fetches one suggestion for the current directory.
- After `cd`, fetches one new suggestion for the new directory.
- Inserts the suggestion only when the prompt buffer is empty.
- Does nothing if `goose` is unavailable or `AGENT_SESSION_ID` is unset.
- Uses `goose term run` against your existing Goose terminal session.
- Rejects empty or multiline Goose output instead of forcing a fallback command.

## Uninstall

Remove the block between:

```bash
# >>> goose-term-suggest >>>
# <<< goose-term-suggest <<<
```

from `~/.zshrc`, then delete the project directory.
