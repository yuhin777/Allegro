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
# Each negative case must stop at its designated simulation assertion.
expect_assertion() {
    local bench=$1 scenario=$2 marker=$3 log="$build/$1/$2.log"
    if (cd "$build/$bench" && ulimit -c 0 && "./V$bench" "+$scenario") >"$log" 2>&1; then
        echo "Expected assertion $marker in $bench +$scenario" >&2
        return 1
    fi
    if ! grep -Fq -- "$marker" "$log"; then
        cat "$log" >&2
        return 1
    fi
    echo "PASS $bench +$scenario ($marker)"
}
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
        case "$bench" in
            */b_loader_tb.sv) expect_assertion b_loader_tb bad_return TC_B_RETURN ;;
            */scale_tb.sv) expect_assertion scale_tb upper_lane TC_SCALE_B_RETURN_LANE ;;
            */tmem_a_tb.sv) expect_assertion tmem_a_tb wrong_lane TC_A_TMEM_RETURN ;;
            */tmem_control_tb.sv) expect_assertion tmem_control_tb dealloc_pinned TMEM_DEALLOC_LIFETIME ;;
            */tmem_rf_tb.sv)
                expect_assertion tmem_rf_tb bad_range TMEM_RF_ISSUE
                expect_assertion tmem_rf_tb wrong_ack TMEM_STORE_ACK ;;
            */completion_tb.sv)
                expect_assertion completion_tb duplicate_done TC_TRACKER_DONE
                expect_assertion completion_tb unsolicited_bar_rsp TC_BRIDGE_RSP ;;
        esac
    done
    test/dot/run.sh
    make -C test/tma SIM_BUILD="$build/tma_cocotb" COCOTB_RESULTS_FILE="$build/tma.xml" BUILD_ARGS="-j$jobs"
    test/tma/run_assertions.sh "$build/tma_cocotb"
fi
if [[ $mode == workloads || $mode == all ]]; then
    for module in linear_replay commit_order accumulation fa4_timing fa4_replay; do
        make -C test/workloads MODULE="$module" SIM_BUILD="$build/workload_top" \
            COCOTB_RESULTS_FILE="$build/$module.xml"
    done
    for scenario in non_ok_memory non_ok_ordering; do
        case "$scenario" in
            non_ok_memory) marker="TMA GMEM response status must be OK" ;;
            non_ok_ordering) marker="Invalid ordering response" ;;
        esac
        log="$build/$scenario.log"
        if (ulimit -c 0 && make -C test/workloads MODULE=service_assertions TESTCASE="$scenario" \
                SIM_BUILD="$build/workload_top" COCOTB_RESULTS_FILE="$build/$scenario.xml") >"$log" 2>&1; then
            echo "Expected assertion in $scenario" >&2
            exit 1
        fi
        grep -F -- "$marker" "$log" || { cat "$log" >&2; exit 1; }
    done
fi
