#!/usr/bin/env bash
# Test 07: pause saves session, then it appears in CodeReviewSessions list
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-07"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

# Interactive mode (no NVIM_CODE_REVIEW_RESULT)
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "unset NVIM_CODE_REVIEW_RESULT; nvim -u $PLUGIN_ROOT/tests/minimal_init.lua"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

# Add a comment programmatically
cat > /tmp/cr-pause-comment.lua <<'EOF'
local cr = require('code-review')
cr._session.store:add_line_comment('greeting.txt', nil, 5, 'new', 'Pausable comment')
EOF
send_cmd "$SESSION" "luafile /tmp/cr-pause-comment.lua"
sleep 1

# Pause
send_cmd "$SESSION" "CodeReviewPause"
sleep 1

# Verify session file exists in the audit trail
sessions_dir="$HOME/.local/share/nvim/code-review"
session_count=$(find "$sessions_dir" -path '*/sessions/*.json' -newer /tmp/cr-keymap-check.lua 2>/dev/null | wc -l | tr -d ' ')
if [ "$session_count" -lt 1 ]; then
  echo "FAIL: no session file written to $sessions_dir"
  find "$sessions_dir" -type f 2>/dev/null || true
  exit 1
fi
echo "Session file written: PASS ($session_count sessions on disk)"

# Verify the session JSON contains the comment
session_file=$(find "$sessions_dir" -path '*/sessions/*.json' -newer /tmp/cr-keymap-check.lua 2>/dev/null | head -1)
body=$(jq -r '.store.files[0].lines[0].body' "$session_file")
if [ "$body" != "Pausable comment" ]; then
  echo "FAIL: session JSON missing comment, got: $body"
  cat "$session_file"
  exit 1
fi

echo "PASS: pause writes session with comments intact"
