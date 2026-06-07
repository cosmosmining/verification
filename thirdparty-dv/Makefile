# ===========================================================================
# cocotb + Verilator DV env for a THIRD-PARTY AXI4-Lite crossbar (verilog-axi).
#
#   ./setup.sh                 # once: fetch verilog-axi + generate 2x2 wrapper
#   make                       # run the scoreboard tests on Verilator
#   make SEED=7 N=500          # change random seed / op count
#   make WAVES=1               # also dump dump.vcd
#   make MODULE=test_axil_crossbar_dv TESTCASE=random_traffic   # one test
#
# Requires: verilator, cocotb 1.9.x, cocotbext-axi (see requirements.txt).
# ===========================================================================
SIM           ?= verilator
TOPLEVEL_LANG ?= verilog
SEED          ?= 1
N             ?= 200
export SEED N

COCOTB_DIR := $(shell cocotb-config --makefiles)
WORK       := $(abspath work)
RTL        := $(WORK)/verilog-axi/rtl

TOPLEVEL := axil_crossbar_wrap_2x2
MODULE   ?= test_axil_crossbar_dv
export PYTHONPATH := $(abspath tb):$(PYTHONPATH)

VERILOG_SOURCES += $(WORK)/axil_crossbar_wrap_2x2.v
VERILOG_SOURCES += $(RTL)/axil_crossbar.v
VERILOG_SOURCES += $(RTL)/axil_crossbar_wr.v
VERILOG_SOURCES += $(RTL)/axil_crossbar_rd.v
VERILOG_SOURCES += $(RTL)/axil_crossbar_addr.v
VERILOG_SOURCES += $(RTL)/axil_register_rd.v
VERILOG_SOURCES += $(RTL)/axil_register_wr.v
VERILOG_SOURCES += $(RTL)/arbiter.v
VERILOG_SOURCES += $(RTL)/priority_encoder.v

ifeq ($(SIM),verilator)
  EXTRA_ARGS += -Wno-fatal --timescale 1ns/1ps
  ifeq ($(WAVES),1)
    EXTRA_ARGS += --trace --trace-structs
  endif
endif
ifeq ($(wildcard $(WORK)/axil_crossbar_wrap_2x2.v),)
  $(error Missing generated sources — run ./setup.sh first)
endif

include $(COCOTB_DIR)/Makefile.sim
