#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
START_MARKER="# >>> goose-term-suggest >>>"
END_MARKER="# <<< goose-term-suggest <<<"

mkdir -p "$(dirname "$ZSHRC")"
touch "$ZSHRC"

BLOCK=$(cat <<EOF
$START_MARKER
export GOOSE_TERM_SUGGEST_HOME="$PROJECT_ROOT"
[ -f "\$GOOSE_TERM_SUGGEST_HOME/lib/goose-terminal-suggest.zsh" ] && source "\$GOOSE_TERM_SUGGEST_HOME/lib/goose-terminal-suggest.zsh"
$END_MARKER
EOF
)

TMP_FILE="$(mktemp)"

if grep -Fqx "$START_MARKER" "$ZSHRC" && grep -Fqx "$END_MARKER" "$ZSHRC"; then
  awk -v start="$START_MARKER" -v end="$END_MARKER" -v block="$BLOCK" '
    BEGIN {
      in_block = 0
      replaced = 0
    }
    $0 == start {
      if (!replaced) {
        print block
        replaced = 1
      }
      in_block = 1
      next
    }
    $0 == end {
      in_block = 0
      next
    }
    !in_block {
      print
    }
    END {
      if (!replaced) {
        if (NR > 0) {
          print ""
        }
        print block
      }
    }
  ' "$ZSHRC" > "$TMP_FILE"
else
  cat "$ZSHRC" > "$TMP_FILE"
  if [[ -s "$TMP_FILE" && "$(tail -c 1 "$TMP_FILE" 2>/dev/null || true)" != $'\n' ]]; then
    printf '\n' >> "$TMP_FILE"
  fi
  if [[ -s "$TMP_FILE" ]]; then
    printf '\n' >> "$TMP_FILE"
  fi
  printf '%s\n' "$BLOCK" >> "$TMP_FILE"
fi

mv "$TMP_FILE" "$ZSHRC"

echo "Installed goose-term-suggest into $ZSHRC"
echo 'Ensure Goose terminal init is configured separately, e.g. eval "$(goose term init zsh)"'
echo "Reload with: exec zsh"
