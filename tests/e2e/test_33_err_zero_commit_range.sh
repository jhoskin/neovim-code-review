#!/usr/bin/env bash
# Test 33: a non-working-tree range that resolves to zero commits exits with
# code 1 and a stderr diagnostic.
# Covers: TST-ERR-0001
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-33"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

exit_file=$(mktemp -t nvim-exit.XXXXXX)
err_file=$(mktemp -t nvim-err.XXXXXX)

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "NVIM_CODE_REVIEW_RESULT=/tmp/cr-33-result nvim -u $PLUGIN_ROOT/tests/minimal_init.lua 2> $err_file; echo \$? > $exit_file"
sleep 1.5

# HEAD..HEAD spans zero commits.
send_cmd "$SESSION" "CodeReview HEAD..HEAD"
wait_for_exit "$SESSION" 5 || true

exit_code=$(cat "$exit_file" 2>/dev/null || echo "none")
if [ "$exit_code" != "1" ]; then
  echo "FAIL: expected exit code 1 for a zero-commit range, got $exit_code"
  cat "$err_file" 2>/dev/null || true
  exit 1
fi
echo "Exit code 1: PASS"

if ! grep -qi "zero commits\|empty_range" "$err_file" 2>/dev/null; then
  echo "FAIL: stderr does not diagnose the zero-commit range"
  echo "--- stderr ---"; cat "$err_file" 2>/dev/null || true
  exit 1
fi
echo "PASS: zero-commit range exits 1 with a diagnostic"
