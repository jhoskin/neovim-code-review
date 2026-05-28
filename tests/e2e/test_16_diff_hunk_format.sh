#!/usr/bin/env bash
# Test 16: files[0].lines[0].diff_hunk is non-empty unified diff
# Covers: TST-STO-0005
# starting with `@@ -` and containing the commented line.
# Covers REQ-STO-0005
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-16"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

result_file=$(mktemp -t nvim-code-review-result.XXXXXX)
rm -f "$result_file"
exit_file=$(mktemp -t nvim-exit.XXXXXX)

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "NVIM_CODE_REVIEW_RESULT=$result_file nvim -u $PLUGIN_ROOT/tests/minimal_init.lua; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

# Add a line comment on line 5 ("Line five uncommitted." — the added line in working tree)
cat > /tmp/cr-hunk-comment.lua <<'EOF'
local cr = require('code-review')
cr._session.store:add_line_comment('greeting.txt', nil, 5, 'new', 'Hunk format check')
EOF
send_cmd "$SESSION" "luafile /tmp/cr-hunk-comment.lua"
sleep 1

send_cmd "$SESSION" "CodeReviewSubmit"
sleep 1
send_keys "$SESSION" Enter
wait_for_exit "$SESSION" 5

exit_code=$(cat "$exit_file")
[ "$exit_code" = "0" ] || { echo "FAIL: exit code $exit_code"; exit 1; }

review_path=$(cat "$result_file")
[ -f "$review_path" ] || { echo "FAIL: review file missing"; exit 1; }

hunk=$(jq -r '.files[0].lines[0].diff_hunk' "$review_path")
echo "--- diff_hunk ---"
echo "$hunk"
echo "--- end ---"

if [ -z "$hunk" ] || [ "$hunk" = "null" ]; then
  echo "FAIL: diff_hunk is empty/null"
  exit 1
fi
echo "diff_hunk non-empty: PASS"

first_line=$(echo "$hunk" | head -1)
case "$first_line" in
  "@@ -"*) echo "diff_hunk starts with '@@ -': PASS" ;;
  *) echo "FAIL: diff_hunk does not start with '@@ -': $first_line"; exit 1 ;;
esac

# Verify the hunk includes the commented (added) line
if ! echo "$hunk" | grep -q "Line five uncommitted"; then
  echo "FAIL: diff_hunk does not contain commented line content"
  exit 1
fi
echo "diff_hunk includes commented line: PASS"

echo "PASS: diff_hunk is a unified diff containing the commented line"
