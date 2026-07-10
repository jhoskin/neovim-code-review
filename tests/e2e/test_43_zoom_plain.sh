#!/usr/bin/env bash
# Test 43: while zoomed (<leader>Rz), the surviving diff buffer is rendered
# without diff paint so treesitter syntax shows through. The diff namespace
# (code_review_render) is emptied on the survivor; comment markers stay; the
# plain rendering persists across next_file (<leader>Rn) while zoomed; unzoom
# restores the diff paint.
# Covers: TST-RND-0018
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-43"
trap "cleanup_session $SESSION" EXIT

# A repo with two modified files, each a real change (so they carry diff paint).
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

# --- one lua dump, writes to the path in g:crout ------------------------------
# Counts extmarks in the diff-paint namespace (code_review_render) and the
# comment namespace (code_review_comments) on the current new-side buffer.

cat > /tmp/cr-zoom-plain.lua <<'EOF'
local render = require('code-review.render.init')
local wins = render.review_windows()
local new_buf
for _, w in ipairs(wins) do
  local b = vim.api.nvim_win_get_buf(w)
  local name = vim.api.nvim_buf_get_name(b)
  if name:find('code-review://new/', 1, true) then new_buf = b end
end
local nss = vim.api.nvim_get_namespaces()
local ns = nss['code_review_render']
local ns_c = nss['code_review_comments']
local diff_marks = -1
local comment_marks = -1
if new_buf and ns then
  diff_marks = #vim.api.nvim_buf_get_extmarks(new_buf, ns, 0, -1, {})
end
if new_buf and ns_c then
  comment_marks = #vim.api.nvim_buf_get_extmarks(new_buf, ns_c, 0, -1, {})
end
vim.fn.writefile({
  'nwins=' .. tostring(#wins),
  'new_buf=' .. tostring(new_buf),
  'new_name=' .. (new_buf and vim.api.nvim_buf_get_name(new_buf) or 'nil'),
  'diff_marks=' .. tostring(diff_marks),
  'comment_marks=' .. tostring(comment_marks),
}, vim.g.crout)
EOF

for f in before zoom next unzoom; do
  mv "/tmp/cr-zoom-plain-$f.txt" "/tmp/cr-zoom-plain-$f.txt.bak" 2>/dev/null || true
done

# dump <phase>: set g:crout and run the lua dump for this phase.
dump() {
  local phase="$1"
  send_cmd "$SESSION" "let g:crout='/tmp/cr-zoom-plain-$phase.txt'"
  send_cmd "$SESSION" "luafile /tmp/cr-zoom-plain.lua"
  sleep 1
  if [ ! -s "/tmp/cr-zoom-plain-$phase.txt" ]; then
    echo "FAIL: $phase check file empty"
    capture_pane "$SESSION"
    exit 1
  fi
  echo "--- $phase ---"; cat "/tmp/cr-zoom-plain-$phase.txt"; echo "--- end ---"
}

field() { grep "^$2=" "/tmp/cr-zoom-plain-$1.txt" | cut -d= -f2-; }

# --- drive the review ---------------------------------------------------------

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "file_a.txt" 5
sleep 1

# Before zoom: the new-side buffer carries diff paint.
send_keys "$SESSION" Escape
dump before
b_nwins=$(field before nwins)
b_diff=$(field before diff_marks)
if [ "$b_nwins" != "3" ]; then
  echo "FAIL: expected 3 review windows before zoom, got $b_nwins"; exit 1
fi
if [ "$b_diff" = "-1" ]; then
  echo "FAIL: could not locate the new-side buffer or diff namespace before zoom"; exit 1
fi
if [ "$b_diff" -le 0 ]; then
  echo "FAIL: expected diff paint on the new-side buffer before zoom, got $b_diff extmarks"; exit 1
fi
echo "before zoom (3 windows, diff paint present): PASS"

# Zoom in: the survivor drops its diff paint.
send_keys "$SESSION" Escape
send_keys "$SESSION" Space R z
sleep 1
dump zoom
z_nwins=$(field zoom nwins)
z_diff=$(field zoom diff_marks)
if [ "$z_nwins" != "2" ]; then
  echo "FAIL: expected 2 review windows when zoomed, got $z_nwins"; exit 1
fi
if [ "$z_diff" != "0" ]; then
  echo "FAIL: expected 0 diff extmarks on the zoomed survivor, got $z_diff"; exit 1
fi
echo "zoom in (2 windows, survivor diff paint cleared): PASS"

# Next file while zoomed: the new survivor is plain too.
send_keys "$SESSION" Escape
send_keys "$SESSION" Space R n
sleep 1
dump next
n_nwins=$(field next nwins)
n_diff=$(field next diff_marks)
if [ "$n_nwins" != "2" ]; then
  echo "FAIL: expected zoom to persist across next_file (2 windows), got $n_nwins"; exit 1
fi
if [ "$n_diff" != "0" ]; then
  echo "FAIL: expected 0 diff extmarks on the next-file survivor while zoomed, got $n_diff"; exit 1
fi
echo "next file while zoomed (2 windows, survivor still plain): PASS"

# Unzoom: the diff paint returns.
send_keys "$SESSION" Escape
send_keys "$SESSION" Space R z
sleep 1
dump unzoom
u_nwins=$(field unzoom nwins)
u_diff=$(field unzoom diff_marks)
if [ "$u_nwins" != "3" ]; then
  echo "FAIL: expected 3 review windows after unzoom, got $u_nwins"; exit 1
fi
if [ "$u_diff" = "-1" ]; then
  echo "FAIL: could not locate the new-side buffer or diff namespace after unzoom"; exit 1
fi
if [ "$u_diff" -le 0 ]; then
  echo "FAIL: expected diff paint to return after unzoom, got $u_diff extmarks"; exit 1
fi
echo "unzoom (3 windows, diff paint restored): PASS"

echo "PASS: zoom renders the survivor without diff paint and restores it on unzoom"
