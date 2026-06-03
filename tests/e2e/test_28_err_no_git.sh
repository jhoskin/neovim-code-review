#!/usr/bin/env bash
# Test 28: with git absent from PATH, :CodeReview exits with code 1.
# Covers: TST-ERR-0002
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-28"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

# A PATH with no git (but nvim is launched by absolute path so it still runs).
empty_path=$(mktemp -d -t cr-nopath.XXXXXX)
nvim_bin=$(command -v nvim)
exit_file=$(mktemp -t nvim-exit.XXXXXX)

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "PATH=$empty_path NVIM_CODE_REVIEW_RESULT=/tmp/cr-28-result $nvim_bin -u $PLUGIN_ROOT/tests/minimal_init.lua; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for_exit "$SESSION" 5 || true

exit_code=$(cat "$exit_file" 2>/dev/null || echo "none")
if [ "$exit_code" = "1" ]; then
  echo "PASS: :CodeReview with no git on PATH exited with code 1"
else
  echo "FAIL: expected exit code 1 (no git), got $exit_code"
  exit 1
fi
