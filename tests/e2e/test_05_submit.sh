#!/usr/bin/env bash
# Test 05: submit creates JSON file and exits with code 0
# Covers: TST-STO-0001, TST-STO-0003, TST-STO-0004, TST-STO-0006, TST-CLI-0002, TST-CLI-0004
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-05"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

result_file=$(mktemp -t nvim-code-review-result.XXXXXX)
rm -f "$result_file"
exit_file=$(mktemp -t nvim-exit.XXXXXX)

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "NVIM_CODE_REVIEW_RESULT=$result_file nvim -u $PLUGIN_ROOT/tests/minimal_init.lua; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5

# Submit immediately (empty review is allowed)
send_cmd "$SESSION" "CodeReviewSubmit"
sleep 1
# Confirm summary
send_keys "$SESSION" Enter
wait_for_exit "$SESSION" 5

exit_code=$(cat "$exit_file")
if [ "$exit_code" != "0" ]; then
  echo "FAIL: expected exit code 0, got $exit_code"
  exit 1
fi
echo "Exit code 0: PASS"

if [ ! -s "$result_file" ]; then
  echo "FAIL: result file is empty or missing"
  exit 1
fi
echo "Result file populated: PASS"

review_path=$(cat "$result_file")
if [ ! -f "$review_path" ]; then
  echo "FAIL: review file does not exist: $review_path"
  exit 1
fi
echo "Review file exists: PASS"

if ! jq empty "$review_path" >/dev/null 2>&1; then
  echo "FAIL: review file is not valid JSON"
  cat "$review_path"
  exit 1
fi
echo "Valid JSON: PASS"

# Check empty review structure
files=$(jq -r '.files | length' "$review_path")
if [ "$files" != "0" ]; then
  echo "FAIL: expected 0 files, got $files"
  exit 1
fi
# Verdict field should not exist in v1 schema
has_verdict=$(jq 'has("verdict")' "$review_path")
if [ "$has_verdict" = "true" ]; then
  echo "FAIL: verdict field should not be in review JSON"
  exit 1
fi
echo "Empty review structure correct: PASS"

echo "PASS: submit creates JSON file with exit code 0"
