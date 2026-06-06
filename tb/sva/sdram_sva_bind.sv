// ---------------------------------------------------------------------------
// sdram_sva_bind.sv : bind the assertion modules into the DUT.
// Compile AFTER rtl/sdram_lite_ctrl.sv and the SVA modules. No RTL edits.
// ---------------------------------------------------------------------------

bind sdram_lite_ctrl sdram_protocol_sva u_proto_sva (
  .clk(clk), .rst_n(rst_n),
  .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready), .s_axil_awaddr(s_axil_awaddr),
  .s_axil_wvalid (s_axil_wvalid),  .s_axil_wready (s_axil_wready),
  .s_axil_wdata  (s_axil_wdata),   .s_axil_wstrb  (s_axil_wstrb),
  .s_axil_bvalid (s_axil_bvalid),  .s_axil_bready (s_axil_bready), .s_axil_bresp(s_axil_bresp),
  .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready), .s_axil_araddr(s_axil_araddr),
  .s_axil_rvalid (s_axil_rvalid),  .s_axil_rready (s_axil_rready), .s_axil_rresp(s_axil_rresp),
  .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
  .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_resp(rsp_resp),
  .init_done(init_done), .refresh_active(refresh_active)
);

bind sdram_lite_ctrl sdram_timing_sva #(.BANKS(BANKS), .TRFC(TRFC)) u_timing_sva (
  .clk(clk), .rst_n(rst_n),
  .act_issue(act_issue), .pre_issue(pre_issue), .cas_issue(cas_issue), .ref_issue(ref_issue),
  .bank_state(bank_state), .t_rcd_q(t_rcd_q), .t_rp_q(t_rp_q), .t_ref_q(t_ref_q),
  .refresh_active(refresh_active), .init_done(init_done),
  .ctrl_enable(ctrl_enable), .ctrl_refresh_en(ctrl_refresh_en),
  .rsp_valid(rsp_valid), .rsp_ready(rsp_ready)
);
