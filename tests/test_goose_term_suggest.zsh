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

function reset_state() {
  BUFFER=""
  CURSOR=0
  WIDGET=""
  GOOSE_TERM_SUGGEST_PENDING=""
  GOOSE_TERM_SUGGEST_LAST_KEY=""
  GOOSE_TERM_SUGGEST_NEEDS_REFRESH=1
  GOOSE_LOG="$TMP_DIR/goose.log"
  : > "$GOOSE_LOG"
  export GOOSE_LOG
}

function goose() {
  print -r -- "goose $1 $2" >> "$GOOSE_LOG"
  if [[ "$1" == "term" && "$2" == "run" ]]; then
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
assert_eq "" "$GOOSE_TERM_SUGGEST_PENDING" "no session should skip fetch"
assert_eq "0" "$(wc -l < "$GOOSE_LOG" | tr -d ' ')" "no session should not call goose"

reset_state
export AGENT_SESSION_ID="session"
GOOSE_RESPONSE="git status"
__goose_term_suggest_queue
assert_eq "git status" "$GOOSE_TERM_SUGGEST_PENDING" "first prompt should fetch one suggestion"
assert_eq "1" "$(wc -l < "$GOOSE_LOG" | tr -d ' ')" "first prompt should call goose once"

BUFFER=""
CURSOR=0
__goose_term_suggest_apply_pending
assert_eq "git status" "$BUFFER" "empty buffer should receive suggestion"
assert_eq "${#BUFFER}" "$CURSOR" "cursor should move to end of inserted suggestion"
assert_eq "" "$GOOSE_TERM_SUGGEST_PENDING" "pending suggestion should be cleared after apply"

BUFFER="echo keep"
CURSOR=${#BUFFER}
GOOSE_TERM_SUGGEST_PENDING="git diff"
__goose_term_suggest_apply_pending
assert_eq "echo keep" "$BUFFER" "non-empty buffer should not be overwritten"
assert_eq "git diff" "$GOOSE_TERM_SUGGEST_PENDING" "pending should remain when buffer is non-empty"

GOOSE_RESPONSE="git diff"
__goose_term_suggest_queue
assert_eq "1" "$(wc -l < "$GOOSE_LOG" | tr -d ' ')" "same prompt without cd should not refetch"

OLD_PWD="$PWD"
cd "$TMP_DIR"
__goose_term_suggest_mark_dirty
GOOSE_RESPONSE="ls"
__goose_term_suggest_queue
assert_eq "2" "$(wc -l < "$GOOSE_LOG" | tr -d ' ')" "cd should trigger one more fetch"
assert_eq "ls" "$GOOSE_TERM_SUGGEST_PENDING" "cd should refresh pending suggestion"
cd "$OLD_PWD"

reset_state
export AGENT_SESSION_ID="session"
GOOSE_RESPONSE=$'git status\npwd'
__goose_term_suggest_queue
assert_eq "" "$GOOSE_TERM_SUGGEST_PENDING" "multiline output should be rejected"

INSTALL_HOME="$TMP_DIR/home"
mkdir -p "$INSTALL_HOME"
ZDOTDIR="$INSTALL_HOME" "$ROOT_DIR/install.sh" >/dev/null
assert_file_contains "$INSTALL_HOME/.zshrc" 'source "$GOOSE_TERM_SUGGEST_HOME/lib/goose-terminal-suggest.zsh"' "install should source zsh hook"

if grep -Fq 'goose term init zsh' "$INSTALL_HOME/.zshrc"; then
  print -u2 -- "FAIL: install should not manage goose term init"
  exit 1
fi

if grep -Fq 'alias @g=' "$INSTALL_HOME/.zshrc"; then
  print -u2 -- "FAIL: install should not define @g"
  exit 1
fi

print -- "ok"
