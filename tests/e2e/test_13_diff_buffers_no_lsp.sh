#!/usr/bin/env bash
# Test 13: diff buffers have no LSPs attached during a review
# Covers: TST-LSP-0001
# The renderer's diff buffers are buftype=nofile, so no language server
# attaches (no FileType event on a nofile scratch buffer). This is the
# structural prevention that replaced diffview's post-hoc LSP stripping.
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
-- Drive to the markdown file (the case that would attract Marksman) so the
-- diff buffers actually hold README.md content while we check for clients.
pcall(function() require('code-review.render.init').switch_file('README.md') end)
local function diff_bufs()
  local a, b
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local nm = vim.api.nvim_buf_get_name(buf)
    if nm:find('code-review://old/', 1, true) then a = buf end
    if nm:find('code-review://new/', 1, true) then b = buf end
  end
  return a, b
end
local a_buf, b_buf = diff_bufs()
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
