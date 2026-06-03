#!/usr/bin/env bash
# Test 31: on Neovim < 0.10, :CodeReview exits with code 1 and the stderr
# diagnostic names the minimum version. The version check is mocked by
# overriding vim.fn.has('nvim-0.10').
# Covers: TST-ERR-0006
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-31"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

cat > /tmp/cr-oldver-init.lua <<EOF
vim.opt.runtimepath:prepend("$PLUGIN_ROOT")
vim.opt.swapfile = false
vim.opt.backup = false
vim.g.mapleader = " "
-- Pretend Neovim is older than 0.10; delegate every other feature query.
local orig_has = vim.fn.has
vim.fn.has = function(x)
  if x == "nvim-0.10" then
    return 0
  end
  return orig_has(x)
end
require("code-review").setup({})
EOF

exit_file=$(mktemp -t nvim-exit.XXXXXX)
err_file=$(mktemp -t nvim-err.XXXXXX)

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "NVIM_CODE_REVIEW_RESULT=/tmp/cr-31-result nvim -u /tmp/cr-oldver-init.lua 2> $err_file; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for_exit "$SESSION" 5 || true

exit_code=$(cat "$exit_file" 2>/dev/null || echo "none")
if [ "$exit_code" != "1" ]; then
  echo "FAIL: expected exit code 1 on old Neovim, got $exit_code"
  cat "$err_file" 2>/dev/null || true
  exit 1
fi
echo "Exit code 1: PASS"

if ! grep -qi "0.10" "$err_file" 2>/dev/null; then
  echo "FAIL: stderr diagnostic does not name the minimum version 0.10"
  echo "--- stderr ---"; cat "$err_file" 2>/dev/null || true
  exit 1
fi
echo "PASS: old Neovim exits 1 with a version diagnostic"
