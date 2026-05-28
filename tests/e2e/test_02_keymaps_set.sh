#!/usr/bin/env bash
# Test 02: keymaps are registered on diff buffers after DiffviewDiffBufRead fires
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-02"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

cat > /tmp/cr-keymap-check.lua <<'EOF'
local ok, lib = pcall(require, 'diffview.lib')
local lines = { 'lib_ok=' .. tostring(ok) }
if ok then
  local v = lib.get_current_view()
  table.insert(lines, 'view=' .. tostring(v))
  if v and v.cur_layout then
    table.insert(lines, 'cur_layout=' .. tostring(v.cur_layout))
    local check = function(side_name, side_obj)
      if not side_obj then
        table.insert(lines, side_name .. '_obj=nil')
        return
      end
      local bufnr = nil
      if side_obj.file and side_obj.file.bufnr then
        bufnr = side_obj.file.bufnr
      elseif side_obj.id then
        local pok, b = pcall(vim.api.nvim_win_get_buf, side_obj.id)
        if pok then bufnr = b end
      end
      table.insert(lines, side_name .. '_bufnr=' .. tostring(bufnr))
      if bufnr then
        local maps = vim.api.nvim_buf_get_keymap(bufnr, 'n')
        table.insert(lines, side_name .. '_keymap_count=' .. tostring(#maps))
        local has_cc, has_cs, has_cd = false, false, false
        for _, m in ipairs(maps) do
          if m.lhs == ' cc' then has_cc = true end
          if m.lhs == ' cs' then has_cs = true end
          if m.lhs == ' cd' then has_cd = true end
        end
        table.insert(lines, side_name .. '_has_cc=' .. tostring(has_cc))
        table.insert(lines, side_name .. '_has_cs=' .. tostring(has_cs))
        table.insert(lines, side_name .. '_has_cd=' .. tostring(has_cd))
      end
    end
    check('a', v.cur_layout.a)
    check('b', v.cur_layout.b)
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

a_has_cc=$(grep '^a_has_cc=' /tmp/cr-keymap-check.txt | cut -d= -f2 || echo "missing")
b_has_cc=$(grep '^b_has_cc=' /tmp/cr-keymap-check.txt | cut -d= -f2 || echo "missing")

if [ "$a_has_cc" = "true" ] && [ "$b_has_cc" = "true" ]; then
  echo "PASS: <leader>cc keymap set on both old (a) and new (b) diff buffers"
elif [ "$b_has_cc" = "true" ]; then
  echo "PARTIAL: <leader>cc on new side only"
  exit 1
else
  echo "FAIL: <leader>cc not set"
  exit 1
fi
