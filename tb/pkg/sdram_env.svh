// ---------------------------------------------------------------------------
// sdram_env.svh : reference model, scoreboard, coverage, vseqr, env.
// Part of sdram_pkg.
// ---------------------------------------------------------------------------

`uvm_analysis_imp_decl(_req)
`uvm_analysis_imp_decl(_rsp)

// ============================================================ reference model
// Untimed prediction of read data + response code. Mirrors sim/cocotb/sdram_ref.py.
class sdram_ref_model extends uvm_object;
  `uvm_object_utils(sdram_ref_model)
  bit [SDRAM_DATA_W-1:0] mem [int];   // sparse backing store
  function new(string name="sdram_ref_model"); super.new(name); endfunction

  function void predict(input mem_req_item req,
                        output bit [1:0] resp, output bit [SDRAM_DATA_W-1:0] rdata);
    int idx;
    rdata = '0;
    if (req.addr >= SDRAM_CAP_WORDS) begin resp = NRESP_ERROR; return; end // F-022
    idx = req.addr[SDRAM_IDX_W-1:0];
    if (req.we) begin                                                      // F-011
      bit [SDRAM_DATA_W-1:0] cur = mem.exists(idx) ? mem[idx] : '0;
      for (int b = 0; b < SDRAM_STRB_W; b++)
        if (req.wstrb[b]) cur[b*8 +: 8] = req.wdata[b*8 +: 8];
      mem[idx] = cur;
      resp = NRESP_OKAY;
    end else begin                                                         // F-012
      resp  = NRESP_OKAY;
      rdata = mem.exists(idx) ? mem[idx] : '0;
    end
  endfunction
endclass

// ================================================================ scoreboard
class sdram_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(sdram_scoreboard)
  uvm_analysis_imp_req #(mem_req_item, sdram_scoreboard) sb_req;
  uvm_analysis_imp_rsp #(mem_req_item, sdram_scoreboard) sb_rsp;
  sdram_ref_model ref_model;
  mem_req_item    pend[$];               // outstanding requests, in order (F-008)
  int unsigned    n_total, n_match, n_err_resp;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    sb_req = new("sb_req", this);
    sb_rsp = new("sb_rsp", this);
  endfunction

  function void build_phase(uvm_phase phase);
    ref_model = sdram_ref_model::type_id::create("ref_model");
  endfunction

  // accepted request -> queue it
  function void write_req(mem_req_item t);
    mem_req_item c; if (!$cast(c, t.clone())) return;
    pend.push_back(c);
  endfunction

  // observed response -> pop oldest request, predict, compare
  function void write_rsp(mem_req_item r);
    mem_req_item req;
    bit [1:0] eresp; bit [SDRAM_DATA_W-1:0] erdata;
    if (pend.size() == 0) begin
      `uvm_error("SB", "response with no outstanding request (extra/dropped response)")
      return;
    end
    req = pend.pop_front();
    ref_model.predict(req, eresp, erdata);
    n_total++;
    if (eresp == NRESP_ERROR) n_err_resp++;
    if (r.resp !== eresp) begin
      `uvm_error("SB", $sformatf("resp mismatch addr=0x%0h we=%0b got=%0d exp=%0d",
                                 req.addr, req.we, r.resp, eresp))
    end else if (!req.we && eresp == NRESP_OKAY && r.rdata !== erdata) begin
      `uvm_error("SB", $sformatf("rdata mismatch addr=0x%0h got=0x%08h exp=0x%08h",
                                 req.addr, r.rdata, erdata))
    end else begin
      n_match++;
    end
  endfunction

  function void check_phase(uvm_phase phase);
    if (pend.size() != 0)
      `uvm_error("SB", $sformatf("%0d requests without responses at end of test", pend.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("scoreboard: total=%0d matched=%0d error_resp=%0d outstanding=%0d",
                              n_total, n_match, n_err_resp, pend.size()), UVM_LOW)
  endfunction
endclass

// ================================================================ coverage
// Black-box functional coverage on native traffic. White-box coverage
// (bank-state/page/cmd/timing/refresh) lives in the bound module tb/sva.
class sdram_coverage extends uvm_component;
  `uvm_component_utils(sdram_coverage)
  uvm_analysis_imp_req #(mem_req_item, sdram_coverage) cg_req;
  uvm_analysis_imp_rsp #(mem_req_item, sdram_coverage) cg_rsp;

  mem_req_item cur;

  // CG-ADR : bank / row class / out-of-range (F-010, F-022)
  covergroup cg_addr;
    option.per_instance = 1;
    cp_bank : coverpoint cur.addr[13:12];                  // 4 banks
    cp_oor  : coverpoint (cur.addr >= SDRAM_CAP_WORDS) { bins inrange={0}; bins oor={1}; }
    cp_we   : coverpoint cur.we { bins rd={0}; bins wr={1}; }
    x_bank_we : cross cp_bank, cp_we;
  endgroup
  // CG-STB : byte-strobe patterns on writes (F-011)
  covergroup cg_wstrb;
    option.per_instance = 1;
    cp_strb : coverpoint cur.wstrb {
      bins none = {4'h0}; bins b0={4'h1}; bins b01={4'h3};
      bins b012={4'h7}; bins all={4'hF}; bins others=default;
    }
  endgroup
  // CG-RSP : native response codes (F-022)
  covergroup cg_resp;
    option.per_instance = 1;
    cp_resp : coverpoint cur.resp { bins okay={NRESP_OKAY}; bins error={NRESP_ERROR}; }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_req = new("cg_req", this);
    cg_rsp = new("cg_rsp", this);
    cg_addr = new(); cg_wstrb = new(); cg_resp = new();
  endfunction

  function void write_req(mem_req_item t);
    cur = t;
    cg_addr.sample();
    if (t.we) cg_wstrb.sample();
  endfunction
  function void write_rsp(mem_req_item r);
    cur = r;
    cg_resp.sample();
  endfunction
endclass

// =========================================================== virtual sequencer
class sdram_vseqr extends uvm_sequencer;
  `uvm_component_utils(sdram_vseqr)
  axil_sequencer    axil_seqr;
  mem_req_sequencer mem_seqr;
  sdram_reg_block   regmodel;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

// ===================================================================== env
class sdram_env extends uvm_env;
  `uvm_component_utils(sdram_env)
  sdram_env_cfg                 cfg;
  axil_agent                    axil_agt;
  mem_req_agent                 mem_agt;
  sdram_scoreboard              sb;
  sdram_coverage                cov;
  sdram_vseqr                   vseqr;
  sdram_reg_block               regmodel;
  sdram_reg_adapter             adapter;
  uvm_reg_predictor #(axil_item) predictor;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(sdram_env_cfg)::get(this, "", "cfg", cfg)) begin
      cfg = sdram_env_cfg::type_id::create("cfg");
      `uvm_warning(get_type_name(), "no env cfg provided; using defaults")
    end
    uvm_config_db#(axil_agent_cfg)   ::set(this, "axil_agt", "cfg", cfg.axil_cfg);
    uvm_config_db#(mem_req_agent_cfg)::set(this, "mem_agt",  "cfg", cfg.mem_cfg);

    axil_agt = axil_agent   ::type_id::create("axil_agt", this);
    mem_agt  = mem_req_agent::type_id::create("mem_agt",  this);
    vseqr    = sdram_vseqr  ::type_id::create("vseqr",    this);

    regmodel = sdram_reg_block::type_id::create("regmodel");
    regmodel.build();
    regmodel.reset();
    adapter  = sdram_reg_adapter::type_id::create("adapter");
    predictor= uvm_reg_predictor#(axil_item)::type_id::create("predictor", this);

    if (cfg.has_scoreboard) sb  = sdram_scoreboard::type_id::create("sb",  this);
    if (cfg.has_coverage)   cov = sdram_coverage  ::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    // scoreboard
    if (cfg.has_scoreboard) begin
      mem_agt.ap_req.connect(sb.sb_req);
      mem_agt.ap_rsp.connect(sb.sb_rsp);
    end
    // coverage
    if (cfg.has_coverage) begin
      mem_agt.ap_req.connect(cov.cg_req);
      mem_agt.ap_rsp.connect(cov.cg_rsp);
    end
    // RAL: explicit predictor fed by the CSR monitor
    axil_agt.ap.connect(predictor.bus_in);
    predictor.map     = regmodel.map;
    predictor.adapter = adapter;
    regmodel.map.set_sequencer(axil_agt.seqr, adapter);
    regmodel.map.set_auto_predict(0);
    // virtual sequencer handles
    vseqr.axil_seqr = axil_agt.seqr;
    vseqr.mem_seqr  = mem_agt.seqr;
    vseqr.regmodel  = regmodel;
  endfunction
endclass
