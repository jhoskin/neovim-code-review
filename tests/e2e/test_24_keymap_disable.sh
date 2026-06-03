#!/usr/bin/env bash
# Test 24: setup({ keymaps = { add_comment = false } }) disables that default
# Covers: TST-UIX-0010
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-24"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

# Custom init: disable add_comment and delete_comment, keep others
cat > /tmp/cr-disable-init.lua <<'EOF'
local plugin = "/Users/joh/dev/neovim-code-review"

vim.opt.runtimepath:prepend(plugin)
vim.opt.swapfile = false
vim.opt.backup = false
vim.g.mapleader = " "

require("code-review").setup({
  keymaps = {
    add_comment = false,
    delete_comment = false,
  },
})
EOF

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "nvim -u /tmp/cr-disable-init.lua"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

# Check that the disabled keymaps are NOT set, but the others are
cat > /tmp/cr-disable-check.lua <<'EOF'
local bufnr
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(buf):find('code-review://new/', 1, true) then bufnr = buf end
end
local maps = vim.api.nvim_buf_get_keymap(bufnr, 'n')

local has = { cc = false, cd = false, cs = false, cf = false, cq = false, cp = false }
for _, m in ipairs(maps) do
  if m.lhs == ' Rc' then has.cc = true end
  if m.lhs == ' Rd' then has.cd = true end
  if m.lhs == ' Rs' then has.cs = true end
  if m.lhs == ' Rf' then has.cf = true end
  if m.lhs == ' Rq' then has.cq = true end
  if m.lhs == ' Rp' then has.cp = true end
end

vim.fn.writefile({
  'add_comment_disabled=' .. tostring(not has.cc),
  'delete_comment_disabled=' .. tostring(not has.cd),
  'summary_present=' .. tostring(has.cs),
  'file_comment_present=' .. tostring(has.cf),
  'cancel_present=' .. tostring(has.cq),
  'pause_present=' .. tostring(has.cp),
}, '/tmp/cr-disable-check.txt')
EOF

mv /tmp/cr-disable-check.txt /tmp/cr-disable-check.txt.bak 2>/dev/null || true
send_cmd "$SESSION" "luafile /tmp/cr-disable-check.lua"
sleep 1

if [ ! -s /tmp/cr-disable-check.txt ]; then
  echo "FAIL: check file empty"
  capture_pane "$SESSION"
  exit 1
fi

echo "--- check ---"
cat /tmp/cr-disable-check.txt
echo "--- end ---"

ok=true
for key in add_comment_disabled delete_comment_disabled summary_present file_comment_present cancel_present pause_present; do
  val=$(grep "^${key}=" /tmp/cr-disable-check.txt | cut -d= -f2)
  if [ "$val" != "true" ]; then
    echo "FAIL: $key = $val (expected true)"
    ok=false
  fi
done

if [ "$ok" = "true" ]; then
  echo "PASS: keymaps.X = false disables that default, others still bound"
else
  exit 1
fi
