#!/usr/bin/env bash
# Test 06: Add a line comment via keymap, submit, verify in JSON output
# Covers: TST-STO-0001, TST-STO-0004, TST-CLI-0002
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-06"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

result_file=$(mktemp -t nvim-code-review-result.XXXXXX)
mv "$result_file" "$result_file.bak" 2>/dev/null || true
exit_file=$(mktemp -t nvim-exit.XXXXXX)

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "NVIM_CODE_REVIEW_RESULT=$result_file nvim -u $PLUGIN_ROOT/tests/minimal_init.lua; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

# Programmatically add a line comment via Lua (more reliable than keystroke simulation)
cat > /tmp/cr-add-comment.lua <<'EOF'
local cr = require('code-review')
cr._session.store:add_line_comment('greeting.txt', nil, 5, 'new', 'Test comment on line 5')
cr._session.store:add_file_comment('greeting.txt', 'Overall this file needs a review pass')
EOF
send_cmd "$SESSION" "luafile /tmp/cr-add-comment.lua"
sleep 1

# Submit
send_cmd "$SESSION" "CodeReviewSubmit"
sleep 1
send_keys "$SESSION" Enter  # confirm summary
wait_for_exit "$SESSION" 5

exit_code=$(cat "$exit_file")
[ "$exit_code" = "0" ] || { echo "FAIL: exit code $exit_code"; exit 1; }

review_path=$(cat "$result_file")
[ -f "$review_path" ] || { echo "FAIL: review file missing"; exit 1; }

# Verify the comments are in the JSON
comment=$(jq -r '.files[0].lines[0].body' "$review_path")
file_comment=$(jq -r '.files[0].comment' "$review_path")
path=$(jq -r '.files[0].path' "$review_path")
line=$(jq -r '.files[0].lines[0].new_lineno' "$review_path")

[ "$comment" = "Test comment on line 5" ] || { echo "FAIL: comment text wrong: $comment"; exit 1; }
[ "$file_comment" = "Overall this file needs a review pass" ] || { echo "FAIL: file comment wrong: $file_comment"; exit 1; }
[ "$path" = "greeting.txt" ] || { echo "FAIL: path wrong: $path"; exit 1; }
[ "$line" = "5" ] || { echo "FAIL: line wrong: $line"; exit 1; }

echo "PASS: line + file comments round-tripped through submit"
