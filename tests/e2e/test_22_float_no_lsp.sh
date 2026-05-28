#!/usr/bin/env bash
# Test 22: comment-input float has no LSP clients attached.
# Covers: TST-LSP-0003
# test_12 already checks the float's filetype is "codereview"; this test
# additionally asserts vim.lsp.get_clients({bufnr=floatbuf}) is empty.
# Covers REQ-LSP-0003
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-22"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

cat > /tmp/cr-float-lsp.lua <<'EOF'
local ui = require('code-review.ui')

-- 1. Comment float
ui.open_comment_float({ prefill = '', on_confirm = function() end, on_cancel = function() end })
local cbuf = vim.api.nvim_get_current_buf()
local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
local c_count = #get_clients({ bufnr = cbuf })
local c_ft = vim.bo[cbuf].filetype
vim.api.nvim_win_close(0, true)

-- 2. Summary float
local Store = require('code-review.store')
local store = Store.new()
store:add_line_comment('foo.txt', nil, 1, 'new', 'sample')
ui.open_summary_float(store, function() end, function() end)
local sbuf = vim.api.nvim_get_current_buf()
local s_count = #get_clients({ bufnr = sbuf })
local s_ft = vim.bo[sbuf].filetype
vim.api.nvim_win_close(0, true)

vim.fn.writefile({
  'comment_bufnr=' .. tostring(cbuf),
  'comment_ft=' .. tostring(c_ft),
  'comment_lsp_count=' .. tostring(c_count),
  'summary_bufnr=' .. tostring(sbuf),
  'summary_ft=' .. tostring(s_ft),
  'summary_lsp_count=' .. tostring(s_count),
}, '/tmp/cr-float-lsp.txt')
EOF

mv /tmp/cr-float-lsp.txt /tmp/cr-float-lsp.txt.bak 2>/dev/null || true
send_cmd "$SESSION" "luafile /tmp/cr-float-lsp.lua"
sleep 1

if [ ! -s /tmp/cr-float-lsp.txt ]; then
  echo "FAIL: float LSP check file empty"
  capture_pane "$SESSION"
  exit 1
fi

echo "--- check ---"
cat /tmp/cr-float-lsp.txt
echo "--- end ---"

c_count=$(grep '^comment_lsp_count=' /tmp/cr-float-lsp.txt | cut -d= -f2)
s_count=$(grep '^summary_lsp_count=' /tmp/cr-float-lsp.txt | cut -d= -f2)

ok=true
if [ "$c_count" != "0" ]; then
  echo "FAIL: comment float has $c_count LSP clients (expected 0)"
  ok=false
fi
if [ "$s_count" != "0" ]; then
  echo "FAIL: summary float has $s_count LSP clients (expected 0)"
  ok=false
fi

if [ "$ok" != "true" ]; then
  exit 1
fi

echo "PASS: both floats have no LSP clients attached"
