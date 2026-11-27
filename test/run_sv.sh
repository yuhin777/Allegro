#!/usr/bin/env bash
# Build an ordinary self-checking bench and run it in its build directory.
set -euo pipefail
build=$1
bench=$2
shift 2
top=$(basename "$bench" .sv)
output="$build/$top"
verilator --binary --timing --assert -j "${JOBS:-4}" --top-module "$top" \
    --Mdir "$output" "$@" "$bench"
(cd "$output" && "./V$top")
