#!/usr/bin/env bash
# Test 40: after confirming a comment in the float, the editor returns to
# normal mode. The confirm key is bound in insert mode (the user is typing the
# comment), so closing the float must drop insert mode rather than leak it onto
# the diff/panel buffer underneath.
# Covers: TST-CMT-0011
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-40"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 1

MODE_FILE=/tmp/cr-test-40-mode.txt
rm -f "$MODE_FILE"

# Open a file-level comment float (which starts in insert mode), type a note,
# and confirm with the default confirm key (<C-s>). The float then closes.
send_cmd "$SESSION" "lua require('code-review').add_file_comment()"
sleep 0.6
tmux send-keys -t "$SESSION" "a note"
sleep 0.3
tmux send-keys -t "$SESSION" C-s
sleep 0.8

# Probe the mode WITHOUT first sending Escape -- an Escape would mask a leaked
# insert mode. In normal mode the ':' opens the cmdline and the file is written;
# if insert mode leaked, the ':lua...' is typed into the non-modifiable buffer
# and nothing is written.
tmux send-keys -t "$SESSION" ":lua vim.fn.writefile({vim.api.nvim_get_mode().mode}, '$MODE_FILE')" Enter
sleep 0.8

if [ ! -s "$MODE_FILE" ]; then
  echo "FAIL: mode probe wrote nothing -- editor was left in insert mode after confirm"
  capture_pane "$SESSION"
  exit 1
fi

mode=$(head -n1 "$MODE_FILE")
echo "mode after confirm: $mode"
if [ "$mode" = "n" ]; then
  echo "PASS: editor returns to normal mode after confirming a comment"
else
  echo "FAIL: expected normal mode 'n', got '$mode'"
  exit 1
fi
