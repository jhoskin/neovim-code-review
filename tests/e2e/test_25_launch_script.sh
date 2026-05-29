#!/usr/bin/env bash
# Test 25: bundled scripts/interactive-review-launch exists, is executable, and rejects unsafe input
# Covers: script integrity (no spec REQ — it's a wrapper, not part of plugin behavior)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

script="$PLUGIN_ROOT/scripts/interactive-review-launch"

if [ ! -f "$script" ]; then
  echo "FAIL: launch script not found at $script"
  exit 1
fi
echo "Script exists: PASS"

if [ ! -x "$script" ]; then
  echo "FAIL: launch script is not executable"
  exit 1
fi
echo "Script executable: PASS"

# Each guard case should be rejected with exit 1 and a diagnostic on stderr
for unsafe in 'foo|bar' 'foo"bar' 'foo\bar' $'foo\nbar'; do
  rc=0
  output=$("$script" "$unsafe" 2>&1) || rc=$?
  if [ "$rc" = "0" ]; then
    echo "FAIL: script accepted unsafe input '$unsafe' (should reject)"
    exit 1
  fi
  if [ "$rc" != "1" ]; then
    echo "FAIL: unsafe input '$unsafe' exited $rc, expected 1"
    exit 1
  fi
  if ! echo "$output" | grep -q "refusing unsafe argument"; then
    echo "FAIL: unsafe input '$unsafe' did not produce expected diagnostic"
    echo "  stderr: $output"
    exit 1
  fi
done
echo "Rejects unsafe inputs (|, \", \\, newline): PASS"

echo "PASS: scripts/interactive-review-launch is well-formed"
