#!/usr/bin/env bash
# Test 12: comment input float uses filetype "codereview" (not "markdown")
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-12"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

# Open a comment float programmatically and inspect its buffer
cat > /tmp/cr-float-check.lua <<'EOF'
local ui = require('code-review.ui')
ui.open_comment_float({
  prefill = "test",
  on_confirm = function() end,
  on_cancel = function() end,
})
-- After open, the current buffer is the comment float
local buf = vim.api.nvim_get_current_buf()
local lines = {
  'bufnr=' .. tostring(buf),
  'filetype=' .. tostring(vim.bo[buf].filetype),
  'buftype=' .. tostring(vim.bo[buf].buftype),
}
vim.fn.writefile(lines, '/tmp/cr-float-check.txt')
EOF

mv /tmp/cr-float-check.txt /tmp/cr-float-check.txt.bak 2>/dev/null || true
send_cmd "$SESSION" "luafile /tmp/cr-float-check.lua"
sleep 1

if [ ! -s /tmp/cr-float-check.txt ]; then
  echo "FAIL: check file empty"
  capture_pane "$SESSION"
  exit 1
fi

echo "--- check ---"
cat /tmp/cr-float-check.txt
echo "--- end ---"

filetype=$(grep '^filetype=' /tmp/cr-float-check.txt | cut -d= -f2)

if [ "$filetype" = "codereview" ]; then
  echo "PASS: comment float filetype is 'codereview' (LSP-safe)"
else
  echo "FAIL: expected filetype 'codereview', got '$filetype'"
  exit 1
fi
