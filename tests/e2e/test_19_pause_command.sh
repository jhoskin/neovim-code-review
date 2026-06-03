#!/usr/bin/env bash
# Test 19: :CodeReviewPause saves session JSON, closes the renderer, nvim alive,
# Covers: TST-CLI-0007, TST-SES-0001, TST-SES-0003
# notify mentions the session ID.
# Covers REQ-CLI-0007
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-19"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

sessions_root="$HOME/.local/share/nvim/code-review"
marker=$(mktemp -t cr-pause-marker.XXXXXX)
sleep 1

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "unset NVIM_CODE_REVIEW_RESULT; nvim -u $PLUGIN_ROOT/tests/minimal_init.lua"
sleep 1.5

send_cmd "$SESSION" "CodeReview HEAD~1..HEAD"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

# Add a comment programmatically
cat > /tmp/cr-pause-cmd-comment.lua <<'EOF'
local cr = require('code-review')
cr._session.store:add_line_comment('greeting.txt', nil, 5, 'new', 'Pause-command comment')
EOF
send_cmd "$SESSION" "luafile /tmp/cr-pause-cmd-comment.lua"
sleep 1

send_cmd "$SESSION" "CodeReviewPause"
sleep 2

if ! session_alive "$SESSION"; then
  echo "FAIL: pause exited nvim (should stay alive)"
  exit 1
fi
echo "Nvim alive after pause: PASS"

# Find newly written session JSON
session_file=$(find "$sessions_root" -path '*/sessions/*.json' -newer "$marker" 2>/dev/null | head -1)
if [ -z "$session_file" ] || [ ! -f "$session_file" ]; then
  echo "FAIL: no session JSON written under $sessions_root"
  find "$sessions_root" -type f 2>/dev/null || true
  exit 1
fi
echo "Session JSON written: $session_file"

# Verify contents: comment body, range_str, timestamps
body=$(jq -r '.store.files[0].lines[0].body' "$session_file")
if [ "$body" != "Pause-command comment" ]; then
  echo "FAIL: session missing comment body, got: $body"
  cat "$session_file"
  exit 1
fi
echo "Session contains comment: PASS"

# range_str should be the explicit range we passed
range_str=$(jq -r '.range_str' "$session_file")
if [ "$range_str" != "HEAD~1..HEAD" ]; then
  echo "FAIL: range_str expected HEAD~1..HEAD, got: $range_str"
  exit 1
fi
echo "Session preserves range_str: PASS"

created=$(jq -r '.created_at' "$session_file")
updated=$(jq -r '.updated_at' "$session_file")
if [ -z "$created" ] || [ "$created" = "null" ]; then
  echo "FAIL: created_at missing"; exit 1
fi
if [ -z "$updated" ] || [ "$updated" = "null" ]; then
  echo "FAIL: updated_at missing"; exit 1
fi
echo "Timestamps present (created=$created updated=$updated): PASS"

# diff_info embedded
diff_type=$(jq -r '.diff_info.type' "$session_file")
if [ -z "$diff_type" ] || [ "$diff_type" = "null" ]; then
  echo "FAIL: diff_info.type missing"
  cat "$session_file"
  exit 1
fi
echo "Session contains diff_info: PASS"

# Verify the renderer is closed: no code-review:// diff buffers remain and the
# renderer reports no open windows.
cat > /tmp/cr-pause-render-check.lua <<'EOF'
local diff_bufs = 0
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_valid(buf) then
    local nm = vim.api.nvim_buf_get_name(buf)
    if nm:find('code-review://', 1, true) then diff_bufs = diff_bufs + 1 end
  end
end
local wins = #require('code-review.render.init').review_windows()
vim.fn.writefile({
  'diff_bufs=' .. tostring(diff_bufs),
  'review_wins=' .. tostring(wins),
}, '/tmp/cr-pause-render-check.txt')
EOF
rm -f /tmp/cr-pause-render-check.txt
send_cmd "$SESSION" "luafile /tmp/cr-pause-render-check.lua"
sleep 1

if [ ! -s /tmp/cr-pause-render-check.txt ]; then
  echo "FAIL: renderer check file empty"
  exit 1
fi
echo "--- renderer state ---"
cat /tmp/cr-pause-render-check.txt
echo "--- end ---"
diff_bufs=$(grep '^diff_bufs=' /tmp/cr-pause-render-check.txt | cut -d= -f2)
review_wins=$(grep '^review_wins=' /tmp/cr-pause-render-check.txt | cut -d= -f2)
if [ "$diff_bufs" != "0" ] || [ "$review_wins" != "0" ]; then
  echo "FAIL: expected renderer closed after pause, got diff_bufs=$diff_bufs review_wins=$review_wins"
  exit 1
fi
echo "Renderer closed: PASS"

# Verify :messages contains the session id (notify output)
session_id=$(jq -r '.session_id' "$session_file")
cat > /tmp/cr-pause-messages.lua <<'EOF'
local out = vim.api.nvim_exec2(':messages', { output = true }).output
vim.fn.writefile(vim.split(out, '\n', { plain = true }), '/tmp/cr-pause-messages.txt')
EOF
rm -f /tmp/cr-pause-messages.txt
send_cmd "$SESSION" "luafile /tmp/cr-pause-messages.lua"
sleep 1

if [ ! -s /tmp/cr-pause-messages.txt ]; then
  echo "FAIL: messages dump empty"
  exit 1
fi
if ! grep -q "$session_id" /tmp/cr-pause-messages.txt; then
  echo "FAIL: :messages does not mention session id $session_id"
  echo "--- messages ---"
  cat /tmp/cr-pause-messages.txt
  echo "--- end ---"
  exit 1
fi
echo "Notify mentions session id: PASS"

echo "PASS: :CodeReviewPause persists session, closes the renderer, leaves nvim running, notifies"
