SIM ?= verilator
TOPLEVEL_LANG := verilog
TOPLEVEL := blackwell_smem_subsystem
MODULE ?= tensor_transfer
REPO := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
VERILOG_SOURCES := $(addprefix $(REPO)/,$(shell cat $(REPO)/test/tma/files.f))
export PYTHONPATH := $(REPO)/test/tma:$(PYTHONPATH)
include $(shell cocotb-config --makefiles)/Makefile.sim
