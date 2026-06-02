#!/usr/bin/env bash
# Test 11: diff buffers are marked non-modifiable during a review
# Covers: TST-DIF-0007
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-11"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

cat > /tmp/cr-readonly-check.lua <<'EOF'
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
local lines = {
  'a_bufnr=' .. tostring(a_buf),
  'a_modifiable=' .. tostring(a_buf and vim.bo[a_buf].modifiable),
  'b_bufnr=' .. tostring(b_buf),
  'b_modifiable=' .. tostring(b_buf and vim.bo[b_buf].modifiable),
}
vim.fn.writefile(lines, '/tmp/cr-readonly-check.txt')
EOF

mv /tmp/cr-readonly-check.txt /tmp/cr-readonly-check.txt.bak 2>/dev/null || true
send_cmd "$SESSION" "luafile /tmp/cr-readonly-check.lua"
sleep 1

if [ ! -s /tmp/cr-readonly-check.txt ]; then
  echo "FAIL: check file empty"
  capture_pane "$SESSION"
  exit 1
fi

echo "--- check ---"
cat /tmp/cr-readonly-check.txt
echo "--- end ---"

a_mod=$(grep '^a_modifiable=' /tmp/cr-readonly-check.txt | cut -d= -f2)
b_mod=$(grep '^b_modifiable=' /tmp/cr-readonly-check.txt | cut -d= -f2)

if [ "$a_mod" = "false" ] && [ "$b_mod" = "false" ]; then
  echo "PASS: both diff buffers are non-modifiable"
else
  echo "FAIL: a_modifiable=$a_mod b_modifiable=$b_mod (both should be false)"
  exit 1
fi
