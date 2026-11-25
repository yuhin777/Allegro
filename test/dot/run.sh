#!/usr/bin/env bash
# On the RTL verification host, run from any directory.
set -euo pipefail
project=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
python3 "$project/test/dot/reference.py" > vectors.txt
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
verilator --hierarchical --cc --timing --assert --build --Mdir model -j "${JOBS:-4}" \
    --top-module array_tb "$project/test/dot/hierarchy.vlt" "${sources[@]}" "$project/test/dot/array_tb.sv"
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
"${CXX:-c++}" -std=c++17 -pthread -I model -I "${VERILATOR_ROOT:-$verilator_root}/include" -I "${VERILATOR_ROOT:-$verilator_root}/include/vltstd" \
    driver.cpp -Wl,--start-group model/libVarray_tb.a model/libverilated.a -Wl,--end-group -o dot-test
./dot-test
verilator --binary --assert -j "${JOBS:-4}" --Mdir primitives --top-module primitive_tb \
    "${sources[@]}" "$project/test/dot/primitive_tb.sv"
primitives/Vprimitive_tb
