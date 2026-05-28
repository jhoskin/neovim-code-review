#!/usr/bin/env bash
# Test 20: summary float preview contains the expected lines:
# Covers: TST-UIX-0009
# header, mode note, preamble "# Code Review Comments", comment text.
# Covers REQ-UIX-0009
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-20"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

# Agent mode — exercises the agent-mode note string
result_file=$(mktemp -t nvim-code-review-result.XXXXXX)
rm -f "$result_file"

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "NVIM_CODE_REVIEW_RESULT=$result_file nvim -u $PLUGIN_ROOT/tests/minimal_init.lua"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

# Add a comment so the preview has user content
cat > /tmp/cr-summary-comment.lua <<'EOF'
local cr = require('code-review')
cr._session.store:add_line_comment('greeting.txt', nil, 5, 'new', 'SUMMARY-PREVIEW-MARKER')
EOF
send_cmd "$SESSION" "luafile /tmp/cr-summary-comment.lua"
sleep 1

# Trigger submit — opens summary float but does NOT confirm
send_cmd "$SESSION" "CodeReviewSubmit"
sleep 2

# Capture buffer lines of whatever buffer is current (the float)
cat > /tmp/cr-summary-capture.lua <<'EOF'
local buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
vim.fn.writefile(lines, '/tmp/cr-summary-capture.txt')
EOF
rm -f /tmp/cr-summary-capture.txt
send_cmd "$SESSION" "luafile /tmp/cr-summary-capture.lua"
sleep 1

if [ ! -s /tmp/cr-summary-capture.txt ]; then
  echo "FAIL: summary capture empty"
  capture_pane "$SESSION"
  exit 1
fi

echo "--- summary float lines ---"
cat /tmp/cr-summary-capture.txt
echo "--- end ---"

assert_contains() {
  local needle="$1" label="$2"
  if ! grep -qF "$needle" /tmp/cr-summary-capture.txt; then
    echo "FAIL: summary preview missing $label: $needle"
    exit 1
  fi
  echo "Found $label: PASS"
}

assert_contains "Submit review?" "header"
assert_contains "write to the result file and exit" "agent-mode note"
assert_contains "# Code Review Comments" "markdown preamble"
assert_contains "SUMMARY-PREVIEW-MARKER" "user comment text"

# Cancel the summary so nvim exits cleanly via cancel (no submit)
send_keys "$SESSION" q
sleep 1

echo "PASS: summary float preview contains header, mode note, preamble, and comment"
