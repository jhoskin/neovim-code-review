#!/usr/bin/env bash
# Test 12: comment input float uses filetype "codereview" (not "markdown")
# Covers: TST-CMT-0010, TST-LSP-0002
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

# Check both the comment float AND the summary float
cat > /tmp/cr-float-check.lua <<'EOF'
local ui = require('code-review.ui')
local Store = require('code-review.store')

-- 1. Comment float
ui.open_comment_float({
  prefill = "test",
  on_confirm = function() end,
  on_cancel = function() end,
})
local comment_buf = vim.api.nvim_get_current_buf()
local comment_ft = vim.bo[comment_buf].filetype
-- Close it
vim.api.nvim_win_close(0, true)

-- 2. Summary float
local store = Store.new()
store:add_line_comment('foo.txt', nil, 1, 'new', 'sample')
ui.open_summary_float(store, function() end, function() end)
local summary_buf = vim.api.nvim_get_current_buf()
local summary_ft = vim.bo[summary_buf].filetype
vim.api.nvim_win_close(0, true)

vim.fn.writefile({
  'comment_ft=' .. tostring(comment_ft),
  'summary_ft=' .. tostring(summary_ft),
}, '/tmp/cr-float-check.txt')
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

comment_ft=$(grep '^comment_ft=' /tmp/cr-float-check.txt | cut -d= -f2)
summary_ft=$(grep '^summary_ft=' /tmp/cr-float-check.txt | cut -d= -f2)

ok=true
if [ "$comment_ft" != "codereview" ]; then
  echo "FAIL: comment float filetype is '$comment_ft', expected 'codereview'"
  ok=false
fi
if [ "$summary_ft" != "codereview" ]; then
  echo "FAIL: summary float filetype is '$summary_ft', expected 'codereview'"
  ok=false
fi

if [ "$ok" = "true" ]; then
  echo "PASS: both floats use 'codereview' filetype (LSP-safe)"
else
  exit 1
fi
