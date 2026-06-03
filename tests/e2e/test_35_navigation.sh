#!/usr/bin/env bash
# Test 35: next_file navigation advances to the next changed file and focuses
# the new-side diff window.
# Covers: TST-RND-0010
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-35"
trap "cleanup_session $SESSION" EXIT

# A repo with two modified files.
repo=$(mktemp -d -t code-review-test.XXXXXX)
cd "$repo"
git init -q -b main
git config user.email t@x ; git config user.name t ; git config commit.gpgsign false
printf 'a1\na2\n' > file_a.txt
printf 'b1\nb2\n' > file_b.txt
git add . && git commit -q -m initial
printf 'a1\na2 changed\n' > file_a.txt
printf 'b1\nb2 changed\n' > file_b.txt
cd - >/dev/null
echo "Test repo: $repo"

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "file_a.txt" 5
sleep 1

cat > /tmp/cr-nav-check.lua <<'EOF'
local render = require('code-review.render.init')
local first = render.current_path()
render.next_file()
local cur = vim.api.nvim_get_current_buf()
vim.fn.writefile({
  'first=' .. tostring(first),
  'after_next=' .. tostring(render.current_path()),
  'cur_buf=' .. vim.api.nvim_buf_get_name(cur),
}, '/tmp/cr-nav-check.txt')
EOF

mv /tmp/cr-nav-check.txt /tmp/cr-nav-check.txt.bak 2>/dev/null || true
send_cmd "$SESSION" "luafile /tmp/cr-nav-check.lua"
sleep 1

if [ ! -s /tmp/cr-nav-check.txt ]; then
  echo "FAIL: nav check file empty"
  capture_pane "$SESSION"
  exit 1
fi
echo "--- check ---"; cat /tmp/cr-nav-check.txt; echo "--- end ---"

first=$(grep '^first=' /tmp/cr-nav-check.txt | cut -d= -f2)
after=$(grep '^after_next=' /tmp/cr-nav-check.txt | cut -d= -f2)
cur_buf=$(grep '^cur_buf=' /tmp/cr-nav-check.txt | cut -d= -f2-)

if [ "$first" = "$after" ]; then
  echo "FAIL: next_file did not change the current file (still $first)"
  exit 1
fi
echo "next_file advanced ($first -> $after): PASS"

case "$cur_buf" in
  *code-review://new/*) echo "focus is in the new-side window: PASS" ;;
  *) echo "FAIL: expected focus in a code-review://new/ buffer, got: $cur_buf"; exit 1 ;;
esac

echo "PASS: next_file advances the file and focuses the new-side window"
