#!/usr/bin/env bash
# Compile the physical RTL once for all cocotb workloads. Keeping VPI visibility
# on the driven ports and sampled events avoids reevaluating every internal net
# as a possible asynchronous Python write.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
build=$(mkdir -p "$1" && cd "$1" && pwd)
cd "$repo"
jobs=${JOBS:-8}
if [[ -z ${VERILATOR_ROOT:-} && -d /usr/share/verilator && ! -x /usr/share/verilator/verilator_bin ]]; then
    mkdir -p "$build/toolchain"
    cp -asn /usr/share/verilator/. "$build/toolchain/"
    ln -sf "$(command -v verilator_bin)" "$build/toolchain/verilator_bin"
    export VERILATOR_ROOT="$build/toolchain"
fi
mapfile -t sources < rtl/files.f
sources=("${sources[@]/#/$repo/}")
libs=$(cocotb-config --lib-dir)
verilator --cc --exe --hierarchical --timing --assert --vpi +define+ALLEGRO_TEST_MEMORY_ACK --top-module blackwell_async_subsystem_top \
    --prefix Vtop -o Vtop --timescale 1ns/1ps -Wno-fatal --output-split 12000 \
    --Mdir "$build" -j "$jobs" -LDFLAGS "-Wl,-rpath,$libs -L$libs -lcocotbvpi_verilator" \
    "$repo/test/workloads/model.vlt" "${sources[@]}" "$repo/test/workloads/blackwell_test_memory_ack.sv" "$(cocotb-config --share)/lib/verilator/verilator.cpp"
make -C "$build" -f Vtop_hier.mk -j "$jobs" OPT_FAST="${ALLEGRO_OPT:--O1}" OPT_SLOW=-O0 hier_build
