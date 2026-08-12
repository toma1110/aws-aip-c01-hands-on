#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export PYTHONPATH="$PWD"
run_expected() {
  local scenario="$1" expected="$2" actual=0
  python -m h4.cli "$scenario" || actual=$?
  if [[ "$actual" -ne "$expected" ]]; then
    echo "unexpected exit: scenario=$scenario expected=$expected actual=$actual" >&2
    exit 1
  fi
}

run_expected baseline 0
run_expected average-pass-critical-fail 2
run_expected warning-only 0
run_expected manual-review 2
run_expected fixed 0
run_expected cleanup 0
python -m unittest discover -s tests -v
