SIM ?= verilator
TOPLEVEL_LANG := verilog
ifeq ($(SIM),verilator)
COMPILE_ARGS += --assert
endif
TOPLEVEL := blackwell_smem_subsystem
MODULE ?= smem_subsystem_tests
REPO := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
VERILOG_SOURCES := $(addprefix $(REPO)/,$(shell cat $(REPO)/test/tma/files.f))
export PYTHONPATH := $(REPO)/test/tma:$(PYTHONPATH)
COCOTB_RESULTS_FILE ?= results.xml
.DEFAULT_GOAL := check
.PHONY: check
check: sim
	python3 ../check_results.py "$(COCOTB_RESULTS_FILE)"

include $(shell cocotb-config --makefiles)/Makefile.sim
