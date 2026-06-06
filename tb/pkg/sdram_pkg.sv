// ---------------------------------------------------------------------------
// sdram_pkg.sv : the UVM verification package for sdram_lite_ctrl.
// Compile AFTER the interface files (axil_if, mem_req_if, sdram_rst_if) so the
// virtual interface types are visible. Clean-room; no vendor/OpenTitan VIP.
// ---------------------------------------------------------------------------
package sdram_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "sdram_common.svh"
  `include "sdram_axil_agent.svh"
  `include "sdram_mem_req_agent.svh"
  `include "sdram_regmodel.svh"
  `include "sdram_env.svh"
  `include "sdram_sequences.svh"
  `include "sdram_tests.svh"
endpackage
