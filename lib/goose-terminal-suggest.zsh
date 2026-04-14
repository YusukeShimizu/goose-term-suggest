#!/usr/bin/env zsh

if [[ -n "${GOOSE_TERM_SUGGEST_LOADED:-}" ]]; then
  return 0
fi
typeset -g GOOSE_TERM_SUGGEST_LOADED=1

autoload -Uz add-zsh-hook
autoload -Uz add-zle-hook-widget 2>/dev/null || true

typeset -g GOOSE_TERM_SUGGEST_HOME="${GOOSE_TERM_SUGGEST_HOME:-${${(%):-%N}:A:h:h}}"
typeset -g GOOSE_TERM_SUGGEST_MODEL="${GOOSE_TERM_SUGGEST_MODEL:-gpt-5.4-nano-low}"
typeset -g GOOSE_TERM_SUGGEST_PENDING=""
typeset -g GOOSE_TERM_SUGGEST_LAST_KEY=""
typeset -g GOOSE_TERM_SUGGEST_NEEDS_REFRESH=1

function __goose_term_suggest_repo_root() {
  local root
  root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || true
  if [[ -n "$root" ]]; then
    print -r -- "$root"
  fi
}

function __goose_term_suggest_context_key() {
  local repo_root
  repo_root="$(__goose_term_suggest_repo_root)"
  print -r -- "${repo_root:-"(none)"}::${PWD:A}"
}

function __goose_term_suggest_build_prompt() {
  local repo_root="$1"
  cat <<EOF
You are generating a zsh command suggestion.
Return exactly one shell command.
Output one line only.
Do not include markdown, quotes, bullets, or explanations.
Suggest the single most likely next command for this directory.

Current directory: ${PWD:A}
Repository root: ${repo_root:-"(none)"}
EOF
}

function __goose_term_suggest_sanitize() {
  local raw="$1"
  local line_count

  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [[ -n "$raw" ]] || return 0

  line_count=$(print -r -- "$raw" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  [[ "$line_count" == "1" ]] || return 0

  print -r -- "$raw"
}

function __goose_term_suggest_fetch() {
  command -v goose >/dev/null 2>&1 || return 0
  [[ -n "${AGENT_SESSION_ID:-}" ]] || return 0

  local repo_root prompt suggestion
  repo_root="$(__goose_term_suggest_repo_root)"
  prompt="$(__goose_term_suggest_build_prompt "$repo_root")"
  suggestion="$(GOOSE_MODEL="$GOOSE_TERM_SUGGEST_MODEL" goose term run "$prompt" 2>/dev/null)" || return 0
  __goose_term_suggest_sanitize "$suggestion"
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
  [[ -n "${WIDGET:-}" ]] && zle redisplay
  return 0
}

function __goose_term_suggest_mark_dirty() {
  GOOSE_TERM_SUGGEST_NEEDS_REFRESH=1
}

add-zsh-hook precmd __goose_term_suggest_queue
add-zsh-hook chpwd __goose_term_suggest_mark_dirty

if (( $+functions[add-zle-hook-widget] )) && add-zle-hook-widget zle-line-init __goose_term_suggest_apply_pending 2>/dev/null; then
  :
else
  function zle-line-init() {
    __goose_term_suggest_apply_pending
  }
  zle -N zle-line-init
fi
