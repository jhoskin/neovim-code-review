#!/usr/bin/env bash
# Test 10: a file-level comment shows its 📄 indicator in the file panel (next
# to the file) and keeps its text as a virtual-line block at the top of the
# new-side diff buffer -- and no longer paints a sign on the diff buffer itself.
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

-- Repaint comment markers + the panel from the store (the incremental path).
require('code-review.render.init').repaint_comments()

-- greeting.txt is modified, so the file comment text lands on the new-side buffer.
local newbuf, panelbuf
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(buf):find('code-review://new/', 1, true) then newbuf = buf end
  if vim.bo[buf].filetype == 'codereview-panel' then panelbuf = buf end
end

local lines = {}
table.insert(lines, 'newbuf=' .. tostring(newbuf))
table.insert(lines, 'panelbuf=' .. tostring(panelbuf))

-- New-side diff buffer: virt_lines text present, NO sign (the indicator moved
-- to the panel).
local cns = vim.api.nvim_create_namespace('code_review_comments')
local cmarks = vim.api.nvim_buf_get_extmarks(newbuf, cns, 0, -1, { details = true })
local has_virt_lines = false
local buf_has_file_sign = false
for _, m in ipairs(cmarks) do
  local row, details = m[2], m[4] or {}
  if row == 0 and details.virt_lines then has_virt_lines = true end
  if row == 0 and details.sign_text then buf_has_file_sign = true end
end
table.insert(lines, 'has_virt_lines=' .. tostring(has_virt_lines))
table.insert(lines, 'buf_has_file_sign=' .. tostring(buf_has_file_sign))

-- Panel buffer: a 📄 sign in the panel namespace next to greeting.txt.
local pns = vim.api.nvim_create_namespace('code_review_panel')
local pmarks = vim.api.nvim_buf_get_extmarks(panelbuf, pns, 0, -1, { details = true })
local panel_has_sign = false
for _, m in ipairs(pmarks) do
  local details = m[4] or {}
  if details.sign_text and details.sign_text ~= '' then
    panel_has_sign = true
    table.insert(lines, 'panel_sign_text=' .. tostring(details.sign_text))
    table.insert(lines, 'panel_sign_hl=' .. tostring(details.sign_hl_group))
  end
end
table.insert(lines, 'panel_has_sign=' .. tostring(panel_has_sign))

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
buf_sign=$(grep '^buf_has_file_sign=' /tmp/cr-file-sign-check.txt | cut -d= -f2)
panel_sign=$(grep '^panel_has_sign=' /tmp/cr-file-sign-check.txt | cut -d= -f2)

if [ "$has_virt" = "true" ] && [ "$panel_sign" = "true" ] && [ "$buf_sign" = "false" ]; then
  echo "PASS: file comment shows 📄 in the panel and keeps its text on the diff buffer (no buffer sign)"
else
  echo "FAIL: virt_lines=$has_virt panel_sign=$panel_sign buf_sign=$buf_sign (want true/true/false)"
  exit 1
fi
