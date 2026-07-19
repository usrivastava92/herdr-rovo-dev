#!/usr/bin/env bash
#
# Run every tests/*.test.sh. Exits non-zero if any test file fails.
# These tests use a fake `herdr` binary and never contact a real Herdr server.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

status=0
shopt -s nullglob
for t in "$SCRIPT_DIR"/*.test.sh; do
  echo "== $(basename "$t") =="
  if bash "$t"; then
    echo
  else
    status=1
    echo "  ^ test file failed" >&2
    echo
  fi
done

if [ "$status" -eq 0 ]; then
  echo "All tests passed."
else
  echo "Some tests failed." >&2
fi
exit "$status"
