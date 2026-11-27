#!/usr/bin/env bash
# Reuse the Verilator binary built by test/tma/Makefile with --assert.
set -euo pipefail
build=$(cd "${1:?usage: run_assertions.sh SIM_BUILD}" && pwd)
tests=$(cd "$(dirname "$0")" && pwd)
export MODULE=tma_assertions TOPLEVEL=blackwell_smem_subsystem TOPLEVEL_LANG=verilog
export PYTHONPATH="$tests${PYTHONPATH:+:$PYTHONPATH}"
LIBPYTHON_LOC=$(cocotb-config --libpython)
export LIBPYTHON_LOC
ulimit -c 0

check() {
    local scenario=$1 marker=$2 log="$build/$1.log"
    if TESTCASE="$scenario" COCOTB_RESULTS_FILE="$build/$scenario.xml" "$build/Vtop" >"$log" 2>&1; then
        echo "Expected $marker in $scenario" >&2
        return 1
    fi
    if ! grep -Fq -- "$marker" "$log"; then
        cat "$log" >&2
        return 1
    fi
    echo "PASS $scenario ($marker)"
}

check reserved_opcode TMA_CMD_OPCODE
check misaligned_map TMA_MAP_ALIGNMENT
check unsolicited_descriptor_return TMA_DESC_RETURN
check unsolicited_data_return TMA_DATA_RETURN
check malformed_descriptor TMA_MAP_FORMAT
check expanded_smem_overflow TMA_SMEM_SPAN
check expanded_gmem_overflow TMA_GMEM_SPAN
