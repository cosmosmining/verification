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

ifeq ($(SIM),verilator)
  EXTRA_ARGS += -Wno-fatal --timescale 1ns/1ps
  ifeq ($(WAVES),1)
    EXTRA_ARGS += --trace --trace-structs
  endif
endif

include $(COCOTB_DIR)/Makefile.sim
