// ---------------------------------------------------------------------------
// sdram_tests.svh : UVM tests. Part of sdram_pkg.
// Each test maps to rows in docs/vplan.md section 4/5.
// ---------------------------------------------------------------------------

class sdram_base_test extends uvm_test;
  `uvm_component_utils(sdram_base_test)
  sdram_env             env;
  sdram_env_cfg         cfg;
  virtual sdram_rst_if  rst_vif;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  // derived tests tweak agent config here (e.g. back-pressure knobs)
  virtual function void tune_cfg(sdram_env_cfg c); endfunction
  // derived tests return the virtual sequence to run (null = wiring sanity only)
  virtual function sdram_base_vseq get_vseq(); return null; endfunction

  function void build_phase(uvm_phase phase);
    cfg = sdram_env_cfg::type_id::create("cfg");
    if (!uvm_config_db#(virtual axil_if)::get(this, "", "axil_vif", cfg.axil_cfg.vif))
      `uvm_fatal(get_type_name(), "no axil_vif")
    if (!uvm_config_db#(virtual mem_req_if)::get(this, "", "mem_vif", cfg.mem_cfg.vif))
      `uvm_fatal(get_type_name(), "no mem_vif")
    void'(uvm_config_db#(virtual sdram_rst_if)::get(this, "", "rst_vif", rst_vif));
    tune_cfg(cfg);
    uvm_config_db#(sdram_env_cfg)::set(this, "env", "cfg", cfg);
    env = sdram_env::type_id::create("env", this);
  endfunction

  task wait_drain(int unsigned timeout_ns = 40000);
    int unsigned t = 0;
    if (env.sb == null) return;
    while (env.sb.pend.size() != 0 && t < timeout_ns) begin #100ns; t += 100; end
  endtask

  task run_phase(uvm_phase phase);
    sdram_base_vseq vseq;
    phase.raise_objection(this);
    #200ns;                       // tb_top drives power-on reset; let it settle
    vseq = get_vseq();
    if (vseq != null) vseq.start(env.vseqr);
    wait_drain();
    #500ns;
    phase.drop_objection(this);
  endtask
endclass

// --------------------------------------------------------------- smoke
class sdram_smoke_test extends sdram_base_test;
  `uvm_component_utils(sdram_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function sdram_base_vseq get_vseq();
    sdram_random_vseq v = sdram_random_vseq::type_id::create("v");
    v.n = 20; return v;
  endfunction
endclass

// --------------------------------------------------------------- RAL
class sdram_reg_test extends sdram_base_test;
  `uvm_component_utils(sdram_reg_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    uvm_reg_hw_reset_seq hw;
    uvm_reg_bit_bash_seq bb;
    uvm_reg_access_seq   ac;
    phase.raise_objection(this);
    #200ns;
    hw = uvm_reg_hw_reset_seq::type_id::create("hw"); hw.model = env.regmodel; hw.start(null);
    bb = uvm_reg_bit_bash_seq::type_id::create("bb"); bb.model = env.regmodel; bb.start(null);
    ac = uvm_reg_access_seq  ::type_id::create("ac"); ac.model = env.regmodel; ac.start(null);
    #200ns;
    phase.drop_objection(this);
  endtask
endclass

// --------------------------------------------------------------- random
class sdram_random_test extends sdram_base_test;
  `uvm_component_utils(sdram_random_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function sdram_base_vseq get_vseq();
    sdram_random_vseq v = sdram_random_vseq::type_id::create("v");
    v.n = 300; return v;
  endfunction
endclass

// --------------------------------------------------------------- locality
class sdram_locality_test extends sdram_base_test;
  `uvm_component_utils(sdram_locality_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function sdram_base_vseq get_vseq();
    sdram_random_vseq v = sdram_random_vseq::type_id::create("v");
    v.n = 300; v.hot_pct = 90; return v;
  endfunction
endclass

// --------------------------------------------------------------- back-pressure
class sdram_backpressure_test extends sdram_base_test;
  `uvm_component_utils(sdram_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void tune_cfg(sdram_env_cfg c);
    c.mem_cfg.rsp_ready_bp = 60;
    c.mem_cfg.req_idle_bp  = 50;
  endfunction
  function sdram_base_vseq get_vseq();
    sdram_random_vseq v = sdram_random_vseq::type_id::create("v");
    v.n = 250; return v;
  endfunction
endclass

// --------------------------------------------------------------- illegal addr
class sdram_illegal_addr_test extends sdram_base_test;
  `uvm_component_utils(sdram_illegal_addr_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function sdram_base_vseq get_vseq();
    return sdram_illegal_vseq::type_id::create("v");
  endfunction
endclass

// --------------------------------------------------------------- refresh collision
class sdram_refresh_collision_test extends sdram_base_test;
  `uvm_component_utils(sdram_refresh_collision_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function sdram_base_vseq get_vseq();
    return sdram_refresh_collision_vseq::type_id::create("v");
  endfunction
endclass

// --------------------------------------------------------------- all-banks thrash
class sdram_allbanks_thrash_test extends sdram_base_test;
  `uvm_component_utils(sdram_allbanks_thrash_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function sdram_base_vseq get_vseq();
    return sdram_thrash_vseq::type_id::create("v");
  endfunction
endclass

// --------------------------------------------------------------- CSR reprogram
class sdram_csr_reprogram_test extends sdram_base_test;
  `uvm_component_utils(sdram_csr_reprogram_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function sdram_base_vseq get_vseq();
    return sdram_reprogram_vseq::type_id::create("v");
  endfunction
endclass

// --------------------------------------------------------------- reset during traffic
class sdram_reset_during_traffic_test extends sdram_base_test;
  `uvm_component_utils(sdram_reset_during_traffic_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    #200ns;
    fork
      begin
        sdram_random_vseq r = sdram_random_vseq::type_id::create("r");
        r.n = 150; r.start(env.vseqr);
      end
    join_none
    #3000ns;
    if (rst_vif != null) rst_vif.pulse(6);   // assert reset mid-traffic (F-025)
    #300ns;
    disable fork;                            // stop the interrupted traffic seq
    if (env.sb != null) env.sb.pend.delete();// drop stale outstanding (responses lost to reset)
    begin
      sdram_recovery_vseq rec = sdram_recovery_vseq::type_id::create("rec");
      rec.start(env.vseqr);                  // clean recovery: write-then-read a fixed set
    end
    wait_drain();
    #300ns;
    phase.drop_objection(this);
  endtask
endclass
