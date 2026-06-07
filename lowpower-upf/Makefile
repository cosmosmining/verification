# ===========================================================================
# cocotb + Icarus Verilog (4-state) power-aware sim for pg_top.
#
#   make                       # run the isolation/retention scoreboard
#   make SEED=7 CYCLES=10      # more / different sleep-wake cycles
#   make BUG=PG_BUG_ISO        # inject a power-gating fault (expect FAIL)
#   bash bugs/run_bug_demo.sh  # full injected-fault campaign -> bugs/BUGS.md
#
# Icarus (not Verilator) on purpose: isolation is an X-propagation property and
# needs a 4-state simulator. Requires: iverilog, cocotb 1.9.x.
# ===========================================================================
SIM           ?= icarus
TOPLEVEL_LANG ?= verilog
SEED          ?= 1
CYCLES        ?= 6
export SEED CYCLES

COCOTB_DIR := $(shell cocotb-config --makefiles)
TOPLEVEL   := pg_top
MODULE     ?= test_pg
export PYTHONPATH := $(abspath tb):$(PYTHONPATH)
export PYTHONIOENCODING := utf-8

VERILOG_SOURCES += $(abspath rtl/pg_top.sv)
VERILOG_SOURCES += $(abspath rtl/pg_pmu.sv)
VERILOG_SOURCES += $(abspath rtl/pg_counter.sv)

COMPILE_ARGS += -g2012
ifdef BUG
  COMPILE_ARGS += -D$(BUG)
endif

include $(COCOTB_DIR)/Makefile.sim
