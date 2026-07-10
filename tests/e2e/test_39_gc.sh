#!/usr/bin/env bash
# Test 39: the launcher's garbage collector on the zmx contract. `gc` reaps
# reviews older than CR_GC_MAX_AGE (abandoned by a start that was never waited
# on) -- removing their state/result/sentinel files AND killing their durable
# zmx session -- while leaving a recent in-flight review untouched. Uses an
# isolated CR_REVIEW_DIR so it never touches real reviews. zmx owns its own
# sockets outside the workdir, so there are no socket files to sweep.
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

export CR_REVIEW_DIR=$(mktemp -d -t cr-gcwd39.XXXXXX)
export CR_GC_MAX_AGE=21600 # 6h
export CR_KITTEN_BIN=/usr/bin/true

# Hand-made session names, unique enough to never collide with a real review.
old_session="code-review-gctest-$$-old"
new_session="code-review-gctest-$$-new"

cleanup() {
  "$ZMX" kill "$old_session" --force >/dev/null 2>&1 || true
  "$ZMX" kill "$new_session" --force >/dev/null 2>&1 || true
  rm -rf "$CR_REVIEW_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Real detached sessions stand in for the two reviews, so we can assert gc kills
# the old one and spares the recent one.
"$ZMX" run "$old_session" -d sleep 600 >/dev/null 2>&1
"$ZMX" run "$new_session" -d sleep 600 >/dev/null 2>&1
sleep 1
for s in "$old_session" "$new_session"; do
  if ! "$ZMX" list --short 2>/dev/null | grep -Fxq "$s"; then
    echo "FAIL: could not create test session $s"
    exit 1
  fi
done

# An OLD, abandoned review: started 7h ago (older than the 6h max age).
old="$CR_REVIEW_DIR/review.OLD1"
printf 'started=%s\nsession=%s\n' "$(( $(date +%s) - 7*3600 ))" "$old_session" > "$old.state"
: > "$old"; : > "$old.done"

# A RECENT in-flight review (started now) -- must be left alone.
new="$CR_REVIEW_DIR/review.NEW1"
printf 'started=%s\nsession=%s\n' "$(date +%s)" "$new_session" > "$new.state"
: > "$new"

"$LAUNCH" gc 2>/dev/null

fail=0
if [ -f "$old.state" ] || [ -f "$old" ] || [ -f "$old.done" ]; then
  echo "FAIL: the old abandoned review's files were not reaped"
  fail=1
else
  echo "old abandoned review files reaped (state + result + sentinel): PASS"
fi

if "$ZMX" list --short 2>/dev/null | grep -Fxq "$old_session"; then
  echo "FAIL: the old review's zmx session was not killed"
  fail=1
else
  echo "old review zmx session killed: PASS"
fi

if [ -f "$new.state" ]; then
  echo "recent in-flight review files left untouched: PASS"
else
  echo "FAIL: gc reaped a recent in-flight review's files (race risk)"
  fail=1
fi

if "$ZMX" list --short 2>/dev/null | grep -Fxq "$new_session"; then
  echo "recent review zmx session still alive: PASS"
else
  echo "FAIL: gc killed a recent in-flight review's session"
  fail=1
fi

[ "$fail" = "0" ] || exit 1
echo "PASS: gc reaps orphans by age (files + zmx session), sparing recent reviews"
