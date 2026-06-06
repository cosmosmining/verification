// ---------------------------------------------------------------------------
// sdram_axil_agent.svh : AXI4-Lite master agent (CSR port). Part of sdram_pkg.
// Drives RAL frontdoor accesses; monitor feeds the uvm_reg_predictor.
// ---------------------------------------------------------------------------

typedef uvm_sequencer #(axil_item) axil_sequencer;

// ----------------------------------------------------------------- driver
class axil_driver extends uvm_driver #(axil_item);
  `uvm_component_utils(axil_driver)
  virtual axil_if vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    axil_agent_cfg cfg;
    if (!uvm_config_db#(axil_agent_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal(get_type_name(), "no axil_agent_cfg")
    vif = cfg.vif;
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      fork
        begin : active
          @(vif.mst_cb); reset_outputs();
          wait (vif.rst_n === 1'b1);
          forever begin
            seq_item_port.get_next_item(req);
            if (req.is_write) drive_write(req); else drive_read(req);
            seq_item_port.item_done();
          end
        end
        begin : rst_detect
          wait (vif.rst_n === 1'b0);  // abort on (re-)assert of reset
        end
      join_any
      disable fork;
    end
  endtask

  task automatic reset_outputs();
    vif.mst_cb.awvalid <= 1'b0; vif.mst_cb.wvalid <= 1'b0; vif.mst_cb.bready <= 1'b0;
    vif.mst_cb.arvalid <= 1'b0; vif.mst_cb.rready <= 1'b0;
    vif.mst_cb.awaddr  <= '0;   vif.mst_cb.awprot <= '0;
    vif.mst_cb.wdata   <= '0;   vif.mst_cb.wstrb  <= '0;
    vif.mst_cb.araddr  <= '0;   vif.mst_cb.arprot <= '0;
  endtask

  task automatic drive_write(axil_item it);
    @(vif.mst_cb);
    vif.mst_cb.awvalid <= 1'b1; vif.mst_cb.awaddr <= it.addr; vif.mst_cb.awprot <= '0;
    vif.mst_cb.wvalid  <= 1'b1; vif.mst_cb.wdata  <= it.wdata; vif.mst_cb.wstrb <= it.wstrb;
    fork
      begin : aw  forever begin @(vif.mst_cb); if (vif.mst_cb.awready) begin vif.mst_cb.awvalid <= 1'b0; break; end end end
      begin : w   forever begin @(vif.mst_cb); if (vif.mst_cb.wready)  begin vif.mst_cb.wvalid  <= 1'b0; break; end end end
    join
    vif.mst_cb.bready <= 1'b1;
    forever begin @(vif.mst_cb); if (vif.mst_cb.bvalid) begin it.resp = vif.mst_cb.bresp; break; end end
    vif.mst_cb.bready <= 1'b0;
  endtask

  task automatic drive_read(axil_item it);
    @(vif.mst_cb);
    vif.mst_cb.arvalid <= 1'b1; vif.mst_cb.araddr <= it.addr; vif.mst_cb.arprot <= '0;
    forever begin @(vif.mst_cb); if (vif.mst_cb.arready) begin vif.mst_cb.arvalid <= 1'b0; break; end end
    vif.mst_cb.rready <= 1'b1;
    forever begin @(vif.mst_cb);
      if (vif.mst_cb.rvalid) begin it.rdata = vif.mst_cb.rdata; it.resp = vif.mst_cb.rresp; break; end
    end
    vif.mst_cb.rready <= 1'b0;
  endtask
endclass

// ----------------------------------------------------------------- monitor
class axil_monitor extends uvm_monitor;
  `uvm_component_utils(axil_monitor)
  virtual axil_if vif;
  uvm_analysis_port #(axil_item) ap;
  function new(string name, uvm_component parent);
    super.new(name, parent); ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    axil_agent_cfg cfg;
    if (!uvm_config_db#(axil_agent_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal(get_type_name(), "no axil_agent_cfg")
    vif = cfg.vif;
  endfunction

  task run_phase(uvm_phase phase);
    bit aw_seen=0, w_seen=0, ar_seen=0;
    bit [SDRAM_AXIL_AW-1:0] aw_addr=0, ar_addr=0;
    bit [SDRAM_DATA_W-1:0]  w_data=0;
    bit [SDRAM_STRB_W-1:0]  w_strb=0;
    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) begin aw_seen=0; w_seen=0; ar_seen=0; continue; end
      // write address / data capture
      if (vif.mon_cb.awvalid && vif.mon_cb.awready) begin aw_addr = vif.mon_cb.awaddr; aw_seen=1; end
      if (vif.mon_cb.wvalid  && vif.mon_cb.wready ) begin w_data  = vif.mon_cb.wdata; w_strb = vif.mon_cb.wstrb; w_seen=1; end
      if (vif.mon_cb.bvalid  && vif.mon_cb.bready ) begin
        axil_item it = axil_item::type_id::create("wr");
        it.is_write = 1; it.addr = aw_addr; it.wdata = w_data; it.wstrb = w_strb;
        it.resp = vif.mon_cb.bresp; ap.write(it);
        aw_seen=0; w_seen=0;
      end
      // read capture
      if (vif.mon_cb.arvalid && vif.mon_cb.arready) begin ar_addr = vif.mon_cb.araddr; ar_seen=1; end
      if (vif.mon_cb.rvalid  && vif.mon_cb.rready && ar_seen) begin
        axil_item it = axil_item::type_id::create("rd");
        it.is_write = 0; it.addr = ar_addr; it.rdata = vif.mon_cb.rdata;
        it.resp = vif.mon_cb.rresp; ap.write(it);
        ar_seen=0;
      end
    end
  endtask
endclass

// ----------------------------------------------------------------- agent
class axil_agent extends uvm_agent;
  `uvm_component_utils(axil_agent)
  axil_agent_cfg cfg;
  axil_driver    drv;
  axil_sequencer seqr;
  axil_monitor   mon;
  uvm_analysis_port #(axil_item) ap;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(axil_agent_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal(get_type_name(), "no axil_agent_cfg")
    uvm_config_db#(axil_agent_cfg)::set(this, "*", "cfg", cfg);
    mon = axil_monitor::type_id::create("mon", this);
    if (cfg.is_active == UVM_ACTIVE) begin
      drv  = axil_driver::type_id::create("drv", this);
      seqr = axil_sequencer::type_id::create("seqr", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    ap = mon.ap;
    if (cfg.is_active == UVM_ACTIVE)
      drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction
endclass
