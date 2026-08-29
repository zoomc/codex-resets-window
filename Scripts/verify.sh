#!/usr/bin/env bash
#
# The regression gate. Run this before every commit and before packaging.
#
#   Scripts/verify.sh            build + self-test + sandbox integration
#   Scripts/verify.sh --live     also run the live end-to-end test (uses real quota)
#
# This toolchain ships no XCTest, so `--selftest` is the unit layer; sandbox-test.sh is the
# integration layer; live-test.sh is the acceptance layer.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_LIVE=0
for arg in "$@"; do [[ "$arg" == "--live" ]] && RUN_LIVE=1; done

printf '\033[1m1/3  build\033[0m\n'
if swift build -c release --disable-sandbox 2>&1 | tail -3; then :; else
  printf '\033[31mbuild failed\033[0m\n'; exit 1
fi

printf '\n\033[1m2/3  self-test (in-process unit layer)\033[0m\n'
if ./.build/release/CodexResetsWindow --selftest; then :; else
  printf '\033[31mself-test failed\033[0m\n'; exit 1
fi

printf '\n\033[1m3/3  sandbox integration\033[0m\n'
if Scripts/sandbox-test.sh; then
  printf '\n\033[32m✓ all checks passed\033[0m\n'
else
  printf '\n\033[31m✗ sandbox integration failed\033[0m\n'; exit 1
fi

if [[ $RUN_LIVE -eq 1 ]]; then
  printf '\n\033[1m4/4  live end-to-end (real Codex, cheapest model)\033[0m\n'
  if Scripts/live-test.sh; then
    printf '\n\033[32m✓ live test passed\033[0m\n'
  else
    printf '\n\033[31m✗ live test failed\033[0m\n'; exit 1
  fi
fi
