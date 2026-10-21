#!/usr/bin/env bash
# shellcheck disable=SC2034 # the variables are read by the code under test (sourced or eval-ed)
# Shared bits for the tests: the repo path, a temp dir removed on exit, PASS/FAIL counters.
# A test file sources this, runs its checks and ends with `finish`.
set -uo pipefail
IFS=$'\n\t'
export LC_ALL=C.UTF-8   # character counts and the Cyrillic check need UTF-8

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
FAILS=0
PASSES=0

ok()  { PASSES=$((PASSES + 1)); [[ -n "${VERBOSE:-}" ]] && echo "  PASS $*"; return 0; }
bad() { FAILS=$((FAILS + 1)); echo "  FAIL $*"; }
section() { echo "-- $*"; }

# check "<description>" <command…> — PASS if the command succeeds.
check() {
    local what="$1"; shift
    if "$@"; then ok "$what"; else bad "$what"; fi
}

finish() {
    echo "   ${PASSES} passed, ${FAILS} failed"
    (( FAILS == 0 ))
}
