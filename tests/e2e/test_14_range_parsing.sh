#!/usr/bin/env bash
# Test 14: parse_range resolves each range format to the right type/base/head
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

-- Each case asserts the resolved (type, base, head) the git-read layer uses.
-- A single revision becomes <rev>^..<rev>; two-dot is a commit range; three-dot
-- is a branch review (base resolves to the merge-base downstream).
local cases = {
  { input = '',              type = 'working_tree', base = nil,      head = nil },
  { input = 'HEAD~1',        type = 'commit_range', base = 'HEAD~1^', head = 'HEAD~1' },
  { input = 'HEAD~1..HEAD',  type = 'commit_range', base = 'HEAD~1',  head = 'HEAD' },
  { input = 'HEAD~1...HEAD', type = 'branch',       base = 'HEAD~1',  head = 'HEAD' },
}

local lines = {}
for _, c in ipairs(cases) do
  local parsed = diff.parse_range(c.input ~= '' and c.input or nil)
  local ok = parsed.type == c.type and parsed.base == c.base and parsed.head == c.head
  table.insert(lines, string.format(
    'input=%q type=%s base=%s head=%s ok=%s',
    c.input, tostring(parsed.type), tostring(parsed.base), tostring(parsed.head), tostring(ok)
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
  echo "FAIL: one or more range cases resolved to the wrong type/base/head"
  exit 1
fi

# Sanity check: count lines == 4 cases
n=$(wc -l < /tmp/cr-range-check.txt | tr -d ' ')
if [ "$n" != "4" ]; then
  echo "FAIL: expected 4 cases, got $n"
  exit 1
fi

echo "PASS: parse_range resolves all 4 range formats to the right type/base/head"
