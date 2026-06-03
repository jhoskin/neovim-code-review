#!/usr/bin/env bash
# Test 37: the launcher's async interface. `start` returns a handle without
# blocking; `status` reports running (exit 3); `wait` blocks until the review
# ends and reports the outcome; finishing tidies up the tmux session + state.
# it2 is stubbed so no real iTerm tab opens during the test.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

LAUNCH="$PLUGIN_ROOT/scripts/interactive-review-launch"

# No-op it2 stub on PATH so `start` does not open a real iTerm2 tab.
stub=$(mktemp -d -t cr-it2-stub.XXXXXX)
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/it2"
chmod +x "$stub/it2"
export PATH="$stub:$PATH"

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"
cd "$repo"

cleanup() {
  [ -n "${session:-}" ] && tmux kill-session -t "$session" 2>/dev/null || true
  [ -n "${handle:-}" ] && rm -f "$handle" "$handle.done" "$handle.state" 2>/dev/null || true
}
trap cleanup EXIT

# start: returns immediately with a handle on stdout.
handle=$("$LAUNCH" start "" 2>/tmp/cr-async-start.err)
if [ -z "$handle" ] || [ ! -f "$handle.state" ]; then
  echo "FAIL: start did not produce a handle + state file (handle='$handle')"
  cat /tmp/cr-async-start.err 2>/dev/null || true
  exit 1
fi
echo "start returned a handle and state: PASS"

session=$(sed -n 's/^session=//p' "$handle.state")
sleep 2
if ! tmux has-session -t "$session" 2>/dev/null; then
  echo "FAIL: review tmux session '$session' not running after start"
  exit 1
fi
echo "review session running: PASS"

# status while running -> exit 3.
rc=0
"$LAUNCH" status "$handle" >/dev/null 2>&1 || rc=$?
if [ "$rc" != "3" ]; then
  echo "FAIL: status while running should exit 3, got $rc"
  exit 1
fi
echo "status reports running (exit 3): PASS"

# Cancel the review; wait should report cancelled (exit 2).
tmux send-keys -t "$session" Escape; sleep 0.3
tmux send-keys -t "$session" ":CodeReviewCancel" Enter
rc=0
timeout 20 "$LAUNCH" wait "$handle" >/dev/null 2>&1 || rc=$?
if [ "$rc" != "2" ]; then
  echo "FAIL: wait after cancel should exit 2, got $rc"
  exit 1
fi
echo "wait reports cancelled (exit 2): PASS"

# wait cleaned up: session gone, state file removed.
if tmux has-session -t "$session" 2>/dev/null; then
  echo "FAIL: tmux session was not cleaned up after the review ended"
  exit 1
fi
if [ -f "$handle.state" ]; then
  echo "FAIL: state file was not cleaned up after the review ended"
  exit 1
fi
echo "completion tidied up the session + state: PASS"

echo "PASS: async launcher start/status/wait lifecycle works"
