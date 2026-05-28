#!/usr/bin/env bash
# Test 14: parse_range produces correct DiffviewOpen args for each range format
# Covers: TST-DIF-0002, TST-DIF-0003, TST-DIF-0004, TST-DIF-0005
# Covers REQ-DIF-0002, REQ-DIF-0003, REQ-DIF-0004, REQ-DIF-0005
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-14"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

cat > /tmp/cr-range-check.lua <<'EOF'
local diff = require('code-review.diff')

local cases = {
  { input = '',           expected = '' },
  { input = 'HEAD~1',     expected = 'HEAD~1^..HEAD~1' },
  { input = 'HEAD~1..HEAD',  expected = 'HEAD~1..HEAD' },
  { input = 'HEAD~1...HEAD', expected = 'HEAD~1...HEAD' },
}

local lines = {}
for _, c in ipairs(cases) do
  local parsed = diff.parse_range(c.input ~= '' and c.input or nil)
  local got = parsed.diffview_args
  local ok = got == c.expected
  table.insert(lines, string.format(
    'input=%q expected=%q got=%q type=%s ok=%s',
    c.input, c.expected, got, tostring(parsed.type), tostring(ok)
  ))
end

vim.fn.writefile(lines, '/tmp/cr-range-check.txt')
EOF

mv /tmp/cr-range-check.txt /tmp/cr-range-check.txt.bak 2>/dev/null || true

start_nvim "$SESSION" "$repo"
send_cmd "$SESSION" "luafile /tmp/cr-range-check.lua"
sleep 1

if [ ! -s /tmp/cr-range-check.txt ]; then
  echo "FAIL: range check file empty"
  capture_pane "$SESSION"
  exit 1
fi

echo "--- check ---"
cat /tmp/cr-range-check.txt
echo "--- end ---"

if grep -q 'ok=false' /tmp/cr-range-check.txt; then
  echo "FAIL: one or more range cases produced wrong diffview_args"
  exit 1
fi

# Sanity check: count lines == 4 cases
n=$(wc -l < /tmp/cr-range-check.txt | tr -d ' ')
if [ "$n" != "4" ]; then
  echo "FAIL: expected 4 cases, got $n"
  exit 1
fi

echo "PASS: parse_range produces correct DiffviewOpen args for all 4 range formats"
