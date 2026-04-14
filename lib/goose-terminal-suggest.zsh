#!/usr/bin/env zsh

if [[ -n "${GOOSE_TERM_SUGGEST_LOADED:-}" ]]; then
  return 0
fi
typeset -g GOOSE_TERM_SUGGEST_LOADED=1

autoload -Uz add-zsh-hook
autoload -Uz add-zle-hook-widget 2>/dev/null || true

typeset -g GOOSE_TERM_SUGGEST_HOME="${GOOSE_TERM_SUGGEST_HOME:-${${(%):-%N}:A:h:h}}"
typeset -g GOOSE_TERM_SUGGEST_BIN="${GOOSE_TERM_SUGGEST_BIN:-$GOOSE_TERM_SUGGEST_HOME/bin/goose-term-suggest}"
typeset -g GOOSE_TERM_SUGGEST_MODEL="${GOOSE_TERM_SUGGEST_MODEL:-gpt-5-nano}"
typeset -g GOOSE_TERM_SUGGEST_MCFLY_DB="${GOOSE_TERM_SUGGEST_MCFLY_DB:-$HOME/Library/Application Support/McFly/history.db}"
typeset -g GOOSE_TERM_SUGGEST_PENDING=""
typeset -g GOOSE_TERM_SUGGEST_LAST_KEY=""
typeset -g GOOSE_TERM_SUGGEST_NEEDS_REFRESH=1

if command -v goose >/dev/null 2>&1 && [[ -z "${AGENT_SESSION_ID:-}" ]]; then
  eval "$(goose term init zsh)"
fi

function __goose_term_suggest_context_root() {
  local root
  root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || true
  if [[ -n "$root" ]]; then
    print -r -- "$root"
  else
    pwd -P
  fi
}

function __goose_term_suggest_context_key() {
  local root="$(__goose_term_suggest_context_root)"
  print -r -- "${root}::${PWD:A}"
}

function __goose_term_suggest_fetch() {
  [[ -x "$GOOSE_TERM_SUGGEST_BIN" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local root partial
  root="$(__goose_term_suggest_context_root)"
  partial="${1:-}"
  "$GOOSE_TERM_SUGGEST_BIN" \
    --pwd "$PWD" \
    --repo-root "$root" \
    --history-db "$GOOSE_TERM_SUGGEST_MCFLY_DB" \
    --model "$GOOSE_TERM_SUGGEST_MODEL" \
    --partial "$partial" 2>/dev/null
}

function __goose_term_suggest_queue() {
  local key suggestion
  key="$(__goose_term_suggest_context_key)"
  if [[ "$GOOSE_TERM_SUGGEST_NEEDS_REFRESH" != "1" && "$GOOSE_TERM_SUGGEST_LAST_KEY" == "$key" ]]; then
    return 0
  fi

  suggestion="$(__goose_term_suggest_fetch)"
  GOOSE_TERM_SUGGEST_PENDING="$suggestion"
  GOOSE_TERM_SUGGEST_LAST_KEY="$key"
  GOOSE_TERM_SUGGEST_NEEDS_REFRESH=0
}

function __goose_term_suggest_apply_pending() {
  if [[ -n "$GOOSE_TERM_SUGGEST_PENDING" && -z "$BUFFER" ]]; then
    BUFFER="$GOOSE_TERM_SUGGEST_PENDING"
    CURSOR=${#BUFFER}
    GOOSE_TERM_SUGGEST_PENDING=""
  fi
  zle redisplay
}

function __goose_term_suggest_mark_dirty() {
  GOOSE_TERM_SUGGEST_NEEDS_REFRESH=1
}

function __goose_term_suggest_manual_widget() {
  local suggestion
  suggestion="$(__goose_term_suggest_fetch "$BUFFER")"
  if [[ -n "$suggestion" ]]; then
    BUFFER="$suggestion"
    CURSOR=${#BUFFER}
    GOOSE_TERM_SUGGEST_PENDING=""
    GOOSE_TERM_SUGGEST_LAST_KEY="$(__goose_term_suggest_context_key)"
    GOOSE_TERM_SUGGEST_NEEDS_REFRESH=0
  fi
  zle redisplay
}

zle -N goose-term-suggest-refresh __goose_term_suggest_manual_widget
bindkey '^G' goose-term-suggest-refresh

add-zsh-hook precmd __goose_term_suggest_queue
add-zsh-hook chpwd __goose_term_suggest_mark_dirty

if (( $+functions[add-zle-hook-widget] )); then
  add-zle-hook-widget zle-line-init __goose_term_suggest_apply_pending
else
  function zle-line-init() {
    __goose_term_suggest_apply_pending
  }
  zle -N zle-line-init
fi
