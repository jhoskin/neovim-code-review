#!/usr/bin/env bash
# Test 41: launching the review at startup (nvim -c 'CodeReview', the agent
# launch path) lands the cursor in the new-side diff buffer of the first file,
# not the file panel. This exercises the VimEnter-deferred open, where a focus
# change made mid-startup would otherwise be reset to the panel.
# Covers: TST-RND-0012
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-41"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

# Fire the review from the command line exactly like the launcher does, so the
# open runs through the VimEnter-deferred path.
start_nvim "$SESSION" "$repo" -c 'CodeReview'
wait_for "$SESSION" "greeting.txt" 8
sleep 1

BUF_FILE=/tmp/cr-test-41-buf.txt
rm -f "$BUF_FILE"
send_cmd "$SESSION" "lua vim.fn.writefile({vim.api.nvim_buf_get_name(0)}, '$BUF_FILE')"
sleep 0.8

if [ ! -s "$BUF_FILE" ]; then
  echo "FAIL: could not read the current buffer name"
  capture_pane "$SESSION"
  exit 1
fi

name=$(head -n1 "$BUF_FILE")
echo "current buffer on load: $name"
if printf '%s' "$name" | grep -qF 'code-review://new/'; then
  echo "PASS: review opens with the cursor in the new-side diff buffer"
else
  echo "FAIL: cursor landed in '$name' (expected a code-review://new/ buffer)"
  exit 1
fi
