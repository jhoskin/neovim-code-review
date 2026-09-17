#!/usr/bin/env bash
# Test 38: failure handling on the zmx contract. If the durable review session
# is killed without a submit (a crash or forced kill, NOT a window close -- a
# window close only detaches the client), `wait` detects the aborted review and returns
# promptly (exit 2) instead of hanging until its timeout.
# CR_KITTEN_BIN=/usr/bin/true so no real kitty window opens during the test.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

LAUNCH="$PLUGIN_ROOT/scripts/interactive-review-launch"

# Resolve the zmx binary exactly as the launcher does; fail fast if absent.
ZMX="${CR_ZMX_BIN:-/opt/homebrew/bin/zmx}"
if [ ! -x "$ZMX" ]; then
  echo "FAIL: zmx binary not found at $ZMX (set CR_ZMX_BIN)"
  exit 1
fi

# A user-level session prefix would skew the session names; neutralise it.
unset ZMX_SESSION_PREFIX

# Isolated workdir + no real kitty window.
export CR_REVIEW_DIR=$(mktemp -d -t cr-async38.XXXXXX)
export CR_KITTEN_BIN=/usr/bin/true

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"
cd "$repo"

cleanup() {
  [ -n "${session:-}" ] && "$ZMX" kill "$session" --force >/dev/null 2>&1 || true
  rm -rf "$CR_REVIEW_DIR" 2>/dev/null || true
}
trap cleanup EXIT

handle=$("$LAUNCH" start "" 2>/dev/null) || { echo "FAIL: start command failed"; exit 1; }
[ -n "$handle" ] && [ -f "$handle.state" ] || { echo "FAIL: start did not produce a handle + state"; exit 1; }
session=$(sed -n 's/^session=//p' "$handle.state")
[ -n "$session" ] || { echo "FAIL: state file has no session= field"; exit 1; }
sleep 2

# Simulate a crash / forced kill: destroy the session with no submit.
"$ZMX" kill "$session" --force >/dev/null 2>&1 || true
echo "killed the session without submitting"

start=$(date +%s)
rc=0
timeout 20 "$LAUNCH" wait "$handle" >/tmp/cr-abort.out 2>&1 || rc=$?
elapsed=$(( $(date +%s) - start ))

if [ "$rc" != "2" ]; then
  echo "FAIL: wait on an aborted review should exit 2, got $rc"
  cat /tmp/cr-abort.out 2>/dev/null || true
  exit 1
fi
echo "wait reports aborted (exit 2): PASS"

# The whole point: it must NOT hang to the wait ceiling.
if [ "$elapsed" -gt 8 ]; then
  echo "FAIL: wait took ${elapsed}s on an aborted review (should return promptly, not hang)"
  exit 1
fi
echo "wait returned promptly (${elapsed}s, not a hang): PASS"

if ! grep -qi "abort" /tmp/cr-abort.out 2>/dev/null; then
  echo "FAIL: no 'aborted' diagnostic; got: $(cat /tmp/cr-abort.out)"
  exit 1
fi
echo "PASS: an aborted review is detected promptly instead of hanging"
