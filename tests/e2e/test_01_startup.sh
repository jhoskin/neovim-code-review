#!/usr/bin/env bash
# Test 01: :CodeReview opens diffview
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-01"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"

# Diffview should open showing the working tree changes
wait_for "$SESSION" "greeting.txt" 5
assert_session_alive "$SESSION"

echo "PASS: :CodeReview opened diffview"
