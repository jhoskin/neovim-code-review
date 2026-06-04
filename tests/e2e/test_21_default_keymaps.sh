#!/usr/bin/env bash
# Test 21: ALL default action keymaps (Rn, RN, Rc, Rf, Rd, Rs, Rq, Rp) plus the
# change-navigation keys ]c / [c are registered on the new-side diff buffer.
# Covers: TST-UIX-0008, TST-UIX-0012
# test_02 covers the both-sides assertion for Rc; this test covers full coverage.
# Covers REQ-UIX-0008, REQ-UIX-0012
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-21"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

cat > /tmp/cr-allkeys.lua <<'EOF'
local bufnr
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(buf):find('code-review://new/', 1, true) then bufnr = buf end
end
local maps = vim.api.nvim_buf_get_keymap(bufnr, 'n')
local want = { Rn = false, RN = false, Rc = false, Rf = false, Rd = false, Rs = false, Rq = false, Rp = false }
local bracket = { next_change = false, prev_change = false }
for _, m in ipairs(maps) do
  for k, _ in pairs(want) do
    if m.lhs == ' ' .. k then want[k] = true end
  end
  if m.lhs == ']c' then bracket.next_change = true end
  if m.lhs == '[c' then bracket.prev_change = true end
end
local lines = { 'bufnr=' .. tostring(bufnr) }
for _, k in ipairs({ 'Rn', 'RN', 'Rc', 'Rf', 'Rd', 'Rs', 'Rq', 'Rp' }) do
  table.insert(lines, k .. '=' .. tostring(want[k]))
end
table.insert(lines, 'next_change=' .. tostring(bracket.next_change))
table.insert(lines, 'prev_change=' .. tostring(bracket.prev_change))
vim.fn.writefile(lines, '/tmp/cr-allkeys.txt')
EOF

mv /tmp/cr-allkeys.txt /tmp/cr-allkeys.txt.bak 2>/dev/null || true

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 3

send_cmd "$SESSION" "luafile /tmp/cr-allkeys.lua"
sleep 1

if [ ! -s /tmp/cr-allkeys.txt ]; then
  echo "FAIL: allkeys check file empty"
  capture_pane "$SESSION"
  exit 1
fi

echo "--- keymap check ---"
cat /tmp/cr-allkeys.txt
echo "--- end ---"

missing=0
for k in Rn RN Rc Rf Rd Rs Rq Rp; do
  v=$(grep "^${k}=" /tmp/cr-allkeys.txt | cut -d= -f2)
  if [ "$v" != "true" ]; then
    echo "FAIL: <leader>$k not registered on new-side diff buffer"
    missing=1
  fi
done

# Change-navigation keys (]c / [c) -- TST-UIX-0012.
for key in next_change prev_change; do
  v=$(grep "^${key}=" /tmp/cr-allkeys.txt | cut -d= -f2)
  if [ "$v" != "true" ]; then
    echo "FAIL: $key (]c / [c) not registered on new-side diff buffer"
    missing=1
  fi
done

if [ "$missing" != "0" ]; then
  exit 1
fi

echo "PASS: all action keymaps (Rn/RN/Rc/Rf/Rd/Rs/Rq/Rp) + ]c/[c set on the diff buffer"
