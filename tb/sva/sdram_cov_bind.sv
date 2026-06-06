// ---------------------------------------------------------------------------
// sdram_cov_bind.sv : bind the white-box coverage module into the DUT.
// UVM filelist only (tb/sdram.f) -- not part of the Verilator/cocotb build.
// ---------------------------------------------------------------------------
bind sdram_lite_ctrl sdram_cov #(.BANKS(BANKS)) u_cov (
  .clk(clk), .rst_n(rst_n),
  .act_issue(act_issue), .pre_issue(pre_issue), .cas_issue(cas_issue), .ref_issue(ref_issue),
  .bank_state(bank_state), .cur_bank(cur_bank), .cur_we(cur_we),
  .t_rcd_q(t_rcd_q), .t_rp_q(t_rp_q), .t_ref_q(t_ref_q),
  .q_level(q_level), .refresh_active(refresh_active)
);
