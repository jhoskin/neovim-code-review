#!/usr/bin/env bash
# Test 04: :CodeReviewCancel (agent mode) should exit nvim with code 2
# Covers: TST-CLI-0006
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-04"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

result_file=$(mktemp -t nvim-code-review-result.XXXXXX)
rm -f "$result_file"

# Use a wrapper script so we can capture nvim's exit code
exit_file=$(mktemp -t nvim-exit.XXXXXX)
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "NVIM_CODE_REVIEW_RESULT=$result_file nvim -u $PLUGIN_ROOT/tests/minimal_init.lua; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5

send_cmd "$SESSION" "CodeReviewCancel"
wait_for_exit "$SESSION" 5 || true

exit_code=$(cat "$exit_file")
if [ "$exit_code" = "2" ]; then
  echo "PASS: :CodeReviewCancel exited with code 2 (agent mode)"
else
  echo "FAIL: expected exit code 2, got $exit_code"
  exit 1
fi
