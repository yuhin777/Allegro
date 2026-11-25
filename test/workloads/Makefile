# Use the same hierarchical model and narrow VPI probes for every workload.
REPO := $(abspath ../..)
MODULE ?= fa4_replay
SIM_BUILD ?= $(REPO)/build/regression/workload_top
COCOTB_RESULTS_FILE ?= $(CURDIR)/results.xml
export MODULE TESTCASE COCOTB_RESULTS_FILE
export TOPLEVEL := blackwell_async_subsystem_top
export TOPLEVEL_LANG := verilog
export PYTHONPATH := $(CURDIR):$(PYTHONPATH)
export LIBPYTHON_LOC := $(shell cocotb-config --libpython)

.PHONY: sim
sim: $(SIM_BUILD)/Vtop
	$(RM) "$(COCOTB_RESULTS_FILE)"
	"$<"
	python3 -c 'import os, xml.etree.ElementTree as E; cases=E.parse(os.environ["COCOTB_RESULTS_FILE"]).findall(".//testcase"); assert cases and all(c.find(t) is None for c in cases for t in ("error","failure","skipped"))'

$(SIM_BUILD)/Vtop: $(addprefix $(REPO)/,$(shell cat $(REPO)/rtl/files.f)) build.sh model.vlt blackwell_test_memory_ack.sv
	./build.sh "$(SIM_BUILD)"
