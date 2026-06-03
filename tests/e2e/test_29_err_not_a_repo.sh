#!/usr/bin/env bash
# Test 29: running :CodeReview outside a git repository exits with code 1.
# Covers: TST-ERR-0003
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-29"
trap "cleanup_session $SESSION" EXIT

# A plain directory that is NOT a git repository.
nonrepo=$(mktemp -d -t cr-nonrepo.XXXXXX)
echo "Non-repo dir: $nonrepo"

exit_file=$(mktemp -t nvim-exit.XXXXXX)
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$nonrepo" \
  "NVIM_CODE_REVIEW_RESULT=/tmp/cr-29-result nvim -u $PLUGIN_ROOT/tests/minimal_init.lua; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for_exit "$SESSION" 5 || true

exit_code=$(cat "$exit_file" 2>/dev/null || echo "none")
if [ "$exit_code" = "1" ]; then
  echo "PASS: :CodeReview outside a git repo exited with code 1"
else
  echo "FAIL: expected exit code 1 (not a repo), got $exit_code"
  exit 1
fi
