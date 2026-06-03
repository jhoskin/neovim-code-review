#!/usr/bin/env bash
# Test 30: :CodeReview with an unresolvable revision exits with code 1 and the
# stderr diagnostic names the revision.
# Covers: TST-ERR-0007
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-30"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

exit_file=$(mktemp -t nvim-exit.XXXXXX)
err_file=$(mktemp -t nvim-err.XXXXXX)
bad_rev="no-such-branch-zzz"

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "NVIM_CODE_REVIEW_RESULT=/tmp/cr-30-result nvim -u $PLUGIN_ROOT/tests/minimal_init.lua 2> $err_file; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION" "CodeReview ${bad_rev}..HEAD"
wait_for_exit "$SESSION" 5 || true

exit_code=$(cat "$exit_file" 2>/dev/null || echo "none")
if [ "$exit_code" != "1" ]; then
  echo "FAIL: expected exit code 1 (bad revision), got $exit_code"
  cat "$err_file" 2>/dev/null || true
  exit 1
fi
echo "Exit code 1: PASS"

if ! grep -q "$bad_rev" "$err_file" 2>/dev/null; then
  echo "FAIL: stderr diagnostic does not name the unresolvable revision '$bad_rev'"
  echo "--- stderr ---"; cat "$err_file" 2>/dev/null || true
  exit 1
fi
echo "PASS: unresolvable revision exits 1 and names the revision on stderr"
