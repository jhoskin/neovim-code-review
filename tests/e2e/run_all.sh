#!/usr/bin/env bash
# Run all e2e tests, report pass/fail summary.
set -u
cd "$(dirname "$0")"

PASS=0
FAIL=0
FAILED_TESTS=()

for test in test_*.sh; do
  echo "================================================================"
  echo "Running $test"
  echo "================================================================"
  if bash "$test"; then
    PASS=$((PASS + 1))
    echo ">>> $test PASSED"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$test")
    echo ">>> $test FAILED"
  fi
  echo ""
done

echo "================================================================"
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
echo "All tests passed!"
