#!/usr/bin/env bash
# Test 34: launching the review without an interactive UI (headless) exits with
# code 1. git, repo, and version preconditions are satisfied, so only the
# no-UI check can fail. (< /dev/null keeps headless nvim from blocking on stdin.)
# Covers: TST-ERR-0008
set -euo pipefail
source "$(dirname "$0")/lib.sh"

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

err_file=$(mktemp -t nvim-err.XXXXXX)
set +e
( cd "$repo" && NVIM_CODE_REVIEW_RESULT=/tmp/cr-34-result \
  nvim --headless -u "$PLUGIN_ROOT/tests/minimal_init.lua" -c 'CodeReview' < /dev/null 2> "$err_file" )
exit_code=$?
set -e

if [ "$exit_code" != "1" ]; then
  echo "FAIL: expected exit code 1 when headless (no UI), got $exit_code"
  cat "$err_file" 2>/dev/null || true
  exit 1
fi
echo "Exit code 1: PASS"

if ! grep -qi "headless\|interactive\|no_ui" "$err_file" 2>/dev/null; then
  echo "FAIL: stderr does not diagnose the missing interactive UI"
  echo "--- stderr ---"; cat "$err_file" 2>/dev/null || true
  exit 1
fi
echo "PASS: headless launch exits 1 with a no-UI diagnostic"
