#!/usr/bin/env bash
# Test 23: LSP stop_client uses graceful shutdown (force=false)
# Covers: TST-LSP-0001
#
# Regression test for the "Client X quit with error code 143" notification.
# REQ-LSP-0001 mandates force=false so the LSP exits with code 0 rather
# than SIGTERM (code 143). This test asserts that the code in ui.lua and
# init.lua does not call stop_client with force=true.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Check that ui.lua's stop_lsps uses force=false
if rg -q 'stop_client[^)]*,[[:space:]]*true' "$PLUGIN_ROOT/lua/code-review/ui.lua"; then
  echo "FAIL: ui.lua calls stop_client with force=true (causes SIGTERM/exit 143)"
  rg -n 'stop_client[^)]*,[[:space:]]*true' "$PLUGIN_ROOT/lua/code-review/ui.lua"
  exit 1
fi

# And the same elsewhere in the plugin
if rg -q 'stop_client[^)]*,[[:space:]]*true' "$PLUGIN_ROOT/lua/code-review/"; then
  echo "FAIL: code calls stop_client with force=true somewhere:"
  rg -n 'stop_client[^)]*,[[:space:]]*true' "$PLUGIN_ROOT/lua/code-review/"
  exit 1
fi

# Positive check: at least one graceful stop_client call exists
if ! rg -q 'stop_client[^)]*,[[:space:]]*false' "$PLUGIN_ROOT/lua/code-review/ui.lua"; then
  echo "FAIL: ui.lua should call stop_client with force=false at least once"
  exit 1
fi

echo "PASS: all stop_client calls use force=false (graceful LSP shutdown)"
