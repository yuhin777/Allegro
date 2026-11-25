#!/usr/bin/env bash
set -euo pipefail
project=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$project"
common=(rtl/common/blackwell_async_pkg.sv rtl/tensor_core/blackwell_tc_pkg.sv)
verilator --binary --assert -j "${JOBS:-4}" --Mdir "$work/engine" --top-module mma_engine_tb \
    "${common[@]}" rtl/tmem/blackwell_tmem_pkg.sv rtl/tensor_core/blackwell_tc_mma_engine.sv \
    test/tensor_core/mma_engine_tb.sv
"$work/engine/Vmma_engine_tb"
python3 test/tensor_core/b_loader_vectors.py > "$work/b_vectors.txt"
verilator --binary --assert -j "${JOBS:-4}" --Mdir "$work/loader" --top-module b_loader_tb \
    "${common[@]}" rtl/smem/blackwell_smem_pkg.sv rtl/tensor_core/blackwell_tc_piece_map.sv \
    rtl/tensor_core/blackwell_tc_b_loader.sv test/tensor_core/b_loader_tb.sv
cd "$work"
loader/Vb_loader_tb
loader/Vb_loader_tb +final_error
