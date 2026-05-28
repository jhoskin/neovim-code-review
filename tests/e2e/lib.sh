#!/usr/bin/env bash
# Shared helpers for tmux-driven e2e tests.

set -euo pipefail

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MIN_INIT="$PLUGIN_ROOT/tests/minimal_init.lua"

# Start nvim in a tmux session in the given repo.
# Usage: start_nvim <session_name> <repo_path> [extra_nvim_args...]
start_nvim() {
  local session="$1"
  local repo="$2"
  shift 2

  # Kill any leftover session
  tmux kill-session -t "$session" 2>/dev/null || true

  # Result file (some tests inspect it)
  local result_file
  result_file=$(mktemp -t nvim-code-review-result.XXXXXX)
  rm -f "$result_file"  # Ensure clean start

  # Start tmux session with nvim
  tmux new-session -d -s "$session" -x 200 -y 50 -c "$repo" \
    "NVIM_CODE_REVIEW_RESULT=$result_file nvim -u $MIN_INIT $*"

  # Save the result file path for later inspection
  echo "$result_file" > "/tmp/${session}.result_file"

  # Wait for nvim to be ready
  sleep 1.5
}

# Send keys to the tmux session.
# Usage: send_keys <session> <keys...>
send_keys() {
  local session="$1"
  shift
  tmux send-keys -t "$session" "$@"
  sleep 0.3
}

# Send a Vim command (in normal mode).
send_cmd() {
  local session="$1"
  local cmd="$2"
  tmux send-keys -t "$session" Escape
  sleep 0.1
  tmux send-keys -t "$session" ":${cmd}" Enter
  sleep 0.5
}

# Capture the current pane content.
capture_pane() {
  local session="$1"
  tmux capture-pane -t "$session" -p
}

# Wait until a pattern appears in the pane, or timeout.
# Usage: wait_for <session> <pattern> [timeout_seconds]
wait_for() {
  local session="$1"
  local pattern="$2"
  local timeout="${3:-10}"
  local start
  start=$(date +%s)

  while true; do
    if capture_pane "$session" | grep -qF "$pattern"; then
      return 0
    fi
    local now
    now=$(date +%s)
    if (( now - start >= timeout )); then
      echo "TIMEOUT waiting for: $pattern"
      echo "--- pane content ---"
      capture_pane "$session"
      echo "--- end ---"
      return 1
    fi
    sleep 0.2
  done
}

# Check if a tmux session still exists (i.e., nvim hasn't exited).
session_alive() {
  local session="$1"
  tmux has-session -t "$session" 2>/dev/null
}

# Wait for nvim to exit (session ends).
wait_for_exit() {
  local session="$1"
  local timeout="${2:-10}"
  local start
  start=$(date +%s)

  while session_alive "$session"; do
    local now
    now=$(date +%s)
    if (( now - start >= timeout )); then
      echo "TIMEOUT waiting for nvim to exit"
      capture_pane "$session"
      return 1
    fi
    sleep 0.2
  done
  return 0
}

# Get the result file path for the session.
result_file_for() {
  local session="$1"
  cat "/tmp/${session}.result_file"
}

# Cleanup helpers.
cleanup_session() {
  local session="$1"
  tmux kill-session -t "$session" 2>/dev/null || true
  rm -f "/tmp/${session}.result_file"
}

# Assertion helpers.
assert_pane_contains() {
  local session="$1"
  local pattern="$2"
  if ! capture_pane "$session" | grep -qF "$pattern"; then
    echo "FAIL: pane does not contain: $pattern"
    echo "--- pane content ---"
    capture_pane "$session"
    echo "--- end ---"
    return 1
  fi
}

assert_session_alive() {
  local session="$1"
  if ! session_alive "$session"; then
    echo "FAIL: session $session is not alive (nvim exited)"
    return 1
  fi
}

assert_session_dead() {
  local session="$1"
  if session_alive "$session"; then
    echo "FAIL: session $session is still alive (nvim did not exit)"
    capture_pane "$session"
    return 1
  fi
}

assert_file_exists() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "FAIL: file does not exist: $path"
    return 1
  fi
}

assert_json_valid() {
  local path="$1"
  if ! jq empty "$path" >/dev/null 2>&1; then
    echo "FAIL: file is not valid JSON: $path"
    return 1
  fi
}

# Save and restore the system clipboard around a test so it doesn't pollute
# the user's clipboard. Call save_clipboard at test start and restore_clipboard
# in a trap or at end.
CLIPBOARD_BACKUP_FILE=""
save_clipboard() {
  if command -v pbpaste >/dev/null 2>&1; then
    CLIPBOARD_BACKUP_FILE=$(mktemp -t cr-clip-backup.XXXXXX)
    pbpaste > "$CLIPBOARD_BACKUP_FILE" 2>/dev/null || true
  fi
}

restore_clipboard() {
  if [ -n "$CLIPBOARD_BACKUP_FILE" ] && [ -f "$CLIPBOARD_BACKUP_FILE" ]; then
    cat "$CLIPBOARD_BACKUP_FILE" | pbcopy 2>/dev/null || true
    mv "$CLIPBOARD_BACKUP_FILE" "$CLIPBOARD_BACKUP_FILE.consumed" 2>/dev/null || true
    CLIPBOARD_BACKUP_FILE=""
  fi
}
