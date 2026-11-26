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
mode=${1:-all}
case "$mode" in lint|unit|workloads|all) ;; *) echo 'usage: test/run.sh [all|lint|unit|workloads]' >&2; exit 2;; esac
if [[ $mode == lint || $mode == all ]]; then
    verilator --lint-only --assert -Wno-fatal --top-module "$top" -f rtl/files.f
fi
if [[ $mode == unit || $mode == all ]]; then
    mkdir -p "$build/b_loader_tb"
    python3 test/tensor_core/b_loader_vectors.py > "$build/b_loader_tb/b_vectors.txt"
    for bench in test/{base,tensor_core,tmem,tma}/*_tb.sv; do
        flags=(-f rtl/files.f)
        case "$bench" in
            */b_loader_tb.sv|*/mma_engine_tb.sv) ;;
            *) flags+=(-Wno-fatal) ;;
        esac
        test/run_sv.sh "$build" "$bench" "${flags[@]}"
        if [[ $bench == */b_loader_tb.sv ]]; then
            (cd "$build/b_loader_tb" && ./Vb_loader_tb +final_error)
        fi
    done
    test/dot/run.sh
    make -C test/tma SIM_BUILD="$build/tma_cocotb" COCOTB_RESULTS_FILE="$build/tma.xml" BUILD_ARGS="-j$jobs"
fi
if [[ $mode == workloads || $mode == all ]]; then
    for module in linear_replay commit_order accumulation fa4_timing fa4_replay; do
        make -C test/workloads MODULE="$module" SIM_BUILD="$build/workload_top" \
            COCOTB_RESULTS_FILE="$build/$module.xml"
    done
fi
