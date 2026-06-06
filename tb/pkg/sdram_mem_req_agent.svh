// ---------------------------------------------------------------------------
// sdram_mem_req_agent.svh : native request/response master agent.
// Part of sdram_pkg.
// ---------------------------------------------------------------------------

typedef uvm_sequencer #(mem_req_item) mem_req_sequencer;

// ----------------------------------------------------------------- driver
class mem_req_driver extends uvm_driver #(mem_req_item);
  `uvm_component_utils(mem_req_driver)
  virtual mem_req_if vif;
  mem_req_agent_cfg  cfg;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(mem_req_agent_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal(get_type_name(), "no mem_req_agent_cfg")
    vif = cfg.vif;
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      fork
        begin : active
          @(vif.mst_cb); reset_outputs();
          wait (vif.rst_n === 1'b1);
          fork
            drive_requests();
            drive_rsp_ready();
          join
        end
        begin : rst_detect
          wait (vif.rst_n === 1'b0);
        end
      join_any
      disable fork;
    end
  endtask

  task automatic reset_outputs();
    vif.mst_cb.req_valid <= 1'b0; vif.mst_cb.req_we <= 1'b0; vif.mst_cb.req_addr <= '0;
    vif.mst_cb.req_wdata <= '0;   vif.mst_cb.req_wstrb <= '0; vif.mst_cb.rsp_ready <= 1'b0;
  endtask

  task automatic drive_requests();
    forever begin
      seq_item_port.get_next_item(req);
      // optional idle gap before this request (back-pressure on req channel)
      while (($urandom_range(99) < cfg.req_idle_bp)) begin
        vif.mst_cb.req_valid <= 1'b0; @(vif.mst_cb);
      end
      vif.mst_cb.req_valid <= 1'b1;
      vif.mst_cb.req_we    <= req.we;
      vif.mst_cb.req_addr  <= req.addr;
      vif.mst_cb.req_wdata <= req.wdata;
      vif.mst_cb.req_wstrb <= req.wstrb;
      forever begin @(vif.mst_cb); if (vif.mst_cb.req_ready) break; end
      vif.mst_cb.req_valid <= 1'b0;
      seq_item_port.item_done();
    end
  endtask

  // Independent thread: applies random rsp_ready back-pressure.
  task automatic drive_rsp_ready();
    forever begin
      vif.mst_cb.rsp_ready <= ($urandom_range(99) < cfg.rsp_ready_bp) ? 1'b0 : 1'b1;
      @(vif.mst_cb);
    end
  endtask
endclass

// ----------------------------------------------------------------- monitor
class mem_req_monitor extends uvm_monitor;
  `uvm_component_utils(mem_req_monitor)
  virtual mem_req_if vif;
  uvm_analysis_port #(mem_req_item) ap_req;  // accepted requests (in order)
  uvm_analysis_port #(mem_req_item) ap_rsp;  // observed responses (in order)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap_req = new("ap_req", this);
    ap_rsp = new("ap_rsp", this);
  endfunction

  function void build_phase(uvm_phase phase);
    mem_req_agent_cfg cfg;
    if (!uvm_config_db#(mem_req_agent_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal(get_type_name(), "no mem_req_agent_cfg")
    vif = cfg.vif;
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) continue;
      if (vif.mon_cb.req_valid && vif.mon_cb.req_ready) begin
        mem_req_item it = mem_req_item::type_id::create("req");
        it.we    = vif.mon_cb.req_we;
        it.addr  = vif.mon_cb.req_addr;
        it.wdata = vif.mon_cb.req_wdata;
        it.wstrb = vif.mon_cb.req_wstrb;
        ap_req.write(it);
      end
      if (vif.mon_cb.rsp_valid && vif.mon_cb.rsp_ready) begin
        mem_req_item it = mem_req_item::type_id::create("rsp");
        it.rdata = vif.mon_cb.rsp_rdata;
        it.resp  = vif.mon_cb.rsp_resp;
        ap_rsp.write(it);
      end
    end
  endtask
endclass

// ----------------------------------------------------------------- agent
class mem_req_agent extends uvm_agent;
  `uvm_component_utils(mem_req_agent)
  mem_req_agent_cfg cfg;
  mem_req_driver    drv;
  mem_req_sequencer seqr;
  mem_req_monitor   mon;
  uvm_analysis_port #(mem_req_item) ap_req;
  uvm_analysis_port #(mem_req_item) ap_rsp;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(mem_req_agent_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal(get_type_name(), "no mem_req_agent_cfg")
    uvm_config_db#(mem_req_agent_cfg)::set(this, "*", "cfg", cfg);
    mon = mem_req_monitor::type_id::create("mon", this);
    if (cfg.is_active == UVM_ACTIVE) begin
      drv  = mem_req_driver::type_id::create("drv", this);
      seqr = mem_req_sequencer::type_id::create("seqr", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    ap_req = mon.ap_req;
    ap_rsp = mon.ap_rsp;
    if (cfg.is_active == UVM_ACTIVE)
      drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction
endclass
