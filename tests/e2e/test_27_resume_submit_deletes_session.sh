#!/usr/bin/env bash
# Test 27: submitting a resumed session deletes its session file.
# Covers: TST-SES-0005
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-27"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

sessions_root="$HOME/.local/share/nvim/code-review"
marker=$(mktemp -t cr-resume-marker.XXXXXX)
sleep 1

# Interactive mode (no NVIM_CODE_REVIEW_RESULT) so submit does not exit nvim.
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "unset NVIM_CODE_REVIEW_RESULT; nvim -u $PLUGIN_ROOT/tests/minimal_init.lua"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 1

cat > /tmp/cr-resume-comment.lua <<'EOF'
require('code-review')._session.store:add_line_comment('greeting.txt', nil, 5, 'new', 'Resume comment')
EOF
send_cmd "$SESSION" "luafile /tmp/cr-resume-comment.lua"
sleep 1

send_cmd "$SESSION" "CodeReviewPause"
sleep 1.5

session_file=$(find "$sessions_root" -path '*/sessions/*.json' -newer "$marker" 2>/dev/null | head -1)
if [ -z "$session_file" ] || [ ! -f "$session_file" ]; then
  echo "FAIL: no session file written on pause"
  exit 1
fi
session_id=$(jq -r '.session_id' "$session_file")
echo "Paused session: $session_file (id=$session_id)"

# Resume the session by id and submit it (bypass the confirmation float; the
# deletion is what SES-0005 asserts).
cat > /tmp/cr-resume-submit.lua <<EOF
local cr = require('code-review')
cr.start_from_session('$session_id')
cr._do_submit()
EOF
send_cmd "$SESSION" "luafile /tmp/cr-resume-submit.lua"
sleep 1.5

if [ -f "$session_file" ]; then
  echo "FAIL: session file still exists after submitting the resumed session: $session_file"
  exit 1
fi
echo "Session file deleted after submit: PASS"

assert_session_alive "$SESSION"
echo "PASS: submitting a resumed session deletes its session file"
