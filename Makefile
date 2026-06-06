# ===========================================================================
# sdram_lite_ctrl - top-level Makefile
#
#   make smoke                 cocotb + Verilator scoreboard mirror (license-free)
#   make lint                  Verilator lint of RTL + bound SVA
#   make uvm SIM=<sim> UVM_TEST=<test> [SEED=n] [VERB=UVM_LOW] [WAVES=1]
#       SIM = dsim | xsim | questa | vcs | xcelium
#       Default local SIM is one that runs license-free: dsim (Metrics DSim
#       Desktop) or xsim (AMD Vivado). VCS/Questa/Xcelium for the campus run.
#   make regress [SEEDS=...] [JOBS=n] [UVM_TEST=...]   parallel-seed regression
#   make clean
# ===========================================================================

SIM      ?= dsim
UVM_TEST ?= sdram_random_test
SEED     ?= 1
VERB     ?= UVM_MEDIUM
TOP      ?= tb_top
FILELIST ?= tb/sdram.f

ROOT := $(abspath $(CURDIR))

# ---- wave switches per simulator (enabled with WAVES=1) ----
ifeq ($(WAVES),1)
  WAVE_PLUS := +WAVES
endif

.PHONY: smoke lint uvm regress clean help

help:
	@sed -n '2,20p' Makefile

# --------------------------------------------------------------- smoke (here)
smoke:
	$(MAKE) -C sim/cocotb SEED=$(SEED) $(if $(WAVES),WAVES=1,)

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL --timing \
	  rtl/sdram_lite_ctrl.sv
	verilator --lint-only --timing --assert -Wno-fatal -Wno-WIDTH \
	  -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-UNUSEDPARAM --top-module sdram_lite_ctrl \
	  rtl/sdram_lite_ctrl.sv tb/sva/sdram_protocol_sva.sv tb/sva/sdram_timing_sva.sv \
	  tb/sva/sdram_sva_bind.sv

# ----------------------------------------------------------------- UVM run
# Single dispatch on SIM. Each recipe is the documented campus/local command.
uvm:
	@echo ">> UVM run: SIM=$(SIM) TEST=$(UVM_TEST) SEED=$(SEED)"
ifeq ($(SIM),dsim)
	dsim -uvm 1.2 -f $(FILELIST) -top $(TOP) -sv_seed $(SEED) \
	  +UVM_TESTNAME=$(UVM_TEST) +UVM_VERBOSITY=$(VERB) $(WAVE_PLUS)
else ifeq ($(SIM),xsim)
	xvlog -sv -L uvm -f $(FILELIST)
	xelab -L uvm -timescale 1ns/1ps --debug typical $(TOP) -s $(TOP)_sim
	xsim $(TOP)_sim -R --testplusarg "UVM_TESTNAME=$(UVM_TEST)" \
	  --testplusarg "UVM_VERBOSITY=$(VERB)" -sv_seed $(SEED)
else ifeq ($(SIM),questa)
	qrun -64 -uvm -sv -mfcu -f $(FILELIST) -top $(TOP) -sv_seed $(SEED) \
	  +UVM_TESTNAME=$(UVM_TEST) +UVM_VERBOSITY=$(VERB) $(WAVE_PLUS)
else ifeq ($(SIM),vcs)
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -f $(FILELIST) \
	  -top $(TOP) -l comp.log -o simv
	./simv +UVM_TESTNAME=$(UVM_TEST) +UVM_VERBOSITY=$(VERB) +ntb_random_seed=$(SEED) $(WAVE_PLUS)
else ifeq ($(SIM),xcelium)
	xrun -64 -uvm -uvmhome CDNS-1.2 -sv -f $(FILELIST) -top $(TOP) -svseed $(SEED) \
	  +UVM_TESTNAME=$(UVM_TEST) +UVM_VERBOSITY=$(VERB) $(WAVE_PLUS)
else
	@echo "Unknown SIM='$(SIM)'. Use dsim|xsim|questa|vcs|xcelium." && false
endif

# ----------------------------------------------------------- parallel regression
regress:
	python3 scripts/regress.py --uvm-test $(UVM_TEST) $(if $(SEEDS),--seeds $(SEEDS),) \
	  $(if $(JOBS),--jobs $(JOBS),) --sim $(SIM)

clean:
	$(MAKE) -C sim/cocotb clean || true
	rm -rf simv simv.daidir csrc *.log work transcript xsim.dir *.jou \
	       dsim_work metrics.db waves.vcd regression_out obj_dir
