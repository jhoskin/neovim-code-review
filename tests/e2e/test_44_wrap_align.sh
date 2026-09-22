#!/usr/bin/env bash
# Test 44: long lines wrap in both diff windows and the two sides stay level
# row for row on the real screen, through scrolls driven by real keys (the
# WinScrolled path), a window resize, and the zoom round-trip.
# Covers: TST-RND-0019
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-44"
trap "cleanup_session $SESSION" EXIT

# A repo with one modified file: the new side gets a 300-char line at row 5,
# the old side keeps a 200-char line at row 20 that the new side shortens.
repo=$(mktemp -d -t code-review-test.XXXXXX)
cd "$repo"
git init -q -b main
git config user.email t@x ; git config user.name t ; git config commit.gpgsign false
{
  for i in $(seq 1 40); do
    if [ "$i" -eq 20 ]; then printf '%0200d\n' 0 | tr 0 x; else echo "line $i"; fi
  done
} > long.txt
git add . && git commit -q -m initial
{
  for i in $(seq 1 40); do
    if [ "$i" -eq 5 ]; then printf '%0300d\n' 0 | tr 0 y; else echo "line $i"; fi
  done
} > long.txt
cd - >/dev/null
echo "Test repo: $repo"

# The probe reads the number column of both diff windows straight off the
# screen grid and compares the screen row of every line visible on both sides.
cat > /tmp/cr-wrap-align.lua <<'EOF'
local render = require('code-review.render.init')
local ow, nw
for _, w in ipairs(render.review_windows()) do
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
  if name:find('code-review://old/', 1, true) then ow = w end
  if name:find('code-review://new/', 1, true) then nw = w end
end
local out = { 'nwins=' .. #render.review_windows() }
if not (ow and nw) then
  out[#out + 1] = 'error=only one diff window (zoomed?)'
else
  local function colmap(w)
    local pos = vim.api.nvim_win_get_position(w)
    local textoff = vim.fn.getwininfo(w)[1].textoff
    local m, blank = {}, 0
    for r = pos[1] + 1, pos[1] + vim.api.nvim_win_get_height(w) do
      local s = ''
      for c = pos[2] + 1, pos[2] + textoff do s = s .. vim.fn.screenstring(r, c) end
      local n = tonumber(s:match('%d+'))
      if n then m[n] = r else blank = blank + 1 end
    end
    return m, blank
  end
  local mo, blank_o = colmap(ow)
  local mn, blank_n = colmap(nw)
  local bad, common = 0, 0
  for l, r in pairs(mo) do
    if mn[l] then
      common = common + 1
      if mn[l] ~= r then bad = bad + 1 end
    end
  end
  local vo = vim.api.nvim_win_call(ow, function() return vim.fn.winsaveview() end)
  local vn = vim.api.nvim_win_call(nw, function() return vim.fn.winsaveview() end)
  local h5 = vim.api.nvim_win_text_height(nw, { start_row = 4, end_row = 4 })
  out = {
    'nwins=' .. #render.review_windows(),
    'misaligned=' .. bad,
    'common=' .. common,
    'blank_rows=' .. (blank_o + blank_n),
    'old_top=' .. vo.topline .. '+' .. vo.topfill,
    'new_top=' .. vn.topline .. '+' .. vn.topfill,
    'wrap=' .. tostring(vim.wo[nw].wrap),
    'scrollbind=' .. tostring(vim.wo[nw].scrollbind),
    'new5_rows=' .. (h5.all - h5.fill),
  }
end
vim.fn.writefile(out, vim.g.crout)
EOF

dump() {
  local phase="$1"
  local f="/tmp/cr-wrap-align-$phase.txt"
  rm -f "$f"
  send_cmd "$SESSION" "let g:crout='$f'"
  send_cmd "$SESSION" "luafile /tmp/cr-wrap-align.lua"
  sleep 0.5
  if [ ! -s "$f" ]; then
    echo "FAIL: probe wrote nothing for phase $phase"
    capture_pane "$SESSION"
    exit 1
  fi
  echo "--- $phase ---"; cat "$f"; echo "--- end ---"
}

field() {
  grep "^$2=" "/tmp/cr-wrap-align-$1.txt" | cut -d= -f2-
}

assert_level() {
  local phase="$1"
  local bad common
  bad=$(field "$phase" misaligned)
  common=$(field "$phase" common)
  if [ "$bad" != "0" ]; then
    echo "FAIL ($phase): $bad visible lines sit on different rows in old vs new"
    capture_pane "$SESSION"
    exit 1
  fi
  if [ "${common:-0}" -lt 3 ]; then
    echo "FAIL ($phase): too few lines visible on both sides to judge ($common)"
    capture_pane "$SESSION"
    exit 1
  fi
  if [ "$(field "$phase" old_top)" != "$(field "$phase" new_top)" ]; then
    echo "FAIL ($phase): topline/topfill differ: old=$(field "$phase" old_top) new=$(field "$phase" new_top)"
    capture_pane "$SESSION"
    exit 1
  fi
  echo "$phase: level (common=$common): PASS"
}

# --- drive the review ---------------------------------------------------------

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "long.txt" 5
sleep 1

dump load
if [ "$(field load wrap)" != "true" ]; then
  echo "FAIL: expected wrap=true in the new diff window"; exit 1
fi
if [ "$(field load scrollbind)" != "false" ]; then
  echo "FAIL: expected scrollbind=false (align module owns the sync)"; exit 1
fi
if [ "$(field load new5_rows)" -lt 2 ]; then
  echo "FAIL: the 300-char line did not wrap (rows=$(field load new5_rows))"; exit 1
fi
if [ "$(field load blank_rows)" -lt 1 ]; then
  echo "FAIL: expected padding rows beside the wrapped line"; exit 1
fi
assert_level load

# Real key scrolls from the new side (focus lands there on load).
send_keys "$SESSION" Escape
send_keys "$SESSION" C-e C-e C-e
sleep 0.5
dump ctrl-e
assert_level ctrl-e

send_keys "$SESSION" Escape
send_keys "$SESSION" 5 G z t
sleep 0.5
dump zt5
assert_level zt5
if [ "$(field zt5 new_top)" != "5+0" ]; then
  echo "FAIL: expected the wrapped line at the top after zt (new_top=$(field zt5 new_top))"; exit 1
fi

send_keys "$SESSION" Escape
send_keys "$SESSION" C-e
sleep 0.5
dump ctrl-e-over-wrap
assert_level ctrl-e-over-wrap
if [ "$(field ctrl-e-over-wrap new_top)" != "6+0" ]; then
  echo "FAIL: Ctrl-E over the wrapped line should land on line 6 (new_top=$(field ctrl-e-over-wrap new_top))"; exit 1
fi

send_keys "$SESSION" Escape
send_keys "$SESSION" G
sleep 0.5
dump G
assert_level G

# Scroll from the old side, over its own long line.
send_keys "$SESSION" Escape
send_keys "$SESSION" C-w h
send_keys "$SESSION" 1 8 G z t
send_keys "$SESSION" C-e C-e C-e C-e
sleep 0.5
dump old-side
assert_level old-side

send_keys "$SESSION" Escape
send_keys "$SESSION" C-y C-y
sleep 0.5
dump old-side-up
assert_level old-side-up

# A resize changes the wrap points; the padding must follow.
send_cmd "$SESSION" "vertical resize 45"
sleep 1
dump resized
assert_level resized

# Zoom in and out: padding is dropped while zoomed and rebuilt after.
send_keys "$SESSION" Escape
send_keys "$SESSION" Space R z
sleep 1
dump zoomed
if [ "$(field zoomed nwins)" != "2" ]; then
  echo "FAIL: expected 2 review windows while zoomed"; exit 1
fi
send_keys "$SESSION" Escape
send_keys "$SESSION" Space R z
sleep 1
dump unzoomed
assert_level unzoomed

echo "PASS: wrapped diff windows stay level through scrolls, resize and zoom"
