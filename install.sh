#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"

chmod +x "$PROJECT_ROOT/bin/goose-term-suggest"

python3 - "$PROJECT_ROOT" "$ZSHRC" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

project_root = Path(sys.argv[1]).resolve()
zshrc = Path(sys.argv[2]).expanduser()
zshrc.parent.mkdir(parents=True, exist_ok=True)
if not zshrc.exists():
    zshrc.write_text("", encoding="utf-8")

start = "# >>> goose-term-suggest >>>"
end = "# <<< goose-term-suggest <<<"
block = "\n".join(
    [
        start,
        f'export GOOSE_TERM_SUGGEST_HOME="{project_root}"',
        '[ -f "$GOOSE_TERM_SUGGEST_HOME/lib/goose-terminal-suggest.zsh" ] && source "$GOOSE_TERM_SUGGEST_HOME/lib/goose-terminal-suggest.zsh"',
        end,
        "",
    ]
)

content = zshrc.read_text(encoding="utf-8")
if start in content and end in content:
    prefix, rest = content.split(start, 1)
    _, suffix = rest.split(end, 1)
    updated = prefix.rstrip("\n") + "\n" + block + suffix.lstrip("\n")
else:
    updated = content.rstrip("\n") + "\n\n" + block

zshrc.write_text(updated, encoding="utf-8")
PY

echo "Installed goose-term-suggest into $ZSHRC"
echo "Reload with: exec zsh"
