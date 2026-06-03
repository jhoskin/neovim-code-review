#!/usr/bin/env bash
# Test 10: file-level comment renders both a virtual line and a sign on line 1
# Covers: TST-UIX-0006
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-10"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

cat > /tmp/cr-file-sign-check.lua <<'EOF'
local cr = require('code-review')
cr._session.store:add_file_comment('greeting.txt', 'File-level comment test')

-- Repaint comment markers from the store (the renderer's incremental path).
require('code-review.render.init').repaint_comments()

-- greeting.txt is modified, so the file comment lands on the new-side buffer.
local bufnr
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(buf):find('code-review://new/', 1, true) then bufnr = buf end
end

local ns = vim.api.nvim_create_namespace('code_review_comments')
local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })

local lines = {}
table.insert(lines, 'bufnr=' .. tostring(bufnr))
table.insert(lines, 'mark_count=' .. tostring(#marks))
local has_virt_lines = false
local has_sign = false
for _, m in ipairs(marks) do
  local row = m[2]
  local details = m[4] or {}
  if row == 0 and details.virt_lines then
    has_virt_lines = true
  end
  if row == 0 and details.sign_text then
    has_sign = true
    table.insert(lines, 'sign_text=' .. tostring(details.sign_text))
    table.insert(lines, 'sign_hl=' .. tostring(details.sign_hl_group))
  end
end
table.insert(lines, 'has_virt_lines=' .. tostring(has_virt_lines))
table.insert(lines, 'has_sign=' .. tostring(has_sign))
vim.fn.writefile(lines, '/tmp/cr-file-sign-check.txt')
EOF

mv /tmp/cr-file-sign-check.txt /tmp/cr-file-sign-check.txt.bak 2>/dev/null || true
send_cmd "$SESSION" "luafile /tmp/cr-file-sign-check.lua"
sleep 1

if [ ! -s /tmp/cr-file-sign-check.txt ]; then
  echo "FAIL: check file empty"
  capture_pane "$SESSION"
  exit 1
fi

echo "--- check ---"
cat /tmp/cr-file-sign-check.txt
echo "--- end ---"

has_virt=$(grep '^has_virt_lines=' /tmp/cr-file-sign-check.txt | cut -d= -f2)
has_sign=$(grep '^has_sign=' /tmp/cr-file-sign-check.txt | cut -d= -f2)

if [ "$has_virt" = "true" ] && [ "$has_sign" = "true" ]; then
  echo "PASS: file comment renders both virt_lines and sign on line 1"
else
  echo "FAIL: missing one of virt_lines ($has_virt) or sign ($has_sign)"
  exit 1
fi
