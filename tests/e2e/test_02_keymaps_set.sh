#!/usr/bin/env bash
# Test 02: comment keymaps are registered on both renderer diff buffers
# Covers: TST-UIX-0008
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-02"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

cat > /tmp/cr-keymap-check.lua <<'EOF'
-- Find the renderer's two diff buffers by their synthetic names (REQ-RND-0005).
local function diff_bufs()
  local a, b
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local nm = vim.api.nvim_buf_get_name(buf)
    if nm:find('code-review://old/', 1, true) then a = buf end
    if nm:find('code-review://new/', 1, true) then b = buf end
  end
  return a, b
end

local lines = {}
local a_buf, b_buf = diff_bufs()
local sides = { a = a_buf, b = b_buf }
for _, side_name in ipairs({ 'a', 'b' }) do
  local bufnr = sides[side_name]
  table.insert(lines, side_name .. '_bufnr=' .. tostring(bufnr))
  if bufnr then
    local maps = vim.api.nvim_buf_get_keymap(bufnr, 'n')
    table.insert(lines, side_name .. '_keymap_count=' .. tostring(#maps))
    local has_rc, has_rs, has_rd = false, false, false
    for _, m in ipairs(maps) do
      if m.lhs == ' Rc' then has_rc = true end
      if m.lhs == ' Rs' then has_rs = true end
      if m.lhs == ' Rd' then has_rd = true end
    end
    table.insert(lines, side_name .. '_has_rc=' .. tostring(has_rc))
    table.insert(lines, side_name .. '_has_rs=' .. tostring(has_rs))
    table.insert(lines, side_name .. '_has_rd=' .. tostring(has_rd))
  end
end
vim.fn.writefile(lines, '/tmp/cr-keymap-check.txt')
EOF

mv /tmp/cr-keymap-check.txt /tmp/cr-keymap-check.txt.bak 2>/dev/null || true

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 3  # allow autocmd to fire and layout to fully initialize

send_cmd "$SESSION" "luafile /tmp/cr-keymap-check.lua"
sleep 2

if [ ! -s /tmp/cr-keymap-check.txt ]; then
  echo "FAIL: keymap check file not written or empty"
  capture_pane "$SESSION"
  exit 1
fi

echo "--- check results ---"
cat /tmp/cr-keymap-check.txt
echo "--- end ---"

a_has_rc=$(grep '^a_has_rc=' /tmp/cr-keymap-check.txt | cut -d= -f2 || echo "missing")
b_has_rc=$(grep '^b_has_rc=' /tmp/cr-keymap-check.txt | cut -d= -f2 || echo "missing")

if [ "$a_has_rc" = "true" ] && [ "$b_has_rc" = "true" ]; then
  echo "PASS: <leader>Rc keymap set on both old (a) and new (b) diff buffers"
elif [ "$b_has_rc" = "true" ]; then
  echo "PARTIAL: <leader>Rc on new side only"
  exit 1
else
  echo "FAIL: <leader>Rc not set"
  exit 1
fi
