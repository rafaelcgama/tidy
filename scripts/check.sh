#!/bin/bash
# Builds everything and runs the tests, saving the output to build-log.txt so it can be read back.
# Fails when the build or a test fails, so `scripts/check.sh && scripts/make-app.sh` only makes the
# app from code that passes.
cd "$(dirname "$0")/.."
status=0
{
  echo "== $(date)"
  sw_vers 2>/dev/null
  swift --version 2>&1
  echo "== swift build"
  swift build 2>&1 || status=1
  echo "== swift test"
  swift test 2>&1 || status=1
} > build-log.txt 2>&1
grep -E "error:|Build complete|Executed [0-9]+ tests" build-log.txt | tail -20
echo "Full output saved to build-log.txt"
if [ "$status" -ne 0 ]; then
  echo "The build or a test failed, so stop here." >&2
fi
exit "$status"
