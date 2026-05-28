#!/usr/bin/env bash
# Test 15: review JSON id matches filename stem and timestamp regex,
# Covers: TST-STO-0002, TST-STO-0007
# diff_spec.base is full 40-char SHA, diff_spec.head is null or full SHA.
# Covers REQ-STO-0002, REQ-STO-0007
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SESSION="cr-test-15"
trap "cleanup_session $SESSION" EXIT

repo=$(bash "$(dirname "$0")/setup_repo.sh")
echo "Test repo: $repo"

result_file=$(mktemp -t nvim-code-review-result.XXXXXX)
rm -f "$result_file"
exit_file=$(mktemp -t nvim-exit.XXXXXX)

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$repo" \
  "NVIM_CODE_REVIEW_RESULT=$result_file nvim -u $PLUGIN_ROOT/tests/minimal_init.lua; echo \$? > $exit_file"
sleep 1.5

send_cmd "$SESSION" "CodeReview"
wait_for "$SESSION" "greeting.txt" 5
sleep 2

# Submit (empty review is fine for ID format checks)
send_cmd "$SESSION" "CodeReviewSubmit"
sleep 1
send_keys "$SESSION" Enter  # confirm summary
wait_for_exit "$SESSION" 5

exit_code=$(cat "$exit_file")
[ "$exit_code" = "0" ] || { echo "FAIL: exit code $exit_code"; exit 1; }

review_path=$(cat "$result_file")
[ -f "$review_path" ] || { echo "FAIL: review file missing"; exit 1; }

# id field
id=$(jq -r '.id' "$review_path")
echo "id=$id"
if ! echo "$id" | grep -Eq '^[0-9]{8}T[0-9]{6}$'; then
  echo "FAIL: id does not match ^[0-9]{8}T[0-9]{6}\$ : $id"
  exit 1
fi
echo "id regex: PASS"

# id == filename stem
stem=$(basename "$review_path" .json)
if [ "$id" != "$stem" ]; then
  echo "FAIL: id ($id) does not equal filename stem ($stem)"
  exit 1
fi
echo "id equals filename stem: PASS"

# diff_spec.base is full 40-char SHA
base=$(jq -r '.diff_spec.base' "$review_path")
echo "base=$base"
if ! echo "$base" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "FAIL: diff_spec.base is not a 40-char SHA: $base"
  exit 1
fi
echo "diff_spec.base full SHA: PASS"

# diff_spec.head should be null (working tree) OR full 40-char SHA
head=$(jq -r '.diff_spec.head' "$review_path")
echo "head=$head"
if [ "$head" = "null" ]; then
  echo "diff_spec.head is null (working tree): PASS"
elif echo "$head" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "diff_spec.head full SHA: PASS"
else
  echo "FAIL: diff_spec.head is neither null nor a 40-char SHA: $head"
  exit 1
fi

echo "PASS: id and diff_spec SHA formats correct"
