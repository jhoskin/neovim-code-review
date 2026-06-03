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
    add_comment = { "c", "<leader>Rc" }, -- bind BOTH keys to the line comment
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
local has_c, has_leader = false, false
for _, m in ipairs(maps) do
  if m.lhs == 'c' then has_c = true end
  if m.lhs == ' Rc' then has_leader = true end -- leader=<Space>, so '<leader>Rc' == ' Rc'
end
vim.fn.writefile({
  'has_c=' .. tostring(has_c),
  'has_leader_rc=' .. tostring(has_leader),
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

has_c=$(grep '^has_c=' /tmp/cr-list-check.txt | cut -d= -f2)
has_leader=$(grep '^has_leader_rc=' /tmp/cr-list-check.txt | cut -d= -f2)

if [ "$has_c" = "true" ] && [ "$has_leader" = "true" ]; then
  echo "PASS: list keymap bound both 'c' and '<leader>Rc' to the line comment"
else
  echo "FAIL: expected both keys bound (has_c=$has_c has_leader_rc=$has_leader)"
  exit 1
fi
