#!/usr/bin/env bash
# Test 37: the launcher's async + durable interface, on the zmx contract.
# `start` returns a handle without blocking; the review runs in a detached zmx
# session (the durable supervisor) that survives a closed kitty tab -- a tab
# close only detaches the client; `status` reports running (exit 3); a cancel
# driven into the session makes `wait` return cancelled (exit 2); finishing
# tidies up the session + state/sentinel files.
# CR_KITTEN_BIN=/usr/bin/true so no real kitty tab opens during the test.
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

# Isolated workdir + no real kitty tab.
export CR_REVIEW_DIR=$(mktemp -d -t cr-async37.XXXXXX)
export CR_KITTEN_BIN=/usr/bin/true

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"
cd "$repo"

cleanup() {
  [ -n "${session:-}" ] && "$ZMX" kill "$session" --force >/dev/null 2>&1 || true
  rm -rf "$CR_REVIEW_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# start: returns immediately with a handle on stdout.
handle=$("$LAUNCH" start "" 2>/tmp/cr-async-start.err) \
  || { echo "FAIL: start command failed"; cat /tmp/cr-async-start.err 2>/dev/null || true; exit 1; }
if [ -z "$handle" ] || [ ! -f "$handle.state" ]; then
  echo "FAIL: start did not produce a handle + state file (handle='$handle')"
  cat /tmp/cr-async-start.err 2>/dev/null || true
  exit 1
fi
echo "start returned a handle and state: PASS"

session=$(sed -n 's/^session=//p' "$handle.state")
started=$(sed -n 's/^started=//p' "$handle.state")
if [ -z "$session" ]; then
  echo "FAIL: state file has no session= field"
  exit 1
fi
if [ -z "$started" ]; then
  echo "FAIL: state file has no started= field"
  exit 1
fi
# The state format changed with the zmx migration: there is no socket any more.
if grep -q '^sock=' "$handle.state"; then
  echo "FAIL: state file still carries a sock= field (obsolete tmux contract)"
  exit 1
fi
echo "state file has session= and started=, no sock=: PASS"

sleep 2

# Durable: the review runs in a detached zmx session, checked the same way the
# launcher checks liveness (zmx list --short | grep -Fxq).
if ! "$ZMX" list --short 2>/dev/null | grep -Fxq "$session"; then
  echo "FAIL: durable review session '$session' not alive in zmx list"
  exit 1
fi
echo "review session durable (alive as a detached zmx session): PASS"

# status while running -> exit 3.
rc=0
"$LAUNCH" status "$handle" >/dev/null 2>&1 || rc=$?
if [ "$rc" != "3" ]; then
  echo "FAIL: status while running should exit 3, got $rc"
  exit 1
fi
echo "status reports running (exit 3): PASS"

# Cancel from inside the durable session (Escape, then :CodeReviewCancel<CR>,
# mirroring the old tmux send-keys sequence); wait should report cancelled.
printf '\033' | "$ZMX" send "$session" >/dev/null 2>&1 || true
sleep 0.3
printf ':CodeReviewCancel\r' | "$ZMX" send "$session" >/dev/null 2>&1 || true
rc=0
timeout 20 "$LAUNCH" wait "$handle" >/dev/null 2>&1 || rc=$?
if [ "$rc" != "2" ]; then
  echo "FAIL: wait after cancel should exit 2, got $rc"
  exit 1
fi
echo "wait reports cancelled (exit 2): PASS"

# Completion tidied up: session gone from zmx, state file removed.
if "$ZMX" list --short 2>/dev/null | grep -Fxq "$session"; then
  echo "FAIL: zmx session was not cleaned up after the review ended"
  exit 1
fi
if [ -f "$handle.state" ]; then
  echo "FAIL: state file was not cleaned up after the review ended"
  exit 1
fi
echo "completion tidied up the session + state: PASS"

echo "PASS: async durable launcher start/status/wait lifecycle works (zmx)"
