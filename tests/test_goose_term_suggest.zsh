#!/usr/bin/env zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
LIB_PATH="$ROOT_DIR/lib/goose-terminal-suggest.zsh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

function assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" != "$actual" ]]; then
    print -u2 -- "FAIL: $message"
    print -u2 -- "expected: $expected"
    print -u2 -- "actual:   $actual"
    exit 1
  fi
}

function assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Fq "$pattern" "$file"; then
    print -u2 -- "FAIL: $message"
    exit 1
  fi
}

function assert_contains() {
  local value="$1"
  local pattern="$2"
  local message="$3"
  if [[ "$value" != *"$pattern"* ]]; then
    print -u2 -- "FAIL: $message"
    print -u2 -- "missing pattern: $pattern"
    exit 1
  fi
}

function reset_state() {
  BUFFER=""
  CURSOR=0
  WIDGET=""
  GOOSE_TERM_SUGGEST_PENDING=""
  GOOSE_TERM_SUGGEST_PENDING_KEY=""
  GOOSE_TERM_SUGGEST_LAST_KEY=""
  GOOSE_TERM_SUGGEST_LAST_COMMAND=""
  GOOSE_TERM_SUGGEST_NEEDS_REFRESH=1
  GOOSE_TERM_SUGGEST_ACTIVE_FD=""
  GOOSE_TERM_SUGGEST_ACTIVE_GENERATION=0
  GOOSE_TERM_SUGGEST_REQUEST_GENERATION=0
  GOOSE_TERM_SUGGEST_RECENT_COMMANDS=()
  GOOSE_LOG="$TMP_DIR/goose.log"
  : > "$GOOSE_LOG"
  export GOOSE_LOG
}

function drain_active_request() {
  local tries=0

  while [[ -n "${GOOSE_TERM_SUGGEST_ACTIVE_FD:-}" && "$tries" -lt 50 ]]; do
    sleep 0.02
    __goose_term_suggest_on_readable "$GOOSE_TERM_SUGGEST_ACTIVE_FD"
    tries=$((tries + 1))
  done
}

function goose() {
  print -r -- "goose $1 $2" >> "$GOOSE_LOG"
  if [[ "$1" == "term" && "$2" == "run" ]]; then
    print -r -- "model=${GOOSE_MODEL:-}" >> "$GOOSE_LOG"
    print -r -- "${GOOSE_RESPONSE:-}"
    return 0
  fi
  return 1
}

function zle() {
  return 0
}

source "$LIB_PATH"

reset_state
unset AGENT_SESSION_ID || true
GOOSE_RESPONSE="git status"
__goose_term_suggest_queue
drain_active_request
assert_eq "" "$GOOSE_TERM_SUGGEST_PENDING" "no session should skip fetch"
assert_eq "0" "$(wc -l < "$GOOSE_LOG" | tr -d ' ')" "no session should not call goose"

reset_state
export AGENT_SESSION_ID="session"
__goose_term_suggest_note_command '@g codexの設定ファイルはどこ？'
assert_eq '@g codexの設定ファイルはどこ？' "$GOOSE_TERM_SUGGEST_LAST_COMMAND" "last command should be recorded"
assert_eq "1" "${#GOOSE_TERM_SUGGEST_RECENT_COMMANDS[@]}" "recent commands should keep the latest command"
PROMPT_TEXT="$(__goose_term_suggest_build_prompt "$(__goose_term_suggest_repo_root)")"
assert_contains "$PROMPT_TEXT" 'Most recent executed command: @g codexの設定ファイルはどこ？' "prompt should include the last command"
assert_contains "$PROMPT_TEXT" 'If the most recent command was a question to an AI assistant such as @g or @goose' "prompt should instruct follow-up behavior for AI queries"

reset_state
export AGENT_SESSION_ID="session"
GOOSE_RESPONSE="git status"
__goose_term_suggest_queue
drain_active_request
assert_eq "git status" "$BUFFER" "first prompt should auto-apply suggestion when buffer stays empty"
assert_eq "" "$GOOSE_TERM_SUGGEST_PENDING" "auto-applied suggestion should not remain pending"
assert_eq "2" "$(wc -l < "$GOOSE_LOG" | tr -d ' ')" "first prompt should log one goose call and one model line"
assert_file_contains "$GOOSE_LOG" "model=gpt-5.4-nano-low" "suggestion should force gpt-5.4-nano-low"

BUFFER="echo keep"
CURSOR=${#BUFFER}
GOOSE_TERM_SUGGEST_PENDING="git diff"
GOOSE_TERM_SUGGEST_PENDING_KEY="$(__goose_term_suggest_context_key)"
__goose_term_suggest_apply_pending
assert_eq "echo keep" "$BUFFER" "non-empty buffer should not be overwritten"
assert_eq "git diff" "$GOOSE_TERM_SUGGEST_PENDING" "pending should remain when buffer is non-empty"

GOOSE_RESPONSE="git diff"
__goose_term_suggest_queue
assert_eq "2" "$(wc -l < "$GOOSE_LOG" | tr -d ' ')" "same prompt without cd should not refetch"

__goose_term_suggest_note_command "ls"
GOOSE_RESPONSE="git diff --stat"
BUFFER=""
CURSOR=0
__goose_term_suggest_queue
drain_active_request
assert_eq "4" "$(wc -l < "$GOOSE_LOG" | tr -d ' ')" "executed command should trigger one more fetch"
assert_eq "git diff --stat" "$BUFFER" "post-command prompt should receive a fresh suggestion"

reset_state
export AGENT_SESSION_ID="session"
BUFFER="echo keep"
CURSOR=${#BUFFER}
GOOSE_RESPONSE="git diff"
__goose_term_suggest_queue
drain_active_request
assert_eq "echo keep" "$BUFFER" "async completion should not overwrite typed input"
assert_eq "git diff" "$GOOSE_TERM_SUGGEST_PENDING" "async completion should stay pending when input already exists"
assert_eq "$(__goose_term_suggest_context_key)" "$GOOSE_TERM_SUGGEST_PENDING_KEY" "pending suggestion should be tagged to the current context"

OLD_PWD="$PWD"
cd "$TMP_DIR"
__goose_term_suggest_mark_dirty
GOOSE_RESPONSE="ls"
__goose_term_suggest_queue
drain_active_request
assert_eq "4" "$(wc -l < "$GOOSE_LOG" | tr -d ' ')" "cd should trigger one more fetch"
assert_eq "echo keep" "$BUFFER" "cd refresh should not overwrite existing input"
assert_eq "ls" "$GOOSE_TERM_SUGGEST_PENDING" "cd should refresh pending suggestion"
cd "$OLD_PWD"

reset_state
export AGENT_SESSION_ID="session"
GOOSE_RESPONSE=$'git status\npwd'
__goose_term_suggest_queue
drain_active_request
assert_eq "" "$GOOSE_TERM_SUGGEST_PENDING" "multiline output should be rejected"

print -- "ok"
