#!/usr/bin/env bash
# Test 13: diff buffers have no LSPs attached during a review
# (prevents Marksman et al. from crashing when diffview closes the buffer)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-13"
trap "cleanup_session $SESSION" EXIT

# Make a repo where one of the changed files is markdown (the case that
# triggers Marksman to attach if any LSP server is configured for it).
repo=$(mktemp -d -t code-review-test.XXXXXX)
cd "$repo"
git init -q -b main
git config user.email t@x ; git config user.name t ; git config commit.gpgsign false
echo "# README" > README.md
echo "initial" > greeting.txt
git add . && git commit -q -m initial
echo "# README v2" > README.md
echo "modified" > greeting.txt
cd - >/dev/null
echo "Test repo: $repo"

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "README.md" 5
sleep 2

cat > /tmp/cr-no-lsp-check.lua <<'EOF'
local lib = require('diffview.lib')
local view = lib.get_current_view()
local a_buf = view.cur_layout.a.file.bufnr
local b_buf = view.cur_layout.b.file.bufnr
local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
local a_count = #get_clients({ bufnr = a_buf })
local b_count = #get_clients({ bufnr = b_buf })
vim.fn.writefile({
  'a_bufnr=' .. tostring(a_buf),
  'a_filetype=' .. tostring(vim.bo[a_buf].filetype),
  'a_lsp_count=' .. tostring(a_count),
  'b_bufnr=' .. tostring(b_buf),
  'b_filetype=' .. tostring(vim.bo[b_buf].filetype),
  'b_lsp_count=' .. tostring(b_count),
}, '/tmp/cr-no-lsp-check.txt')
EOF

mv /tmp/cr-no-lsp-check.txt /tmp/cr-no-lsp-check.txt.bak 2>/dev/null || true
send_cmd "$SESSION" "luafile /tmp/cr-no-lsp-check.lua"
sleep 1

if [ ! -s /tmp/cr-no-lsp-check.txt ]; then
  echo "FAIL: check file empty"
  capture_pane "$SESSION"
  exit 1
fi

echo "--- check ---"
cat /tmp/cr-no-lsp-check.txt
echo "--- end ---"

a_count=$(grep '^a_lsp_count=' /tmp/cr-no-lsp-check.txt | cut -d= -f2)
b_count=$(grep '^b_lsp_count=' /tmp/cr-no-lsp-check.txt | cut -d= -f2)

if [ "$a_count" = "0" ] && [ "$b_count" = "0" ]; then
  echo "PASS: no LSPs attached to diff buffers"
else
  echo "FAIL: a_count=$a_count b_count=$b_count (both should be 0)"
  exit 1
fi
