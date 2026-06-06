# cocotb + Verilator smoke mirror for sdram_lite_ctrl.
# Usage:
#   make            # run all cocotb tests on Verilator
#   make SEED=7     # change the constrained-random seed
#   make WAVES=1    # also dump a VCD (dump.vcd)
#   make MODULE=tb_smoke TESTCASE=smoke_random   # run one test
#
# Requires: verilator (>=5.x) and cocotb (>=2.0) on PATH.

SIM           ?= verilator
TOPLEVEL_LANG ?= verilog
SEED          ?= 1
export SEED

COCOTB_DIR := $(shell cocotb-config --makefiles)
RTL_DIR    := $(abspath $(shell pwd)/../../rtl)

VERILOG_SOURCES += $(RTL_DIR)/sdram_lite_ctrl.sv
TOPLEVEL := sdram_lite_ctrl
MODULE   ?= tb_smoke

# ASSERT=1 also elaborates the bound SVA under Verilator (subset of SVA) so the
# protocol/timing assertions are live in the mirror -- used by the bug hunt to
# catch timing defects that have no functional (scoreboard) effect.
SVA_DIR := $(abspath $(shell pwd)/../../tb/sva)
ifeq ($(ASSERT),1)
  VERILOG_SOURCES += $(SVA_DIR)/sdram_protocol_sva.sv
  VERILOG_SOURCES += $(SVA_DIR)/sdram_timing_sva.sv
  VERILOG_SOURCES += $(SVA_DIR)/sdram_sva_bind.sv
endif

ifeq ($(SIM),verilator)
  EXTRA_ARGS += -Wno-fatal --timescale 1ns/1ps
  ifeq ($(WAVES),1)
    EXTRA_ARGS += --trace --trace-structs
  endif
  ifeq ($(COVERAGE),1)
    EXTRA_ARGS += --coverage
  endif
  ifeq ($(ASSERT),1)
    EXTRA_ARGS += --assert
  endif
endif

include $(COCOTB_DIR)/Makefile.sim
