#!/usr/bin/env bash
# On the RTL verification host, run from any directory.
set -euo pipefail
project=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# External golden transactions use the raw-bit layout of reference.py. Supply
# MMA-Sim accumulation cases with matching decode, zero-term and packing rules.
if [[ -n ${MMA_SIM_VECTORS:-} ]]; then
    cat -- "$MMA_SIM_VECTORS" > "$work/numerical.txt"
    echo >> "$work/numerical.txt"
fi
cd "$work"
for phase in numerical throughput latency; do
    python3 "$project/test/dot/reference.py" --phase "$phase" >> "$phase.txt"
done
mapfile -t sources < "$project/test/dot/rtl.f"
sources=("${sources[@]/#/$project/}")
# Debian's split install places the compiler under /usr/bin and its include
# files under /usr/share. Hierarchical child builds expect them under one root.
if [[ -z ${VERILATOR_ROOT:-} && -d /usr/share/verilator && ! -x /usr/share/verilator/verilator_bin ]]; then
    mkdir verilator
    cp -as /usr/share/verilator/. verilator/
    ln -s "$(command -v verilator_bin)" verilator/verilator_bin
    export VERILATOR_ROOT="$work/verilator"
fi
# Link the top harness after building each arithmetic family once.
cat > driver.cpp <<'CPP'
#include "Varray_tb.h"
#include "verilated.h"
int main(int argc, char** argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    Varray_tb top(&context);
    while (!context.gotFinish()) {
        top.eval();
        if (!top.eventsPending()) break;
        context.time(top.nextTimeSlot());
    }
    top.final();
    return context.gotFinish() ? 0 : 1;
}
CPP
verilator_root=$(verilator -V | sed -n 's/^ *VERILATOR_ROOT *= *//p' | head -1)
jobs=${JOBS:-4}
for shared in 1 0; do
    echo "SHARE_FP_DOT_ADDER_TREE=$shared"
    verilator --xml-only --xml-output "array-$shared.xml" --top-module blackwell_tc_dot_array \
        -GSHARE_FP_DOT_ADDER_TREE="1'b$shared" "${sources[@]}"
    python3 "$project/test/dot/check_topology.py" "array-$shared.xml" "$shared"
    mode_flags=()
    if [[ $shared == 0 ]]; then mode_flags+=(+define+TEST_INDEPENDENT_FP_TREES); fi
    # Verilator 5.020 gives each child wrapper and makefile independent make
    # targets with the same recipe. Finish generation before building libraries
    # so parallel targets cannot rewrite files a compiler submake is reading.
    verilator --hierarchical --cc --timing --assert "${mode_flags[@]}" --Mdir "model-$shared" -j "$jobs" \
        --top-module array_tb "$project/test/dot/hierarchy.vlt" "${sources[@]}" "$project/test/dot/array_tb.sv"
    make -C "model-$shared" -f Varray_tb_hier.mk -j "$jobs" hier_build
    "${CXX:-c++}" -std=c++17 -pthread -I "model-$shared" -I "${VERILATOR_ROOT:-$verilator_root}/include" -I "${VERILATOR_ROOT:-$verilator_root}/include/vltstd" \
        driver.cpp -Wl,--start-group "model-$shared/libVarray_tb.a" "model-$shared/libverilated.a" -Wl,--end-group -o dot-test
    ./dot-test
done
for bench in primitive_tb int8_tb; do
    "$project/test/run_sv.sh" "$work" "$project/test/dot/$bench.sv" "${sources[@]}"
done
