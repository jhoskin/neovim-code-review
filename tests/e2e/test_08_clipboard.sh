#!/usr/bin/env bash
# Test 08: CodeReviewCopy populates clipboard with markdown
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Skip if no clipboard available
if ! command -v pbpaste >/dev/null 2>&1; then
  echo "SKIP: pbpaste not available (not macOS?)"
  exit 0
fi

SESSION="cr-test-08"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

# Clear clipboard first
echo "" | pbcopy

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "unset NVIM_CODE_REVIEW_RESULT; nvim -u $PLUGIN_ROOT/tests/minimal_init.lua"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

# Add a comment via Lua
cat > /tmp/cr-copy-comment.lua <<'EOF'
local cr = require('code-review')
cr._session.store:add_line_comment('greeting.txt', nil, 5, 'new', 'Clipboard test comment')
cr._session.store:set_verdict('Looks good')
EOF
send_cmd "$SESSION" "luafile /tmp/cr-copy-comment.lua"
sleep 1

send_cmd "$SESSION" "CodeReviewCopy"
sleep 1

clipboard=$(pbpaste)
if echo "$clipboard" | grep -q "Clipboard test comment"; then
  echo "Comment in clipboard: PASS"
else
  echo "FAIL: comment not in clipboard"
  echo "--- clipboard ---"
  echo "$clipboard"
  echo "--- end ---"
  exit 1
fi

if echo "$clipboard" | grep -q "Looks good"; then
  echo "Verdict in clipboard: PASS"
else
  echo "FAIL: verdict not in clipboard"
  exit 1
fi

if echo "$clipboard" | grep -q "^# Code Review:"; then
  echo "Markdown heading present: PASS"
else
  echo "FAIL: missing markdown heading"
  exit 1
fi

echo "PASS: CodeReviewCopy populates clipboard with markdown"
