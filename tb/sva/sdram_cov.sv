// ---------------------------------------------------------------------------
// sdram_cov.sv : white-box functional coverage, bound to the DUT (no RTL edits).
// Implements the vplan covergroups that need internal visibility:
//   CG-BNK, CG-PG, CG-CMD, CG-PGC, CG-TM, CG-Q, CG-REF, CG-RST.
// (Black-box CG-ADR / CG-STB / CG-RSP live in the UVM sdram_coverage subscriber.)
//
// This module uses SystemVerilog covergroups and is compiled ONLY into the UVM
// filelist (tb/sdram.f) -- it is intentionally NOT part of the Verilator/cocotb
// build (Verilator does not collect covergroups).
// ---------------------------------------------------------------------------
module sdram_cov #(parameter int BANKS = 4) (
  input logic        clk, rst_n,
  input logic        act_issue, pre_issue, cas_issue, ref_issue,
  input logic [3:0]  bank_state [0:BANKS-1],
  input logic [1:0]  cur_bank,
  input logic        cur_we,
  input logic [3:0]  t_rcd_q, t_rp_q,
  input logic [15:0] t_ref_q,
  input logic [3:0]  q_level,
  input logic        refresh_active
);
  typedef enum logic [1:0] { PG_HIT, PG_MISS, PG_CONFLICT } pg_e;

  // ---- derive page outcome of each CAS from the command sequence ----
  logic pend_conflict, had_act;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin pend_conflict <= 1'b0; had_act <= 1'b0; end
    else begin
      if (pre_issue) pend_conflict <= 1'b1;
      if (act_issue) had_act       <= 1'b1;
      if (cas_issue) begin pend_conflict <= 1'b0; had_act <= 1'b0; end
    end

  pg_e   page_outcome;
  always_comb begin
    if      (!had_act)      page_outcome = PG_HIT;
    else if (pend_conflict) page_outcome = PG_CONFLICT;
    else                    page_outcome = PG_MISS;
  end

  // ---- count active banks at a refresh (collision pressure) ----
  function automatic int unsigned n_active();
    int unsigned n = 0;
    for (int b = 0; b < BANKS; b++) if (bank_state[b] != 4'b0001) n++;
    return n;
  endfunction

  // ===================================================================== CG-BNK
  covergroup cg_bank_state @(posedge clk);
    option.per_instance = 1;
    cp_state : coverpoint bank_state[cur_bank] {
      bins idle    = {4'b0001};
      bins acting  = {4'b0010};
      bins active  = {4'b0100};
      bins prechg  = {4'b1000};
      // legal forward path; IDLE->PRECHARGING is illegal (must pass ACTIVE)
      bins t_open  = (4'b0001 => 4'b0010 => 4'b0100);
      bins t_close = (4'b0100 => 4'b1000 => 4'b0001);
      illegal_bins t_bad = (4'b0001 => 4'b1000);
    }
  endgroup

  // ===================================================================== CG-CMD
  bit [2:0] cmd_code;  // 0=ACT 1=PRE 2=CAS_RD 3=CAS_WR 4=REF
  covergroup cg_cmd;
    option.per_instance = 1;
    cp_cmd : coverpoint cmd_code {
      bins act    = {0};
      bins pre    = {1};
      bins cas_rd = {2};
      bins cas_wr = {3};
      bins refr   = {4};
    }
  endgroup

  // ============================================================ CG-PG / CG-PGC
  covergroup cg_page;
    option.per_instance = 1;
    cp_page : coverpoint page_outcome {
      bins hit      = {PG_HIT};
      bins miss     = {PG_MISS};
      bins conflict = {PG_CONFLICT};
    }
    cp_rw : coverpoint cur_we { bins rd = {0}; bins wr = {1}; }
    x_page_cmd : cross cp_page, cp_rw;   // CG-PGC
  endgroup

  // ===================================================================== CG-TM
  covergroup cg_timing;
    option.per_instance = 1;
    cp_trcd : coverpoint t_rcd_q { bins lo={1}; bins two={2}; bins three={3};
                                   bins mid={[4:6]}; bins hi={[7:15]}; }
    cp_trp  : coverpoint t_rp_q  { bins lo={1}; bins two={2}; bins three={3};
                                   bins mid={[4:6]}; bins hi={[7:15]}; }
    cp_tref : coverpoint t_ref_q { bins min={[16:31]}; bins small={[32:127]};
                                   bins def={[128:1023]}; bins large={[1024:65535]}; }
  endgroup

  // ====================================================================== CG-Q
  covergroup cg_queue @(posedge clk);
    option.per_instance = 1;
    cp_level : coverpoint q_level {
      bins empty = {0};
      bins low   = {[1:2]};
      bins mid   = {[3:5]};
      bins high  = {[6:7]};
      bins full  = {8};
    }
  endgroup

  // ==================================================================== CG-REF
  int unsigned ref_active_n;
  covergroup cg_refresh;
    option.per_instance = 1;
    cp_banks : coverpoint ref_active_n { bins b[] = {[0:BANKS]}; }
  endgroup

  // ==================================================================== CG-RST
  bit rst_busy, rst_refresh;
  covergroup cg_reset_traffic;
    option.per_instance = 1;
    cp_busy    : coverpoint rst_busy    { bins idle={0}; bins busy={1}; }
    cp_refresh : coverpoint rst_refresh { bins norefresh={0}; bins inrefresh={1}; }
    x_rst : cross cp_busy, cp_refresh;
  endgroup

  cg_bank_state    cov_bnk;
  cg_cmd           cov_cmd;
  cg_page          cov_pg;
  cg_timing        cov_tm;
  cg_queue         cov_q;
  cg_refresh       cov_ref;
  cg_reset_traffic cov_rst;
  initial begin
    cov_bnk = new(); cov_cmd = new(); cov_pg = new(); cov_tm = new();
    cov_q = new(); cov_ref = new(); cov_rst = new();
  end

  // ---- event-driven sampling (blocking assigns so sample() sees the new value) ----
  always @(posedge clk) begin
    if (act_issue) begin cmd_code = 3'd0; cov_cmd.sample(); cov_tm.sample(); end
    if (pre_issue) begin cmd_code = 3'd1; cov_cmd.sample(); end
    if (cas_issue) begin
      cmd_code = cur_we ? 3'd3 : 3'd2;
      cov_cmd.sample();
      cov_pg.sample();
    end
    if (ref_issue) begin
      cmd_code = 3'd4; ref_active_n = n_active();
      cov_cmd.sample(); cov_ref.sample(); cov_tm.sample();
    end
  end

  // CG-RST: sample DUT activity at the moment reset is asserted
  always @(negedge rst_n) begin
    rst_busy    = (q_level != 0);
    rst_refresh = refresh_active;
    cov_rst.sample();
  end
endmodule
