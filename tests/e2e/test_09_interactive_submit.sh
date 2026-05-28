#!/usr/bin/env bash
# Test 09: Interactive submit (no NVIM_CODE_REVIEW_RESULT) → clipboard, no exit
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if ! command -v pbpaste >/dev/null 2>&1; then
  echo "SKIP: pbpaste not available (not macOS?)"
  exit 0
fi

SESSION="cr-test-09"
save_clipboard
trap "cleanup_session $SESSION; restore_clipboard" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

# Clear clipboard
echo "STALE-CLIPBOARD" | pbcopy

# Interactive mode: NVIM_CODE_REVIEW_RESULT explicitly unset
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "unset NVIM_CODE_REVIEW_RESULT; nvim -u $PLUGIN_ROOT/tests/minimal_init.lua"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

# Add a comment via Lua
cat > /tmp/cr-interactive-comment.lua <<'EOF'
local cr = require('code-review')
cr._session.store:add_line_comment('greeting.txt', nil, 5, 'new', 'Interactive submit test')
EOF
send_cmd "$SESSION" "luafile /tmp/cr-interactive-comment.lua"
sleep 1

# Submit
send_cmd "$SESSION" "CodeReviewSubmit"
sleep 1
send_keys "$SESSION" Enter  # confirm summary
sleep 2

# Verify nvim is still running (interactive mode shouldn't exit)
if ! session_alive "$SESSION"; then
  echo "FAIL: nvim exited in interactive mode (should stay open)"
  exit 1
fi
echo "Nvim still running: PASS"

# Verify clipboard has markdown export
clipboard=$(pbpaste)
if ! echo "$clipboard" | grep -q "Interactive submit test"; then
  echo "FAIL: clipboard does not contain comment"
  echo "--- clipboard ---"
  echo "$clipboard"
  echo "--- end ---"
  exit 1
fi
echo "Clipboard contains comment: PASS"

# Verify audit trail file exists
audit_dir="$HOME/.local/share/nvim/code-review"
recent_review=$(find "$audit_dir" -maxdepth 2 -name '*.json' -not -path '*/sessions/*' -newer /tmp/cr-interactive-comment.lua 2>/dev/null | head -1)
if [ -z "$recent_review" ]; then
  echo "FAIL: no audit trail file written"
  exit 1
fi
echo "Audit trail file written: $recent_review"

body=$(jq -r '.files[0].lines[0].body' "$recent_review")
if [ "$body" != "Interactive submit test" ]; then
  echo "FAIL: audit trail body mismatch: $body"
  exit 1
fi

echo "PASS: interactive submit copies to clipboard, leaves nvim running"
