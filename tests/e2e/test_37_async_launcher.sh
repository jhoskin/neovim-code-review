#!/usr/bin/env bash
# Test 37: the launcher's async + durable interface. `start` returns a handle
# without blocking; the review runs in a detached tmux session (the durable
# supervisor) that is alive with NO client attached -- i.e. it survives a closed
# tab; `status` reports running (exit 3); `wait` blocks until the review ends and
# reports the outcome; finishing tidies up the session + state.
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
  [ -n "${sock:-}" ] && [ -n "${session:-}" ] && tmux -S "$sock" kill-session -t "$session" 2>/dev/null || true
  [ -n "${handle:-}" ] && rm -f "$handle" "$handle.done" "$handle.state" "${sock:-/nonexistent}" 2>/dev/null || true
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
sock=$(sed -n 's/^sock=//p' "$handle.state")
if [ -z "$sock" ]; then
  echo "FAIL: state file has no explicit tmux socket"
  exit 1
fi
sleep 2

# Durable: the session is alive on its own socket with NO client attached. That
# is exactly the state after a tab close, and it proves a closed tab does not
# kill the review.
if ! tmux -S "$sock" has-session -t "$session" 2>/dev/null; then
  echo "FAIL: durable review session '$session' not alive on socket $sock"
  exit 1
fi
echo "review session durable (alive with no client attached): PASS"

# status while running -> exit 3.
rc=0
"$LAUNCH" status "$handle" >/dev/null 2>&1 || rc=$?
if [ "$rc" != "3" ]; then
  echo "FAIL: status while running should exit 3, got $rc"
  exit 1
fi
echo "status reports running (exit 3): PASS"

# Cancel from inside the durable session; wait should report cancelled (exit 2).
tmux -S "$sock" send-keys -t "$session" Escape; sleep 0.3
tmux -S "$sock" send-keys -t "$session" ":CodeReviewCancel" Enter
rc=0
timeout 20 "$LAUNCH" wait "$handle" >/dev/null 2>&1 || rc=$?
if [ "$rc" != "2" ]; then
  echo "FAIL: wait after cancel should exit 2, got $rc"
  exit 1
fi
echo "wait reports cancelled (exit 2): PASS"

# Completion tidied up: session gone, state file removed.
if tmux -S "$sock" has-session -t "$session" 2>/dev/null; then
  echo "FAIL: tmux session was not cleaned up after the review ended"
  exit 1
fi
if [ -f "$handle.state" ]; then
  echo "FAIL: state file was not cleaned up after the review ended"
  exit 1
fi
echo "completion tidied up the session + state: PASS"

echo "PASS: async durable launcher start/status/wait lifecycle works"
