#!/usr/bin/env bash
# Test 39: the launcher's garbage collector. `gc` reaps reviews older than
# CR_GC_MAX_AGE (abandoned by a start that was never waited on) and removes dead
# sockets, while leaving a recent in-flight review untouched. Uses an isolated
# CR_REVIEW_DIR so it never touches real reviews. No tmux/it2 needed.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

LAUNCH="$PLUGIN_ROOT/scripts/interactive-review-launch"

export CR_REVIEW_DIR=$(mktemp -d -t cr-gcwd.XXXXXX)

# An OLD, abandoned review (started in 1970) with its files + socket.
old="$CR_REVIEW_DIR/review.OLD1"
printf 'started=1\nsession=code-review-review-OLD1\nsock=%s/old.sock\n' "$CR_REVIEW_DIR" > "$old.state"
: > "$old"; : > "$old.done"; : > "$CR_REVIEW_DIR/old.sock"

# A stray dead socket with no live server.
: > "$CR_REVIEW_DIR/stray.sock"

# A RECENT in-flight review (started now) -- must be left alone.
new="$CR_REVIEW_DIR/review.NEW1"
printf 'started=%s\nsession=code-review-review-NEW1\nsock=%s/new.sock\n' "$(date +%s)" "$CR_REVIEW_DIR" > "$new.state"
: > "$new"

"$LAUNCH" gc 2>/dev/null

fail=0
if [ -f "$old.state" ] || [ -f "$old" ] || [ -f "$old.done" ] || [ -e "$CR_REVIEW_DIR/old.sock" ]; then
  echo "FAIL: the old abandoned review was not fully reaped"
  fail=1
else
  echo "old abandoned review reaped (state + result + sentinel + socket): PASS"
fi

if [ -e "$CR_REVIEW_DIR/stray.sock" ]; then
  echo "FAIL: stray dead socket not removed"
  fail=1
else
  echo "stray dead socket removed: PASS"
fi

if [ -f "$new.state" ]; then
  echo "recent in-flight review left untouched: PASS"
else
  echo "FAIL: gc reaped a recent in-flight review (race risk)"
  fail=1
fi

[ "$fail" = "0" ] || exit 1
echo "PASS: gc reaps orphans by age and removes dead sockets, sparing recent reviews"
