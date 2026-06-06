// Compile filelist for the UVM testbench (paths relative to repo root).
// Use with: <sim> -f tb/sdram.f  (see Makefile UVM targets).
+incdir+tb/pkg

// DUT
rtl/sdram_lite_ctrl.sv

// interfaces (must precede the package: it uses virtual interface types)
tb/if/axil_if.sv
tb/if/mem_req_if.sv
tb/if/sdram_rst_if.sv

// UVM package
tb/pkg/sdram_pkg.sv

// assertions + white-box coverage + binds (after DUT and package)
tb/sva/sdram_protocol_sva.sv
tb/sva/sdram_timing_sva.sv
tb/sva/sdram_cov.sv
tb/sva/sdram_sva_bind.sv
tb/sva/sdram_cov_bind.sv

// top
tb/tb_top.sv
