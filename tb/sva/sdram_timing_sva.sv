// ---------------------------------------------------------------------------
// sdram_timing_sva.sv : white-box bank-timing + FSM assertions. Bound to the
// DUT; reads internal command pulses, per-bank state, and timing CSRs.
// Implements vplan A-TRCD, A-TRP, A-TREF, A-1HOT, A-NCDR.
// ---------------------------------------------------------------------------
module sdram_timing_sva #(parameter int BANKS = 4, parameter int TRFC = 8) (
  input logic        clk, rst_n,
  input logic        act_issue, pre_issue, cas_issue, ref_issue,
  input logic [3:0]  bank_state [0:BANKS-1],
  input logic [3:0]  t_rcd_q, t_rp_q,
  input logic [15:0] t_ref_q,
  input logic        refresh_active, init_done, ctrl_enable, ctrl_refresh_en
);
  // ---- A-1HOT : per-bank state is always one-hot (legal encoding) ----
  genvar b;
  generate
    for (b = 0; b < BANKS; b++) begin : g_onehot
      ap_onehot : assert property (@(posedge clk) disable iff (!rst_n)
        $onehot(bank_state[b]));
    end
  endgenerate

  // ---- A-NCDR : no CAS while a refresh is in progress ----
  ap_no_cas_in_refresh : assert property (@(posedge clk) disable iff (!rst_n)
    refresh_active |-> !cas_issue);

  // ---- A-TRCD : >= t_rcd cycles between an ACTIVATE and its following CAS ----
  // (serialized scheduler: each activate is consumed by exactly one CAS)
  logic        await_cas;
  int unsigned cyc_since_act;
  logic [3:0]  trcd_cap;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin await_cas <= 1'b0; cyc_since_act <= 0; trcd_cap <= '0; end
    else begin
      if (act_issue) begin await_cas <= 1'b1; cyc_since_act <= 0; trcd_cap <= t_rcd_q; end
      else if (await_cas) cyc_since_act <= cyc_since_act + 1;
      if (cas_issue && await_cas) await_cas <= 1'b0;
    end
  ap_trcd : assert property (@(posedge clk) disable iff (!rst_n)
    (cas_issue && await_cas) |-> (cyc_since_act >= trcd_cap));

  // ---- A-TRP : >= t_rp cycles between a PRECHARGE and the following ACTIVATE ----
  logic        await_act;
  int unsigned cyc_since_pre;
  logic [3:0]  trp_cap;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin await_act <= 1'b0; cyc_since_pre <= 0; trp_cap <= '0; end
    else begin
      if (pre_issue) begin await_act <= 1'b1; cyc_since_pre <= 0; trp_cap <= t_rp_q; end
      else if (await_act) cyc_since_pre <= cyc_since_pre + 1;
      if (act_issue && await_act) await_act <= 1'b0;
    end
  ap_trp : assert property (@(posedge clk) disable iff (!rst_n)
    (act_issue && await_act) |-> (cyc_since_pre >= trp_cap));

  // ---- A-TREF : refresh interval honored while enabled ----
  int unsigned cyc_since_ref;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) cyc_since_ref <= 0;
    else if (ref_issue) cyc_since_ref <= 0;
    else cyc_since_ref <= cyc_since_ref + 1;
  // while auto-refresh is enabled and initialised, a refresh must occur before
  // the interval (+ refresh duration + arbitration slack) elapses.
  ap_tref : assert property (@(posedge clk) disable iff (!rst_n)
    (ctrl_enable && ctrl_refresh_en && init_done)
      |-> (cyc_since_ref <= (t_ref_q + TRFC + 16)));
endmodule
