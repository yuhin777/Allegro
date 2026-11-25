#!/usr/bin/env bash
# Run representative synthesis checks inside the 5080 ORFS image.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
out=${ALLEGRO_BUILD_DIR:-"$repo/build/regression"}/synthesis
mkdir -p "$out"
tools_dir=/OpenROAD-flow-scripts/tools/install/yosys
run_yosys() {
    docker run --rm -v "$repo:/design:ro" -w /design --entrypoint "$tools_dir/bin/yosys" openroad/orfs:latest \
        -m "$tools_dir/share/yosys/plugins/slang.so" -Q -p "$1"
}
top=blackwell_async_subsystem_top
run_yosys "read_slang --ast-compilation-only -DSYNTHESIS --top $top -f rtl/files.f" >"$out/$top.elaboration.log"
echo "PASS SystemVerilog elaboration $top"
for module in blackwell_fifo blackwell_banked_sram blackwell_tc_async_completion blackwell_tc_completion_tracker blackwell_int8_dot; do
    run_yosys "read_slang -DSYNTHESIS --top $module -f rtl/files.f; synth -top $module; check -assert; stat" >"$out/$module.log"
    echo "PASS synthesis $module"
done
