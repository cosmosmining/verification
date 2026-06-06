// ---------------------------------------------------------------------------
// sdram_sequences.svh : native traffic sequence + virtual sequences.
// Part of sdram_pkg.
// ---------------------------------------------------------------------------

// ----------------------------------------------------------- native traffic
class mem_traffic_seq extends uvm_sequence #(mem_req_item);
  `uvm_object_utils(mem_traffic_seq)
  int unsigned n        = 100;
  int unsigned oor_pct  = 10;    // out-of-range address probability
  int unsigned hot_pct  = 50;    // locality probability (hot set)
  bit          thrash   = 0;     // all-banks alternating-row mode
  bit [SDRAM_ADDR_W-1:0] hot[$];
  int unsigned tcnt = 0;

  function new(string name="mem_traffic_seq"); super.new(name); endfunction

  function void default_hot();
    hot = '{0,1,2,'h100,'h101,'h200,'h1000,'h1001,'h2000,'h3FFF};
  endfunction

  function bit [SDRAM_ADDR_W-1:0] pick_thrash();
    bit [1:0] bank = tcnt[1:0];
    bit [3:0] row  = tcnt[2] ? 4'd8 : 4'd0;   // alternate two rows -> conflicts
    bit [7:0] col  = $urandom_range(255);
    return {18'd0, bank, row, col};
  endfunction

  task body();
    if (hot.size() == 0) default_hot();
    repeat (n) begin
      mem_req_item it = mem_req_item::type_id::create("it");
      start_item(it);
      if (!it.randomize()) `uvm_error(get_type_name(), "randomize failed")
      // address selection by knob (post-randomize)
      if ($urandom_range(99) < oor_pct)
        it.addr = SDRAM_CAP_WORDS + $urandom_range(1<<16);
      else if (thrash)
        it.addr = pick_thrash();
      else if ($urandom_range(99) < hot_pct)
        it.addr = hot[$urandom_range(hot.size()-1)];
      else
        it.addr = $urandom_range(SDRAM_CAP_WORDS-1);
      if (it.we && it.wstrb == 0) it.wstrb = 4'hF;  // keep write strobe legal
      finish_item(it);
      tcnt++;
    end
  endtask
endclass

// ------------------------------------------------ directed native sequence
class mem_directed_seq extends uvm_sequence #(mem_req_item);
  `uvm_object_utils(mem_directed_seq)
  bit                    wes  [$];
  bit [SDRAM_ADDR_W-1:0] addrs[$];
  bit [SDRAM_DATA_W-1:0] datas[$];
  function new(string name="mem_directed_seq"); super.new(name); endfunction
  task body();
    foreach (addrs[i]) begin
      mem_req_item it = mem_req_item::type_id::create("it");
      start_item(it);
      it.we    = wes[i];
      it.addr  = addrs[i];
      it.wdata = datas[i];
      it.wstrb = wes[i] ? 4'hF : 4'h0;
      finish_item(it);
    end
  endtask
endclass

// --------------------------------------------------------- virtual seq base
class sdram_base_vseq extends uvm_sequence #(uvm_sequence_item);
  `uvm_object_utils(sdram_base_vseq)
  `uvm_declare_p_sequencer(sdram_vseqr)
  function new(string name="sdram_base_vseq"); super.new(name); endfunction

  // program timing, enable, wait for INIT_DONE (F-026)
  task configure(int trcd=3, int trp=3, int tref=64, bit irq=1);
    uvm_status_e st; uvm_reg_data_t val;
    p_sequencer.regmodel.t_rcd.write(st, trcd, .parent(this));
    p_sequencer.regmodel.t_rp .write(st, trp,  .parent(this));
    p_sequencer.regmodel.t_ref.write(st, tref, .parent(this));
    p_sequencer.regmodel.ctrl .write(st, (irq ? 32'h7 : 32'h3), .parent(this));
    for (int i = 0; i < 500; i++) begin
      p_sequencer.regmodel.status.read(st, val, .parent(this));
      if (val[0]) return;   // INIT_DONE
    end
    `uvm_error(get_type_name(), "INIT_DONE never asserted")
  endtask
endclass

// --------------------------------------------------------------- cfg only
class sdram_cfg_vseq extends sdram_base_vseq;
  `uvm_object_utils(sdram_cfg_vseq)
  int trcd=3, trp=3, tref=64;
  function new(string name="sdram_cfg_vseq"); super.new(name); endfunction
  task body(); configure(trcd, trp, tref); endtask
endclass

// ------------------------------------------------------------ random traffic
class sdram_random_vseq extends sdram_base_vseq;
  `uvm_object_utils(sdram_random_vseq)
  int unsigned n=200, oor_pct=10, hot_pct=50;
  bit thrash=0;
  int trcd=3, trp=3, tref=64;
  function new(string name="sdram_random_vseq"); super.new(name); endfunction
  task body();
    mem_traffic_seq tr;
    configure(trcd, trp, tref);
    tr = mem_traffic_seq::type_id::create("tr");
    tr.n = n; tr.oor_pct = oor_pct; tr.hot_pct = hot_pct; tr.thrash = thrash;
    tr.start(p_sequencer.mem_seqr, this);
  endtask
endclass

// ------------------------------------------------- illegal-address focused
class sdram_illegal_vseq extends sdram_random_vseq;
  `uvm_object_utils(sdram_illegal_vseq)
  function new(string name="sdram_illegal_vseq");
    super.new(name); oor_pct = 70; n = 150;
  endfunction
endclass

// ----------------------------------------------------- all-banks thrash
class sdram_thrash_vseq extends sdram_random_vseq;
  `uvm_object_utils(sdram_thrash_vseq)
  function new(string name="sdram_thrash_vseq");
    super.new(name); thrash = 1; n = 256;
  endfunction
endclass

// ----------------------------------------------------- refresh collision
class sdram_refresh_collision_vseq extends sdram_random_vseq;
  `uvm_object_utils(sdram_refresh_collision_vseq)
  function new(string name="sdram_refresh_collision_vseq");
    super.new(name); tref = 24; hot_pct = 70; n = 300;  // small tREF -> frequent refresh
  endfunction
endclass

// ------------------------------- clean-recovery after reset (write-then-read)
class sdram_recovery_vseq extends sdram_base_vseq;
  `uvm_object_utils(sdram_recovery_vseq)
  function new(string name="sdram_recovery_vseq"); super.new(name); endfunction
  task body();
    mem_directed_seq d = mem_directed_seq::type_id::create("d");
    configure(3, 3, 64);
    // write a fixed set, then read it back -> consistent regardless of the
    // (intentionally undefined) memory contents left by the pre-reset traffic.
    for (int a = 0; a < 32; a++) begin
      d.wes.push_back(1); d.addrs.push_back(a); d.datas.push_back(32'hC0DE_0000 + a);
    end
    for (int a = 0; a < 32; a++) begin
      d.wes.push_back(0); d.addrs.push_back(a); d.datas.push_back(0);
    end
    d.start(p_sequencer.mem_seqr, this);
  endtask
endclass

// ----------------------------------------------- mid-traffic CSR reprogram (F-027)
class sdram_reprogram_vseq extends sdram_base_vseq;
  `uvm_object_utils(sdram_reprogram_vseq)
  int unsigned n=300;
  function new(string name="sdram_reprogram_vseq"); super.new(name); endfunction
  task body();
    mem_traffic_seq tr;
    uvm_status_e st;
    configure(3, 3, 64);
    tr = mem_traffic_seq::type_id::create("tr");
    tr.n = n; tr.hot_pct = 40;
    fork
      tr.start(p_sequencer.mem_seqr, this);
      begin : reprog
        // walk timing through corners while traffic runs
        int unsigned vals[] = '{1, 2, 5, 6, 4};
        foreach (vals[i]) begin
          #2000ns;
          p_sequencer.regmodel.t_rcd.write(st, vals[i], .parent(this));
          p_sequencer.regmodel.t_rp .write(st, vals[(i+1)%vals.size()], .parent(this));
        end
      end
    join_any
    disable fork;
  endtask
endclass
