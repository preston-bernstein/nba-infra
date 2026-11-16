#!/usr/bin/env bash
# Run every gate in order. CI and the pre-commit hook both call this script, so they never differ.
#   run-gates.sh
# The writing gate lints only the files that changed against main. Set WRITING_ALL=1 to lint every file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run() {
  echo "== $*" >&2
  "$@"
}

main() {
  run bash scripts/core-validate.sh
  run bash scripts/gha-validate.sh
  run bash scripts/shell-validate.sh
  run bash scripts/docker-validate.sh
  run bash scripts/writing-validate.sh
  run python3 -I scripts/logging-check.py .
  echo "run-gates: all gates passed"
}

main "$@"
