#!/usr/bin/env bash
# Execute on the RTX 5080 verification host. Build products stay under build/.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
build=${ALLEGRO_BUILD_DIR:-"$repo/build/regression"}
mkdir -p "$build"
build=$(cd "$build" && pwd)
jobs=${JOBS:-4}
top=blackwell_async_subsystem_top
run_sv() {
    local bench=$1 name output
    name=$(basename "$bench" .sv)
    output="$build/$name"
    verilator --binary --timing --assert -Wno-fatal -j "$jobs" --top-module "$name" \
        --Mdir "$output" -f rtl/files.f "$bench"
    (cd "$output" && "./V$name")
}
check_xml() {
    python3 - "$1" <<'PYTHON'
import sys
from xml.etree.ElementTree import parse
cases = parse(sys.argv[1]).findall(".//testcase")
if not cases or any(case.find(tag) is not None for case in cases for tag in ("error", "failure", "skipped")):
    raise SystemExit(f"Regression results missing, failed or skipped in {sys.argv[1]}")
PYTHON
}
mode=${1:-all}
case "$mode" in lint|unit|workloads|all) ;; *) echo 'usage: test/run.sh [all|lint|unit|workloads]' >&2; exit 2;; esac
if [[ $mode == lint || $mode == all ]]; then
    verilator --lint-only --assert -Wno-fatal --top-module "$top" -f rtl/files.f
fi
if [[ $mode == unit || $mode == all ]]; then
    for bench in test/tc/*_tb.sv test/tmem/tb_*.sv test/tma/*_tb.sv; do
        run_sv "$bench"
    done
    test/tensor_core/run.sh
    test/dot/run.sh
    make -C test/tma SIM_BUILD="$build/tma_cocotb" COCOTB_RESULTS_FILE="$build/tma.xml" BUILD_ARGS="-j$jobs"
    check_xml "$build/tma.xml"
fi
if [[ $mode == workloads || $mode == all ]]; then
    test/workloads/build.sh "$build/workload_top"
    for module in linear_replay commit_order accumulation fa4_timing fa4_replay; do
        make -C test/workloads MODULE="$module" SIM_BUILD="$build/workload_top" \
            COCOTB_RESULTS_FILE="$build/$module.xml"
    done
fi
