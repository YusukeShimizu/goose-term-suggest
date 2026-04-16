#!/usr/bin/env zsh

if [[ -n "${GOOSE_TERM_SUGGEST_LOADED:-}" ]]; then
  return 0
fi
typeset -g GOOSE_TERM_SUGGEST_LOADED=1

autoload -Uz add-zsh-hook
autoload -Uz add-zle-hook-widget 2>/dev/null || true

typeset -g GOOSE_TERM_SUGGEST_HOME="${GOOSE_TERM_SUGGEST_HOME:-${${(%):-%N}:A:h:h}}"
typeset -g GOOSE_TERM_SUGGEST_MODEL="${GOOSE_TERM_SUGGEST_MODEL:-gpt-5.4-nano-low}"
typeset -g GOOSE_TERM_SUGGEST_SCROLLBACK_LINES="${GOOSE_TERM_SUGGEST_SCROLLBACK_LINES:-80}"
typeset -g GOOSE_TERM_SUGGEST_SCROLLBACK_MAX_CHARS="${GOOSE_TERM_SUGGEST_SCROLLBACK_MAX_CHARS:-4000}"
typeset -g GOOSE_TERM_SUGGEST_PENDING=""
typeset -g GOOSE_TERM_SUGGEST_PENDING_KEY=""
typeset -g GOOSE_TERM_SUGGEST_LAST_KEY=""
typeset -g GOOSE_TERM_SUGGEST_LAST_COMMAND=""
typeset -g GOOSE_TERM_SUGGEST_NEEDS_REFRESH=1
typeset -g GOOSE_TERM_SUGGEST_ACTIVE_FD=""
typeset -g GOOSE_TERM_SUGGEST_ACTIVE_GENERATION=0
typeset -g GOOSE_TERM_SUGGEST_REQUEST_GENERATION=0
typeset -g GOOSE_TERM_SUGGEST_DISPLAYED=""
typeset -g GOOSE_TERM_SUGGEST_HIGHLIGHT_STYLE="${GOOSE_TERM_SUGGEST_HIGHLIGHT_STYLE:-fg=8}"
typeset -ga GOOSE_TERM_SUGGEST_RECENT_COMMANDS=()

function __goose_term_suggest_clear_highlight() {
  region_highlight=("${(@)region_highlight:#*memo=goose-term-suggest}")
  return 0
}

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

function __goose_term_suggest_trim() {
  local raw="$1"
  raw="${raw%%$'\n'*}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  print -r -- "$raw"
}

function __goose_term_suggest_recent_commands_block() {
  local cmd

  if (( ${#GOOSE_TERM_SUGGEST_RECENT_COMMANDS[@]} == 0 )); then
    print -r -- "(none)"
    return 0
  fi

  for cmd in "${GOOSE_TERM_SUGGEST_RECENT_COMMANDS[@]}"; do
    print -r -- "- $cmd"
  done
}

function __goose_term_suggest_wezterm_bin() {
  if command -v wezterm >/dev/null 2>&1; then
    command -v wezterm
    return 0
  fi

  if [[ -x "/Applications/WezTerm.app/Contents/MacOS/wezterm" ]]; then
    print -r -- "/Applications/WezTerm.app/Contents/MacOS/wezterm"
    return 0
  fi

  return 1
}

function __goose_term_suggest_recent_output_block() {
  local lines max_chars wezterm_bin output

  lines="${GOOSE_TERM_SUGGEST_SCROLLBACK_LINES:-0}"
  max_chars="${GOOSE_TERM_SUGGEST_SCROLLBACK_MAX_CHARS:-0}"

  [[ "$lines" == <-> ]] || lines=0
  [[ "$max_chars" == <-> ]] || max_chars=0

  if (( lines <= 0 || max_chars <= 0 )); then
    print -r -- "(disabled)"
    return 0
  fi

  [[ -n "${WEZTERM_PANE:-}" ]] || {
    print -r -- "(unavailable)"
    return 0
  }

  wezterm_bin="$(__goose_term_suggest_wezterm_bin)" || {
    print -r -- "(unavailable)"
    return 0
  }

  output="$("$wezterm_bin" cli get-text --pane-id "$WEZTERM_PANE" --start-line "-$lines" --end-line 0 2>/dev/null)" || true
  output="${output//$'\r'/}"
  output="${output#"${output%%[![:space:]]*}"}"
  output="${output%"${output##*[![:space:]]}"}"

  if [[ -z "$output" ]]; then
    print -r -- "(empty)"
    return 0
  fi

  if (( ${#output} > max_chars )); then
    output="${output: -max_chars}"
  fi

  print -r -- "$output"
}

function __goose_term_suggest_build_prompt() {
  local repo_root="$1"
  local last_command recent_commands recent_output
  last_command="${GOOSE_TERM_SUGGEST_LAST_COMMAND:-"(none)"}"
  recent_commands="$(__goose_term_suggest_recent_commands_block)"
  recent_output="$(__goose_term_suggest_recent_output_block)"
  cat <<EOF
You are generating a zsh command suggestion.
Return exactly one shell command.
Output one line only.
Do not include markdown, quotes, bullets, or explanations.
Suggest the single most likely next shell command based on the current directory and the user's recent terminal activity.
Prefer concrete commands that continue the user's current task, not generic repository commands.
If the most recent command was a question to an AI assistant such as @g or @goose, infer the most likely follow-up shell command that would inspect or verify the answer.
If a recent command mentioned a path, config file, or tool, prefer commands that inspect that path or tool.

Current directory: ${PWD:A}
Repository root: ${repo_root:-"(none)"}
Most recent executed command: ${last_command}
Recent commands:
${recent_commands}
Recent terminal output from the current WezTerm pane:
${recent_output}
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

function __goose_term_suggest_fetch_payload() {
  local generation="$1"
  local key="$2"
  local suggestion

  suggestion="$(__goose_term_suggest_fetch)"

  print -r -- "$generation"
  print -r -- "$key"
  print -r -- "$suggestion"
}

function __goose_term_suggest_clear_active() {
  GOOSE_TERM_SUGGEST_ACTIVE_FD=""
  GOOSE_TERM_SUGGEST_ACTIVE_GENERATION=0
}

function __goose_term_suggest_close_fd() {
  local fd="$1"

  [[ -n "$fd" ]] || return 0
  zle -F "$fd" 2>/dev/null || true
  exec {fd}<&- 2>/dev/null || true

  if [[ "$GOOSE_TERM_SUGGEST_ACTIVE_FD" == "$fd" ]]; then
    __goose_term_suggest_clear_active
  fi
  return 0
}

function __goose_term_suggest_on_readable() {
  local fd="$1"
  local generation=""
  local key=""
  local suggestion=""

  if ! IFS= read -ru "$fd" generation; then
    __goose_term_suggest_close_fd "$fd"
    return 0
  fi

  IFS= read -ru "$fd" key || true
  IFS= read -ru "$fd" suggestion || true
  __goose_term_suggest_close_fd "$fd"

  if [[ "$generation" != "$GOOSE_TERM_SUGGEST_REQUEST_GENERATION" ]]; then
    return 0
  fi

  if [[ "$key" != "$(__goose_term_suggest_context_key)" ]]; then
    return 0
  fi

  GOOSE_TERM_SUGGEST_PENDING="$suggestion"
  GOOSE_TERM_SUGGEST_PENDING_KEY="$key"
  __goose_term_suggest_apply_pending
}

function __goose_term_suggest_on_readable_widget() {
  __goose_term_suggest_on_readable "$1"
}

function __goose_term_suggest_start_async() {
  local key="$1"
  local generation fd

  generation=$((GOOSE_TERM_SUGGEST_REQUEST_GENERATION + 1))
  GOOSE_TERM_SUGGEST_REQUEST_GENERATION="$generation"

  if [[ -n "$GOOSE_TERM_SUGGEST_ACTIVE_FD" ]]; then
    __goose_term_suggest_close_fd "$GOOSE_TERM_SUGGEST_ACTIVE_FD"
  fi

  exec {fd}< <(__goose_term_suggest_fetch_payload "$generation" "$key")
  GOOSE_TERM_SUGGEST_ACTIVE_FD="$fd"
  GOOSE_TERM_SUGGEST_ACTIVE_GENERATION="$generation"
  zle -F -w "$fd" __goose_term_suggest_on_readable_widget 2>/dev/null
}

function __goose_term_suggest_queue() {
  local key
  key="$(__goose_term_suggest_context_key)"
  if [[ "$GOOSE_TERM_SUGGEST_NEEDS_REFRESH" != "1" && "$GOOSE_TERM_SUGGEST_LAST_KEY" == "$key" ]]; then
    return 0
  fi

  GOOSE_TERM_SUGGEST_PENDING=""
  GOOSE_TERM_SUGGEST_PENDING_KEY=""
  GOOSE_TERM_SUGGEST_LAST_KEY="$key"
  GOOSE_TERM_SUGGEST_NEEDS_REFRESH=0
  __goose_term_suggest_start_async "$key"
}

function __goose_term_suggest_apply_pending() {
  if [[ -n "$GOOSE_TERM_SUGGEST_PENDING" && "$GOOSE_TERM_SUGGEST_PENDING_KEY" != "$(__goose_term_suggest_context_key)" ]]; then
    GOOSE_TERM_SUGGEST_PENDING=""
    GOOSE_TERM_SUGGEST_PENDING_KEY=""
  fi

  if [[ -n "$GOOSE_TERM_SUGGEST_PENDING" && -z "$BUFFER" ]]; then
    BUFFER="$GOOSE_TERM_SUGGEST_PENDING"
    CURSOR=${#BUFFER}
    GOOSE_TERM_SUGGEST_DISPLAYED="$BUFFER"
    GOOSE_TERM_SUGGEST_PENDING=""
    GOOSE_TERM_SUGGEST_PENDING_KEY=""
  fi
  __goose_term_suggest_refresh_highlight
  zle -R 2>/dev/null || true
  return 0
}

function __goose_term_suggest_refresh_highlight() {
  __goose_term_suggest_clear_highlight

  if [[ -z "$GOOSE_TERM_SUGGEST_DISPLAYED" ]]; then
    return 0
  fi

  if [[ "$BUFFER" != "$GOOSE_TERM_SUGGEST_DISPLAYED" ]]; then
    GOOSE_TERM_SUGGEST_DISPLAYED=""
    return 0
  fi

  [[ -n "$BUFFER" ]] || return 0
  region_highlight+=("0 ${#BUFFER} ${GOOSE_TERM_SUGGEST_HIGHLIGHT_STYLE} memo=goose-term-suggest")
  return 0
}

function __goose_term_suggest_line_pre_redraw() {
  __goose_term_suggest_refresh_highlight
}

function __goose_term_suggest_mark_dirty() {
  GOOSE_TERM_SUGGEST_PENDING=""
  GOOSE_TERM_SUGGEST_PENDING_KEY=""
  GOOSE_TERM_SUGGEST_DISPLAYED=""
  __goose_term_suggest_clear_highlight
  GOOSE_TERM_SUGGEST_NEEDS_REFRESH=1
}

function __goose_term_suggest_note_command() {
  local command="$(__goose_term_suggest_trim "$1")"
  local count

  [[ -n "$command" ]] || return 0

  GOOSE_TERM_SUGGEST_LAST_COMMAND="$command"
  GOOSE_TERM_SUGGEST_RECENT_COMMANDS+=("$command")
  count=${#GOOSE_TERM_SUGGEST_RECENT_COMMANDS[@]}
  if (( count > 5 )); then
    GOOSE_TERM_SUGGEST_RECENT_COMMANDS=("${(@)GOOSE_TERM_SUGGEST_RECENT_COMMANDS[count-4,count]}")
  fi

  __goose_term_suggest_mark_dirty
}

add-zsh-hook precmd __goose_term_suggest_queue
add-zsh-hook chpwd __goose_term_suggest_mark_dirty
if [[ -o interactive ]]; then
  add-zsh-hook preexec __goose_term_suggest_note_command
fi
zle -N __goose_term_suggest_on_readable_widget

if (( $+functions[add-zle-hook-widget] )) && add-zle-hook-widget zle-line-init __goose_term_suggest_apply_pending 2>/dev/null; then
  :
else
  function zle-line-init() {
    __goose_term_suggest_apply_pending
  }
  zle -N zle-line-init
fi

if (( $+functions[add-zle-hook-widget] )) && add-zle-hook-widget zle-line-pre-redraw __goose_term_suggest_line_pre_redraw 2>/dev/null; then
  :
else
  function zle-line-pre-redraw() {
    __goose_term_suggest_line_pre_redraw
  }
  zle -N zle-line-pre-redraw
fi
