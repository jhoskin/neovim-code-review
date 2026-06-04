#!/usr/bin/env bash
# Test 38: failure handling. If the durable review session is killed without a
# submit (a crash or forced close, NOT a tab close -- a tab close only detaches),
# `wait` detects the aborted review and returns promptly (exit 2) instead of
# hanging until its timeout. osascript is stubbed so no real Ghostty window opens.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

LAUNCH="$PLUGIN_ROOT/scripts/interactive-review-launch"

stub=$(mktemp -d -t cr-osa-stub.XXXXXX)
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/osascript"
chmod +x "$stub/osascript"
export PATH="$stub:$PATH"

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"
cd "$repo"

cleanup() {
  [ -n "${sock:-}" ] && [ -n "${session:-}" ] && tmux -S "$sock" kill-session -t "$session" 2>/dev/null || true
  [ -n "${handle:-}" ] && rm -f "$handle" "$handle.done" "$handle.state" "${sock:-/nonexistent}" 2>/dev/null || true
}
trap cleanup EXIT

handle=$("$LAUNCH" start "" 2>/dev/null)
[ -n "$handle" ] && [ -f "$handle.state" ] || { echo "FAIL: start failed"; exit 1; }
session=$(sed -n 's/^session=//p' "$handle.state")
sock=$(sed -n 's/^sock=//p' "$handle.state")
sleep 2

# Simulate a crash / forced close: destroy the session with no submit.
tmux -S "$sock" kill-session -t "$session" 2>/dev/null
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

# The whole point: it must NOT hang to the 5-hour ceiling.
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
