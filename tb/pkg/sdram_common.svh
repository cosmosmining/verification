// ---------------------------------------------------------------------------
// sdram_common.svh : shared params, enums, config objects, sequence items.
// Part of sdram_pkg.
// ---------------------------------------------------------------------------

// DUT-matching constants (see docs/dut_spec.md / rtl/sdram_lite_ctrl.sv)
localparam int SDRAM_DATA_W   = 32;
localparam int SDRAM_STRB_W   = 4;
localparam int SDRAM_ADDR_W   = 32;
localparam int SDRAM_AXIL_AW  = 8;
localparam int SDRAM_BANKS    = 4;
localparam int SDRAM_ROW_W    = 4;
localparam int SDRAM_COL_W    = 8;
localparam int SDRAM_IDX_W    = SDRAM_BANKS == 4 ? (2 + SDRAM_ROW_W + SDRAM_COL_W) : 0;
localparam int SDRAM_CAP_WORDS= (1 << SDRAM_IDX_W);   // 16384
localparam int SDRAM_Q_DEPTH  = 8;

// Native response codes
typedef enum bit [1:0] { NRESP_OKAY = 2'b00, NRESP_ERROR = 2'b10 } native_resp_e;
// AXI response codes
typedef enum bit [1:0] { AXI_OKAY = 2'b00, AXI_SLVERR = 2'b10, AXI_DECERR = 2'b11 } axi_resp_e;
// Page outcome (coverage)
typedef enum bit [1:0] { PAGE_HIT, PAGE_MISS, PAGE_CONFLICT } page_e;
// CSR offsets
typedef enum bit [7:0] {
  CSR_CTRL=8'h00, CSR_STATUS=8'h04, CSR_TRCD=8'h08, CSR_TRP=8'h0C,
  CSR_TREF=8'h10, CSR_ERRST=8'h14, CSR_ERRADDR=8'h18, CSR_SCRATCH=8'h1C
} csr_off_e;

// ===========================================================================
// Config objects
// ===========================================================================
class axil_agent_cfg extends uvm_object;
  `uvm_object_utils(axil_agent_cfg)
  virtual axil_if          vif;
  uvm_active_passive_enum  is_active = UVM_ACTIVE;
  function new(string name="axil_agent_cfg"); super.new(name); endfunction
endclass

class mem_req_agent_cfg extends uvm_object;
  `uvm_object_utils(mem_req_agent_cfg)
  virtual mem_req_if       vif;
  uvm_active_passive_enum  is_active = UVM_ACTIVE;
  int unsigned rsp_ready_bp = 20;  // % cycles rsp_ready held low (back-pressure)
  int unsigned req_idle_bp  = 20;  // % cycles an idle gap inserted between requests
  function new(string name="mem_req_agent_cfg"); super.new(name); endfunction
endclass

class sdram_env_cfg extends uvm_object;
  `uvm_object_utils(sdram_env_cfg)
  axil_agent_cfg    axil_cfg;
  mem_req_agent_cfg mem_cfg;
  bit               has_scoreboard = 1;
  bit               has_coverage   = 1;
  function new(string name="sdram_env_cfg");
    super.new(name);
    axil_cfg = axil_agent_cfg::type_id::create("axil_cfg");
    mem_cfg  = mem_req_agent_cfg::type_id::create("mem_cfg");
  endfunction
endclass

// ===========================================================================
// Sequence items
// ===========================================================================
class axil_item extends uvm_sequence_item;
  rand bit                    is_write;
  rand bit [SDRAM_AXIL_AW-1:0] addr;
  rand bit [SDRAM_DATA_W-1:0]  wdata;
  rand bit [SDRAM_STRB_W-1:0]  wstrb;
       bit [SDRAM_DATA_W-1:0]  rdata;   // result
       bit [1:0]               resp;    // result

  constraint c_aligned { addr[1:0] == 2'b00; }
  constraint c_wstrb_def { soft wstrb == 4'hF; }

  `uvm_object_utils_begin(axil_item)
    `uvm_field_int(is_write, UVM_ALL_ON)
    `uvm_field_int(addr,     UVM_ALL_ON)
    `uvm_field_int(wdata,    UVM_ALL_ON)
    `uvm_field_int(wstrb,    UVM_ALL_ON)
    `uvm_field_int(rdata,    UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_field_int(resp,     UVM_ALL_ON | UVM_NOCOMPARE)
  `uvm_object_utils_end
  function new(string name="axil_item"); super.new(name); endfunction
endclass

class mem_req_item extends uvm_sequence_item;
  rand bit                     we;       // 1=write 0=read
  rand bit [SDRAM_ADDR_W-1:0]  addr;     // word address
  rand bit [SDRAM_DATA_W-1:0]  wdata;
  rand bit [SDRAM_STRB_W-1:0]  wstrb;
       bit [SDRAM_DATA_W-1:0]  rdata;    // observed on response
       bit [1:0]               resp;     // observed on response

  // knobs used by sequences
  rand int unsigned oor_pct;             // chance of an out-of-range address
  rand bit          use_hot;             // pick from a locality hot-set

  constraint c_wstrb { we -> wstrb != 0; !we -> wstrb == 0; }
  constraint c_knobs { soft oor_pct == 10; }

  `uvm_object_utils_begin(mem_req_item)
    `uvm_field_int(we,    UVM_ALL_ON)
    `uvm_field_int(addr,  UVM_ALL_ON)
    `uvm_field_int(wdata, UVM_ALL_ON)
    `uvm_field_int(wstrb, UVM_ALL_ON)
    `uvm_field_int(rdata, UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_field_int(resp,  UVM_ALL_ON | UVM_NOCOMPARE)
  `uvm_object_utils_end
  function new(string name="mem_req_item"); super.new(name); endfunction

  function bit is_oor(); return (addr >= SDRAM_CAP_WORDS); endfunction
endclass
