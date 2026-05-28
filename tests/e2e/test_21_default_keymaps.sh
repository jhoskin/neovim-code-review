#!/usr/bin/env bash
# Test 21: ALL six default keymaps (Rc, Rf, Rd, Rs, Rq, Rp) are registered
# Covers: TST-UIX-0008
# on the new-side diff buffer. test_02 covers the both-sides assertion for Rc;
# this test covers full keymap coverage.
# Covers REQ-UIX-0008
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-21"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

cat > /tmp/cr-allkeys.lua <<'EOF'
local lib = require('diffview.lib')
local view = lib.get_current_view()
local bufnr = view.cur_layout.b.file.bufnr
local maps = vim.api.nvim_buf_get_keymap(bufnr, 'n')
local want = { Rc = false, Rf = false, Rd = false, Rs = false, Rq = false, Rp = false }
for _, m in ipairs(maps) do
  for k, _ in pairs(want) do
    if m.lhs == ' ' .. k then want[k] = true end
  end
end
local lines = { 'bufnr=' .. tostring(bufnr) }
for _, k in ipairs({ 'Rc', 'Rf', 'Rd', 'Rs', 'Rq', 'Rp' }) do
  table.insert(lines, k .. '=' .. tostring(want[k]))
end
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
for k in Rc Rf Rd Rs Rq Rp; do
  v=$(grep "^${k}=" /tmp/cr-allkeys.txt | cut -d= -f2)
  if [ "$v" != "true" ]; then
    echo "FAIL: <leader>$k not registered on new-side diff buffer"
    missing=1
  fi
done

if [ "$missing" != "0" ]; then
  exit 1
fi

echo "PASS: all six default keymaps (Rc, Rf, Rd, Rs, Rq, Rp) set on diff buffer"
