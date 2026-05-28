#!/usr/bin/env bash
# Test 17: session commands (Submit/Cancel/Pause/Copy) only exist while a
# Covers: TST-CLI-0008
# review session is active. They are absent before :CodeReview and after
# :CodeReviewCancel (interactive mode).
# Covers REQ-CLI-0008
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-17"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

# Interactive mode so cancel doesn't kill nvim
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "unset NVIM_CODE_REVIEW_RESULT; nvim -u $PLUGIN_ROOT/tests/minimal_init.lua"
sleep 1.5

# Lua probe: dump existence of the four session commands to a file.
cat > /tmp/cr-cmd-probe.lua <<'EOF'
local cmds = vim.api.nvim_get_commands({})
local targets = { 'CodeReviewSubmit', 'CodeReviewCancel', 'CodeReviewPause', 'CodeReviewCopy' }
local stage = vim.g.cr_probe_stage or 'unknown'
local lines = { 'stage=' .. stage }
for _, name in ipairs(targets) do
  table.insert(lines, name .. '=' .. tostring(cmds[name] ~= nil))
end
local path = '/tmp/cr-cmd-probe-' .. stage .. '.txt'
vim.fn.writefile(lines, path)
EOF

rm -f /tmp/cr-cmd-probe-before.txt /tmp/cr-cmd-probe-during.txt /tmp/cr-cmd-probe-after.txt

# Stage 1: before any :CodeReview
send_cmd "$SESSION" "let g:cr_probe_stage = 'before'"
send_cmd "$SESSION" "luafile /tmp/cr-cmd-probe.lua"
sleep 1

# Stage 2: during a review
send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2
send_cmd "$SESSION" "let g:cr_probe_stage = 'during'"
send_cmd "$SESSION" "luafile /tmp/cr-cmd-probe.lua"
sleep 1

# Stage 3: after cancel
send_cmd "$SESSION" "CodeReviewCancel"
sleep 1
send_cmd "$SESSION" "let g:cr_probe_stage = 'after'"
send_cmd "$SESSION" "luafile /tmp/cr-cmd-probe.lua"
sleep 1

for stage in before during after; do
  f="/tmp/cr-cmd-probe-${stage}.txt"
  if [ ! -s "$f" ]; then
    echo "FAIL: probe file missing for stage $stage"
    capture_pane "$SESSION"
    exit 1
  fi
  echo "--- $stage ---"
  cat "$f"
  echo "--- end ---"
done

check_field() {
  local stage="$1" name="$2" want="$3"
  local got
  got=$(grep "^${name}=" "/tmp/cr-cmd-probe-${stage}.txt" | cut -d= -f2)
  if [ "$got" != "$want" ]; then
    echo "FAIL: stage=$stage $name expected $want got $got"
    return 1
  fi
}

for name in CodeReviewSubmit CodeReviewCancel CodeReviewPause CodeReviewCopy; do
  check_field before  "$name" false || exit 1
  check_field during  "$name" true  || exit 1
  check_field after   "$name" false || exit 1
done

echo "PASS: session commands appear during review and disappear after cancel"
