#!/usr/bin/env zsh

if [[ -n "${GOOSE_TERM_SUGGEST_LOADED:-}" ]]; then
  return 0
fi
typeset -g GOOSE_TERM_SUGGEST_LOADED=1

autoload -Uz add-zsh-hook
autoload -Uz add-zle-hook-widget 2>/dev/null || true

typeset -g GOOSE_TERM_SUGGEST_HOME="${GOOSE_TERM_SUGGEST_HOME:-${${(%):-%N}:A:h:h}}"
typeset -g GOOSE_TERM_SUGGEST_BIN="${GOOSE_TERM_SUGGEST_BIN:-$GOOSE_TERM_SUGGEST_HOME/bin/goose-term-suggest}"
typeset -g GOOSE_TERM_SUGGEST_MODEL="${GOOSE_TERM_SUGGEST_MODEL:-gpt-5.4-nano-medium}"
typeset -g GOOSE_TERM_SUGGEST_MCFLY_DB="${GOOSE_TERM_SUGGEST_MCFLY_DB:-$HOME/Library/Application Support/McFly/history.db}"
typeset -g GOOSE_TERM_SUGGEST_PENDING=""
typeset -g GOOSE_TERM_SUGGEST_LAST_KEY=""
typeset -g GOOSE_TERM_SUGGEST_NEEDS_REFRESH=1
typeset -g GOOSE_TERM_SUGGEST_LAST_COMMAND=""
typeset -g GOOSE_TERM_SUGGEST_LAST_STATUS=0

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

function __goose_term_suggest_track_preexec() {
  GOOSE_TERM_SUGGEST_LAST_COMMAND="$1"
}

function __goose_term_suggest_fetch() {
  [[ -x "$GOOSE_TERM_SUGGEST_BIN" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local root partial last_command last_status
  root="$(__goose_term_suggest_context_root)"
  partial="${1:-}"
  last_command="${2:-$GOOSE_TERM_SUGGEST_LAST_COMMAND}"
  last_status="${3:-$GOOSE_TERM_SUGGEST_LAST_STATUS}"
  "$GOOSE_TERM_SUGGEST_BIN" \
    --pwd "$PWD" \
    --repo-root "$root" \
    --history-db "$GOOSE_TERM_SUGGEST_MCFLY_DB" \
    --model "$GOOSE_TERM_SUGGEST_MODEL" \
    --partial "$partial" \
    --last-command "$last_command" \
    --last-status "$last_status" 2>/dev/null
}

function __goose_term_suggest_queue() {
  local last_status=$?
  local key suggestion
  GOOSE_TERM_SUGGEST_LAST_STATUS=$last_status
  key="$(__goose_term_suggest_context_key)"
  if [[ "$GOOSE_TERM_SUGGEST_NEEDS_REFRESH" != "1" && "$GOOSE_TERM_SUGGEST_LAST_KEY" == "$key" ]]; then
    return 0
  fi

  suggestion="$(__goose_term_suggest_fetch "" "$GOOSE_TERM_SUGGEST_LAST_COMMAND" "$last_status")"
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
  [[ -n "${WIDGET:-}" ]] && zle redisplay
}

function __goose_term_suggest_mark_dirty() {
  GOOSE_TERM_SUGGEST_NEEDS_REFRESH=1
}

function __goose_term_suggest_manual_widget() {
  local suggestion
  suggestion="$(__goose_term_suggest_fetch "$BUFFER" "$GOOSE_TERM_SUGGEST_LAST_COMMAND" "$GOOSE_TERM_SUGGEST_LAST_STATUS")"
  if [[ -n "$suggestion" ]]; then
    BUFFER="$suggestion"
    CURSOR=${#BUFFER}
    GOOSE_TERM_SUGGEST_PENDING=""
    GOOSE_TERM_SUGGEST_LAST_KEY="$(__goose_term_suggest_context_key)"
    GOOSE_TERM_SUGGEST_NEEDS_REFRESH=0
  fi
  [[ -n "${WIDGET:-}" ]] && zle redisplay
}

function __goose_term_suggest_command_known() {
  local cmd="$1"
  [[ -z "$cmd" ]] && return 1
  (( $+commands[$cmd] )) && return 0
  (( $+functions[$cmd] )) && return 0
  (( $+aliases[$cmd] )) && return 0
  (( $+builtins[$cmd] )) && return 0
  (( $+reswords[$cmd] )) && return 0
  return 1
}

function __goose_term_suggest_try_complete_unknown() {
  local -a words
  local first suggestion

  [[ -z "$BUFFER" ]] && return 1
  [[ "$BUFFER" == *['|&;<>`$(){}[]']* ]] && return 1

  words=(${(z)BUFFER})
  (( ${#words[@]} == 0 )) && return 1

  first="${words[1]}"
  __goose_term_suggest_command_known "$first" && return 1

  suggestion="$(__goose_term_suggest_fetch "$BUFFER" "$GOOSE_TERM_SUGGEST_LAST_COMMAND" "$GOOSE_TERM_SUGGEST_LAST_STATUS")"
  [[ -z "$suggestion" || "$suggestion" == "$BUFFER" ]] && return 1

  BUFFER="$suggestion"
  CURSOR=${#BUFFER}
  GOOSE_TERM_SUGGEST_PENDING=""
  GOOSE_TERM_SUGGEST_LAST_KEY="$(__goose_term_suggest_context_key)"
  GOOSE_TERM_SUGGEST_NEEDS_REFRESH=0
  [[ -n "${WIDGET:-}" ]] && zle redisplay
  return 0
}

function __goose_term_suggest_accept_line() {
  __goose_term_suggest_try_complete_unknown && return 0
  zle .accept-line
}

zle -N goose-term-suggest-refresh __goose_term_suggest_manual_widget
zle -N accept-line __goose_term_suggest_accept_line
bindkey '^G' goose-term-suggest-refresh

add-zsh-hook preexec __goose_term_suggest_track_preexec
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
