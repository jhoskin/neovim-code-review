#!/usr/bin/env bash
# Test 03: :CodeReviewCancel (interactive) should NOT exit nvim
# Covers: TST-CLI-0006
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-03"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

# Start without NVIM_CODE_REVIEW_RESULT — interactive mode
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "unset NVIM_CODE_REVIEW_RESULT; nvim -u $PLUGIN_ROOT/tests/minimal_init.lua"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5

send_cmd "$SESSION" "CodeReviewCancel"
sleep 1

# Interactive cancel: nvim should still be alive
if session_alive "$SESSION"; then
  echo "PASS: :CodeReviewCancel did not exit nvim (interactive)"
else
  echo "FAIL: :CodeReviewCancel exited nvim (should stay open in interactive mode)"
  exit 1
fi
