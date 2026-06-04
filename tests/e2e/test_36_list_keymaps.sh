#!/usr/bin/env bash
# Test 36: a list-valued keymap binds every key in the list (the dual
# single-key + <leader>R* scheme). Covers the string-or-list keymap support.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-36"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

cat > /tmp/cr-list-init.lua <<EOF
vim.opt.runtimepath:prepend("$PLUGIN_ROOT")
vim.opt.swapfile = false
vim.opt.backup = false
vim.g.mapleader = " "
require("code-review").setup({
  keymaps = {
    add_comment = { "r", "<leader>Rr" }, -- bind BOTH keys to the line comment
  },
})
EOF

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "nvim -u /tmp/cr-list-init.lua"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

cat > /tmp/cr-list-check.lua <<'EOF'
local bufnr
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b):find('code-review://new/', 1, true) then bufnr = b end
end
local maps = vim.api.nvim_buf_get_keymap(bufnr, 'n')
local has_single, has_leader = false, false
for _, m in ipairs(maps) do
  if m.lhs == 'r' then has_single = true end
  if m.lhs == ' Rr' then has_leader = true end -- leader=<Space>, so '<leader>Rr' == ' Rr'
end
vim.fn.writefile({
  'has_single=' .. tostring(has_single),
  'has_leader_rr=' .. tostring(has_leader),
}, '/tmp/cr-list-check.txt')
EOF

mv /tmp/cr-list-check.txt /tmp/cr-list-check.txt.bak 2>/dev/null || true
send_cmd "$SESSION" "luafile /tmp/cr-list-check.lua"
sleep 1

if [ ! -s /tmp/cr-list-check.txt ]; then
  echo "FAIL: list-keymap check file empty"
  capture_pane "$SESSION"
  exit 1
fi
echo "--- check ---"; cat /tmp/cr-list-check.txt; echo "--- end ---"

has_single=$(grep '^has_single=' /tmp/cr-list-check.txt | cut -d= -f2)
has_leader=$(grep '^has_leader_rr=' /tmp/cr-list-check.txt | cut -d= -f2)

if [ "$has_single" = "true" ] && [ "$has_leader" = "true" ]; then
  echo "PASS: list keymap bound both 'r' and '<leader>Rr' to the line comment"
else
  echo "FAIL: expected both keys bound (has_single=$has_single has_leader_rr=$has_leader)"
  exit 1
fi
