#!/usr/bin/env bash
# Test 18: :CodeReviewCancel as a command (not via keymap)
# Covers: TST-CLI-0006
# - Interactive: nvim stays alive, no audit trail written for this attempt
# - Agent mode: nvim exits with code 2
# Covers REQ-CLI-0006. Sister tests test_03 and test_04 also touch cancel.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION_I="cr-test-18-int"
SESSION_A="cr-test-18-agent"
trap "cleanup_session $SESSION_I; cleanup_session $SESSION_A" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

audit_dir="$HOME/.local/share/nvim/code-review"
marker=$(mktemp -t cr-cancel-marker.XXXXXX)
sleep 1  # ensure mtime gap so "newer than marker" is meaningful

############################
# Interactive mode
############################
tmux kill-session -t "$SESSION_I" 2>/dev/null || true
tmux new-session -d -s "$SESSION_I" -x 200 -y 50 -c "$repo" \
  "unset NVIM_CODE_REVIEW_RESULT; nvim -u $PLUGIN_ROOT/tests/minimal_init.lua"
sleep 1.5

send_cmd "$SESSION_I" "CodeReview"
wait_for "$SESSION_I" "greeting.txt" 5
sleep 2
send_cmd "$SESSION_I" "CodeReviewCancel"
sleep 1

if ! session_alive "$SESSION_I"; then
  echo "FAIL: interactive :CodeReviewCancel killed nvim"
  exit 1
fi
echo "Interactive cancel keeps nvim alive: PASS"

new_audit=$(find "$audit_dir" -maxdepth 3 -name '*.json' -not -path '*/sessions/*' -newer "$marker" 2>/dev/null | wc -l | tr -d ' ')
if [ "$new_audit" != "0" ]; then
  echo "FAIL: interactive cancel wrote an audit trail file ($new_audit new files)"
  find "$audit_dir" -name '*.json' -not -path '*/sessions/*' -newer "$marker" 2>/dev/null
  exit 1
fi
echo "Interactive cancel writes no audit trail: PASS"

cleanup_session "$SESSION_I"

############################
# Agent mode
############################
result_file=$(mktemp -t nvim-code-review-result.XXXXXX)
rm -f "$result_file"
exit_file=$(mktemp -t nvim-exit.XXXXXX)

tmux kill-session -t "$SESSION_A" 2>/dev/null || true
tmux new-session -d -s "$SESSION_A" -x 200 -y 50 -c "$repo" \
  "NVIM_CODE_REVIEW_RESULT=$result_file nvim -u $PLUGIN_ROOT/tests/minimal_init.lua; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION_A" "CodeReview"
wait_for "$SESSION_A" "greeting.txt" 5
sleep 2
send_cmd "$SESSION_A" "CodeReviewCancel"
wait_for_exit "$SESSION_A" 5 || true

exit_code=$(cat "$exit_file")
if [ "$exit_code" != "2" ]; then
  echo "FAIL: agent-mode cancel expected exit 2, got $exit_code"
  exit 1
fi
echo "Agent cancel exits with code 2: PASS"

echo "PASS: :CodeReviewCancel command behaves correctly in both modes"
