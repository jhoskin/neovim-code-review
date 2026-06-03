#!/usr/bin/env bash
# Test 32: when the audit trail directory cannot be written, submitting exits
# with code 1. XDG_DATA_HOME points at a temp tree whose code-review/ parent is
# made read-only, so creating the per-project audit dir (and the review file)
# fails.
# Covers: TST-ERR-0004
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-32"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

data_home=$(mktemp -d -t cr-xdg.XXXXXX)
# Pre-create a read-only code-review/ so the per-project <hash> subdir and the
# review file underneath it cannot be created.
mkdir -p "$data_home/nvim/code-review"
chmod 500 "$data_home/nvim/code-review"
# Restore write so the temp tree can be cleaned up by the OS later.
trap 'chmod -R u+w "$data_home" 2>/dev/null || true; cleanup_session "$SESSION"' EXIT

exit_file=$(mktemp -t nvim-exit.XXXXXX)
err_file=$(mktemp -t nvim-err.XXXXXX)

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "XDG_DATA_HOME=$data_home NVIM_CODE_REVIEW_RESULT=/tmp/cr-32-result nvim -u $PLUGIN_ROOT/tests/minimal_init.lua 2> $err_file; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 1

# Submit directly (bypass the confirmation float); the save must fail.
cat > /tmp/cr-32-submit.lua <<'EOF'
require('code-review')._do_submit()
EOF
send_cmd "$SESSION" "luafile /tmp/cr-32-submit.lua"
wait_for_exit "$SESSION" 5 || true

exit_code=$(cat "$exit_file" 2>/dev/null || echo "none")
if [ "$exit_code" != "1" ]; then
  echo "FAIL: expected exit code 1 when audit dir is unwritable, got $exit_code"
  cat "$err_file" 2>/dev/null || true
  exit 1
fi
echo "PASS: unwritable audit dir makes submit exit with code 1"
