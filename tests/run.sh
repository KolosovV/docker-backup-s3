#!/usr/bin/env bash
# Runs every tests/test_*.sh. No Docker, no S3, no network: curl is replaced by a stub.
# Needs: bash 4+, jq, python3, tar, gzip, base64, sed (GNU).
# usage: tests/run.sh [-v] [name…]   (-v prints every PASS; name = test_notify, notify, …)
set -uo pipefail
IFS=$'\n\t'
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2

[[ "${1:-}" == "-v" ]] && { export VERBOSE=1; shift; }

missing=""
for c in jq python3 tar gzip base64 sed; do
    command -v "$c" >/dev/null 2>&1 || missing+=" $c"
done
[[ -n "$missing" ]] && { echo "Missing:${missing}" >&2; exit 2; }

declare -a files=()
if (( $# )); then
    for n in "$@"; do n="${n#test_}"; n="${n%.sh}"; files+=("test_${n}.sh"); done
else
    for f in test_*.sh; do files+=("$f"); done
fi

failed=0
for f in "${files[@]}"; do
    echo "== ${f}"
    bash "$f" || failed=$((failed + 1))
done
echo
if (( failed )); then echo "FAILED: ${failed} of ${#files[@]} test files"; exit 1; fi
echo "OK: ${#files[@]} test files"
