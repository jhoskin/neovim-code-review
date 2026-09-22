#!/usr/bin/env bash
# Test 42: the tmux-style zoom toggle (<leader>Rz) hides the other diff window,
# gives the survivor wrap + no cursorbind, restores all three windows on a
# second press, and stays zoomed across next_file (<leader>Rn). In wrap mode
# (the default) both diff windows wrap and scrollbind stays off; the align
# module owns the vertical sync (test_44 checks the rows stay level).
# Covers: TST-RND-0017
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-42"
trap "cleanup_session $SESSION" EXIT

# A repo with two modified files, each with old + new content.
repo=$(mktemp -d -t code-review-test.XXXXXX)
cd "$repo"
git init -q -b main
git config user.email t@x ; git config user.name t ; git config commit.gpgsign false
printf 'a1\na2\na3\n' > file_a.txt
printf 'b1\nb2\nb3\n' > file_b.txt
git add . && git commit -q -m initial
printf 'a1\na2 changed\na3\n' > file_a.txt
printf 'b1\nb2 changed\nb3\n' > file_b.txt
cd - >/dev/null
echo "Test repo: $repo"

# --- lua dumps, one per phase -------------------------------------------------

cat > /tmp/cr-zoom-on.lua <<'EOF'
local render = require('code-review.render.init')
local wins = render.review_windows()
local new_win
for _, w in ipairs(wins) do
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
  if name:find('code-review://new/', 1, true) then new_win = w end
end
local cur = vim.api.nvim_get_current_buf()
vim.fn.writefile({
  'nwins=' .. tostring(#wins),
  'cur_buf=' .. vim.api.nvim_buf_get_name(cur),
  'wrap=' .. tostring(new_win and vim.wo[new_win].wrap),
  'scrollbind=' .. tostring(new_win and vim.wo[new_win].scrollbind),
  'cursorbind=' .. tostring(new_win and vim.wo[new_win].cursorbind),
}, '/tmp/cr-zoom-on.txt')
EOF

cat > /tmp/cr-zoom-off.lua <<'EOF'
local render = require('code-review.render.init')
local wins = render.review_windows()
local old_win, new_win
for _, w in ipairs(wins) do
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
  if name:find('code-review://old/', 1, true) then old_win = w end
  if name:find('code-review://new/', 1, true) then new_win = w end
end
local old_row = old_win and vim.api.nvim_win_get_cursor(old_win)[1] or -1
local new_row = new_win and vim.api.nvim_win_get_cursor(new_win)[1] or -1
local old_col = old_win and vim.api.nvim_win_get_position(old_win)[2] or -1
local new_col = new_win and vim.api.nvim_win_get_position(new_win)[2] or -1
vim.fn.writefile({
  'nwins=' .. tostring(#wins),
  'wrap=' .. tostring(new_win and vim.wo[new_win].wrap),
  'scrollbind=' .. tostring(new_win and vim.wo[new_win].scrollbind),
  'cursorbind=' .. tostring(new_win and vim.wo[new_win].cursorbind),
  'old_row=' .. tostring(old_row),
  'new_row=' .. tostring(new_row),
  'old_col=' .. tostring(old_col),
  'new_col=' .. tostring(new_col),
}, '/tmp/cr-zoom-off.txt')
EOF

cat > /tmp/cr-zoom-persist.lua <<'EOF'
local render = require('code-review.render.init')
local wins = render.review_windows()
local cur = vim.api.nvim_get_current_buf()
vim.fn.writefile({
  'nwins=' .. tostring(#wins),
  'cur_buf=' .. vim.api.nvim_buf_get_name(cur),
}, '/tmp/cr-zoom-persist.txt')
EOF

mv /tmp/cr-zoom-on.txt /tmp/cr-zoom-on.txt.bak 2>/dev/null || true
mv /tmp/cr-zoom-off.txt /tmp/cr-zoom-off.txt.bak 2>/dev/null || true
mv /tmp/cr-zoom-persist.txt /tmp/cr-zoom-persist.txt.bak 2>/dev/null || true

# --- drive the review ---------------------------------------------------------

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "file_a.txt" 5
sleep 1

# Focus lands in the new-side diff window on load. Zoom in.
send_keys "$SESSION" Escape
send_keys "$SESSION" Space R z
sleep 1
send_cmd "$SESSION" "luafile /tmp/cr-zoom-on.lua"
sleep 1

if [ ! -s /tmp/cr-zoom-on.txt ]; then
  echo "FAIL: zoom-on check file empty"
  capture_pane "$SESSION"
  exit 1
fi
echo "--- zoom on ---"; cat /tmp/cr-zoom-on.txt; echo "--- end ---"

on_nwins=$(grep '^nwins=' /tmp/cr-zoom-on.txt | cut -d= -f2)
on_cur=$(grep '^cur_buf=' /tmp/cr-zoom-on.txt | cut -d= -f2-)
on_wrap=$(grep '^wrap=' /tmp/cr-zoom-on.txt | cut -d= -f2)
on_scrollbind=$(grep '^scrollbind=' /tmp/cr-zoom-on.txt | cut -d= -f2)
on_cursorbind=$(grep '^cursorbind=' /tmp/cr-zoom-on.txt | cut -d= -f2)

if [ "$on_nwins" != "2" ]; then
  echo "FAIL: expected 2 review windows when zoomed, got $on_nwins"; exit 1
fi
case "$on_cur" in
  *code-review://new/*) ;;
  *) echo "FAIL: expected focus in a code-review://new/ buffer when zoomed, got: $on_cur"; exit 1 ;;
esac
if [ "$on_wrap" != "true" ]; then
  echo "FAIL: expected wrap=true on the zoomed survivor, got $on_wrap"; exit 1
fi
if [ "$on_scrollbind" != "false" ]; then
  echo "FAIL: expected scrollbind=false on the zoomed survivor, got $on_scrollbind"; exit 1
fi
if [ "$on_cursorbind" != "false" ]; then
  echo "FAIL: expected cursorbind=false on the zoomed survivor, got $on_cursorbind"; exit 1
fi
echo "zoom in (2 windows, new-side focused, wrap on, binds off): PASS"

# Zoom out: restore all three windows.
send_keys "$SESSION" Escape
send_keys "$SESSION" Space R z
sleep 1
send_cmd "$SESSION" "luafile /tmp/cr-zoom-off.lua"
sleep 1

if [ ! -s /tmp/cr-zoom-off.txt ]; then
  echo "FAIL: zoom-off check file empty"
  capture_pane "$SESSION"
  exit 1
fi
echo "--- zoom off ---"; cat /tmp/cr-zoom-off.txt; echo "--- end ---"

off_nwins=$(grep '^nwins=' /tmp/cr-zoom-off.txt | cut -d= -f2)
off_wrap=$(grep '^wrap=' /tmp/cr-zoom-off.txt | cut -d= -f2)
off_scrollbind=$(grep '^scrollbind=' /tmp/cr-zoom-off.txt | cut -d= -f2)
off_cursorbind=$(grep '^cursorbind=' /tmp/cr-zoom-off.txt | cut -d= -f2)
off_old_row=$(grep '^old_row=' /tmp/cr-zoom-off.txt | cut -d= -f2)
off_new_row=$(grep '^new_row=' /tmp/cr-zoom-off.txt | cut -d= -f2)
off_old_col=$(grep '^old_col=' /tmp/cr-zoom-off.txt | cut -d= -f2)
off_new_col=$(grep '^new_col=' /tmp/cr-zoom-off.txt | cut -d= -f2)

if [ "$off_nwins" != "3" ]; then
  echo "FAIL: expected 3 review windows after restore, got $off_nwins"; exit 1
fi
if [ "$off_wrap" != "true" ]; then
  echo "FAIL: expected wrap=true after restore (wrap mode), got $off_wrap"; exit 1
fi
if [ "$off_scrollbind" != "false" ]; then
  echo "FAIL: expected scrollbind=false after restore (align owns the sync), got $off_scrollbind"; exit 1
fi
if [ "$off_cursorbind" != "true" ]; then
  echo "FAIL: expected cursorbind=true after restore, got $off_cursorbind"; exit 1
fi
if [ "$off_old_row" != "$off_new_row" ]; then
  echo "FAIL: expected old/new cursor rows equal after restore, got old=$off_old_row new=$off_new_row"; exit 1
fi
if [ "$off_old_col" = "-1" ] || [ "$off_new_col" = "-1" ]; then
  echo "FAIL: could not locate both diff windows after restore"; exit 1
fi
if [ "$off_old_col" -ge "$off_new_col" ]; then
  echo "FAIL: expected old window left of new (old_col=$off_old_col < new_col=$off_new_col)"; exit 1
fi
echo "zoom out (3 windows, wrap on, cursorbind on, rows aligned, old left of new): PASS"

# Zoom back in, then advance to the next file: zoom must persist.
send_keys "$SESSION" Escape
send_keys "$SESSION" Space R z
sleep 1
send_keys "$SESSION" Escape
send_keys "$SESSION" Space R n
sleep 1
send_cmd "$SESSION" "luafile /tmp/cr-zoom-persist.lua"
sleep 1

if [ ! -s /tmp/cr-zoom-persist.txt ]; then
  echo "FAIL: zoom-persist check file empty"
  capture_pane "$SESSION"
  exit 1
fi
echo "--- zoom persist ---"; cat /tmp/cr-zoom-persist.txt; echo "--- end ---"

p_nwins=$(grep '^nwins=' /tmp/cr-zoom-persist.txt | cut -d= -f2)
p_cur=$(grep '^cur_buf=' /tmp/cr-zoom-persist.txt | cut -d= -f2-)

if [ "$p_nwins" != "2" ]; then
  echo "FAIL: expected zoom to persist across next_file (2 windows), got $p_nwins"; exit 1
fi
case "$p_cur" in
  *code-review://new/*) ;;
  *) echo "FAIL: expected a code-review://new/ buffer after next_file while zoomed, got: $p_cur"; exit 1 ;;
esac
echo "zoom persists across next_file (2 windows, new-side buffer): PASS"

echo "PASS: zoom toggle hides/restores the diff windows and persists across next_file"
