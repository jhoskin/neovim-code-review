#!/usr/bin/env bash
# Test 26: quitting Neovim without submitting cancels the review (exit code 2,
# no review file written). Covers the QuitPre/VimLeavePre cancel path, distinct
# from the explicit :CodeReviewCancel command (test_04).
# Covers: TST-UIX-0007
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-26"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

result_file=$(mktemp -t nvim-code-review-result.XXXXXX)
mv "$result_file" "$result_file.unused" 2>/dev/null || true  # ensure it does not exist

exit_file=$(mktemp -t nvim-exit.XXXXXX)
audit_root="$HOME/.local/share/nvim/code-review"
marker=$(mktemp -t cr-quit-marker.XXXXXX)
sleep 1

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "NVIM_CODE_REVIEW_RESULT=$result_file nvim -u $PLUGIN_ROOT/tests/minimal_init.lua; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 1

# Quit Neovim entirely without submitting.
send_cmd "$SESSION" "qall"
wait_for_exit "$SESSION" 5 || true

exit_code=$(cat "$exit_file")
if [ "$exit_code" != "2" ]; then
  echo "FAIL: expected exit code 2 on quit-without-submit, got $exit_code"
  exit 1
fi
echo "Exit code 2 on quit: PASS"

# No review JSON should have been written (cancel, not submit).
new_review=$(find "$audit_root" -name '*.json' -newer "$marker" -not -path '*/sessions/*' 2>/dev/null | head -1)
if [ -n "$new_review" ]; then
  echo "FAIL: a review file was written on cancel: $new_review"
  exit 1
fi
echo "No review file written: PASS"

# The result file must be empty/unwritten (only submit writes it).
if [ -s "$result_file" ]; then
  echo "FAIL: result file was written on cancel: $(cat "$result_file")"
  exit 1
fi
echo "Result file unwritten: PASS"

echo "PASS: quitting without submitting cancels with exit code 2 and writes nothing"
