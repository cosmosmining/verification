// ---------------------------------------------------------------------------
// sdram_regmodel.svh : UVM RAL model + bus adapter for the CSR map.
// Part of sdram_pkg. See docs/dut_spec.md section 4 for the register map.
// ---------------------------------------------------------------------------

// ---- CTRL (RW): ENABLE/REFRESH_EN/IRQ_EN in [2:0] ----
class ctrl_reg extends uvm_reg;
  `uvm_object_utils(ctrl_reg)
  rand uvm_reg_field cfg;
  function new(string name="ctrl_reg"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
  virtual function void build();
    cfg = uvm_reg_field::type_id::create("cfg");
    cfg.configure(this, 3, 0, "RW", 0, 3'h0, 1, 1, 0);
  endfunction
endclass

// ---- STATUS (RO, volatile) ----
class status_reg extends uvm_reg;
  `uvm_object_utils(status_reg)
  uvm_reg_field initd, busy, refp, qfull, qempty, bact;
  function new(string name="status_reg"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
  virtual function void build();
    initd  = uvm_reg_field::type_id::create("initd");
    busy   = uvm_reg_field::type_id::create("busy");
    refp   = uvm_reg_field::type_id::create("refp");
    qfull  = uvm_reg_field::type_id::create("qfull");
    qempty = uvm_reg_field::type_id::create("qempty");
    bact   = uvm_reg_field::type_id::create("bact");
    initd .configure(this, 1, 0, "RO", 1, 1'b0, 1, 0, 0);
    busy  .configure(this, 1, 1, "RO", 1, 1'b0, 1, 0, 0);
    refp  .configure(this, 1, 2, "RO", 1, 1'b0, 1, 0, 0);
    qfull .configure(this, 1, 3, "RO", 1, 1'b0, 1, 0, 0);
    qempty.configure(this, 1, 4, "RO", 1, 1'b1, 1, 0, 0);  // empty out of reset
    bact  .configure(this, 4, 8, "RO", 1, 4'b0, 1, 0, 0);
  endfunction
endclass

// ---- ERR_STATUS (W1C): RANGE_ERR[0] ----
class errst_reg extends uvm_reg;
  `uvm_object_utils(errst_reg)
  uvm_reg_field range_err;
  function new(string name="errst_reg"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
  virtual function void build();
    range_err = uvm_reg_field::type_id::create("range_err");
    range_err.configure(this, 1, 0, "W1C", 1, 1'b0, 1, 0, 0);
  endfunction
endclass

// ---- generic single-field register (RW or RO of given width/reset) ----
class field_reg extends uvm_reg;
  `uvm_object_utils(field_reg)
  rand uvm_reg_field f;
  int unsigned   fw    = 32;
  uvm_reg_data_t frst  = 0;
  string         facc  = "RW";
  function new(string name="field_reg"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
  function void set_params(int unsigned w, uvm_reg_data_t r, string acc);
    fw = w; frst = r; facc = acc;
  endfunction
  virtual function void build();
    f = uvm_reg_field::type_id::create("f");
    f.configure(this, fw, 0, facc, (facc=="RO"),
                frst & ((64'd1 << fw) - 64'd1), 1, (facc=="RW"), 0);
  endfunction
endclass

// ---- register block ----
class sdram_reg_block extends uvm_reg_block;
  `uvm_object_utils(sdram_reg_block)
  rand ctrl_reg   ctrl;
  status_reg      status;
  rand field_reg  t_rcd, t_rp, t_ref, scratch;
  errst_reg       err_status;
  field_reg       err_addr;
  uvm_reg_map     map;

  function new(string name="sdram_reg_block"); super.new(name, UVM_NO_COVERAGE); endfunction

  virtual function void build();
    ctrl       = ctrl_reg  ::type_id::create("ctrl");
    status     = status_reg::type_id::create("status");
    err_status = errst_reg ::type_id::create("err_status");
    t_rcd      = field_reg ::type_id::create("t_rcd");
    t_rp       = field_reg ::type_id::create("t_rp");
    t_ref      = field_reg ::type_id::create("t_ref");
    scratch    = field_reg ::type_id::create("scratch");
    err_addr   = field_reg ::type_id::create("err_addr");

    t_rcd  .set_params(4,  'h3,    "RW");
    t_rp   .set_params(4,  'h3,    "RW");
    t_ref  .set_params(16, 'd1024, "RW");
    scratch.set_params(32, 'h0,    "RW");
    err_addr.set_params(32,'h0,    "RO");

    foreach_build(ctrl); foreach_build(status); foreach_build(err_status);
    foreach_build(t_rcd); foreach_build(t_rp); foreach_build(t_ref);
    foreach_build(scratch); foreach_build(err_addr);

    map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
    map.add_reg(ctrl,       'h00, "RW");
    map.add_reg(status,     'h04, "RO");
    map.add_reg(t_rcd,      'h08, "RW");
    map.add_reg(t_rp,       'h0C, "RW");
    map.add_reg(t_ref,      'h10, "RW");
    map.add_reg(err_status, 'h14, "RW");
    map.add_reg(err_addr,   'h18, "RO");
    map.add_reg(scratch,    'h1C, "RW");

    // Exclude clamping / HW-driven registers from built-in bit-bash & access
    // tests (they are not pure RW). They are covered by the directed
    // reprogram test and the cocotb csr_sanity clamp checks instead.
    foreach_no_test(t_rcd); foreach_no_test(t_rp); foreach_no_test(t_ref);
    foreach_no_test(err_status);

    lock_model();
  endfunction

  // helper: configure(parent)+build() for a child register
  function void foreach_build(uvm_reg r);
    r.configure(this, null, "");
    r.build();
  endfunction

  function void foreach_no_test(uvm_reg r);
    uvm_resource_db#(bit)::set({"REG::", r.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1);
    uvm_resource_db#(bit)::set({"REG::", r.get_full_name()}, "NO_REG_ACCESS_TEST",   1);
  endfunction
endclass

// ---- bus adapter ----
class sdram_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(sdram_reg_adapter)
  function new(string name="sdram_reg_adapter");
    super.new(name);
    supports_byte_enable = 0;
    provides_responses   = 0;
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    axil_item it = axil_item::type_id::create("reg2bus");
    it.is_write = (rw.kind == UVM_WRITE);
    it.addr     = rw.addr[SDRAM_AXIL_AW-1:0];
    it.wdata    = rw.data[SDRAM_DATA_W-1:0];
    it.wstrb    = '1;
    return it;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    axil_item it;
    if (!$cast(it, bus_item)) begin
      `uvm_fatal("REG_ADAPTER", "bus2reg: wrong item type")
      return;
    end
    rw.kind   = it.is_write ? UVM_WRITE : UVM_READ;
    rw.addr   = it.addr;
    rw.data   = it.is_write ? it.wdata : it.rdata;
    rw.status = (it.resp == AXI_OKAY) ? UVM_IS_OK : UVM_NOT_OK;
  endfunction
endclass
