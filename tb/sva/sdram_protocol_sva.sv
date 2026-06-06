// ---------------------------------------------------------------------------
// sdram_protocol_sva.sv : black-box protocol assertions for the AXI4-Lite CSR
// port and the native req/rsp port. Bound to the DUT (never edited into RTL).
// Implements vplan A-AXIW, A-AXIR, A-REQ, A-RSP, A-INIT.
// Clock/disable are inlined per property for maximum simulator portability.
// ---------------------------------------------------------------------------
module sdram_protocol_sva (
  input logic        clk, rst_n,
  // AXI4-Lite
  input logic        s_axil_awvalid, s_axil_awready,
  input logic [7:0]  s_axil_awaddr,
  input logic        s_axil_wvalid,  s_axil_wready,
  input logic [31:0] s_axil_wdata,
  input logic [3:0]  s_axil_wstrb,
  input logic        s_axil_bvalid,  s_axil_bready,
  input logic [1:0]  s_axil_bresp,
  input logic        s_axil_arvalid, s_axil_arready,
  input logic [7:0]  s_axil_araddr,
  input logic        s_axil_rvalid,  s_axil_rready,
  input logic [1:0]  s_axil_rresp,
  // native
  input logic        req_valid, req_ready, req_we,
  input logic [31:0] req_addr,
  input logic        rsp_valid, rsp_ready,
  input logic [1:0]  rsp_resp,
  // white-box gating
  input logic        init_done, refresh_active
);
  // ---- A-AXIW : write-channel handshake stability ----
  ap_awvalid_stable : assert property (@(posedge clk) disable iff (!rst_n)
    (s_axil_awvalid && !s_axil_awready) |=> s_axil_awvalid);
  ap_awaddr_stable  : assert property (@(posedge clk) disable iff (!rst_n)
    (s_axil_awvalid && !s_axil_awready) |=> $stable(s_axil_awaddr));
  ap_wvalid_stable  : assert property (@(posedge clk) disable iff (!rst_n)
    (s_axil_wvalid && !s_axil_wready) |=> s_axil_wvalid);
  ap_wdata_stable   : assert property (@(posedge clk) disable iff (!rst_n)
    (s_axil_wvalid && !s_axil_wready) |=> $stable(s_axil_wdata) && $stable(s_axil_wstrb));
  ap_bvalid_stable  : assert property (@(posedge clk) disable iff (!rst_n)
    (s_axil_bvalid && !s_axil_bready) |=> s_axil_bvalid);
  ap_bresp_legal    : assert property (@(posedge clk) disable iff (!rst_n)
    s_axil_bvalid |-> (s_axil_bresp inside {2'b00, 2'b11}));

  // ---- A-AXIR : read-channel handshake stability ----
  ap_arvalid_stable : assert property (@(posedge clk) disable iff (!rst_n)
    (s_axil_arvalid && !s_axil_arready) |=> s_axil_arvalid);
  ap_araddr_stable  : assert property (@(posedge clk) disable iff (!rst_n)
    (s_axil_arvalid && !s_axil_arready) |=> $stable(s_axil_araddr));
  ap_rvalid_stable  : assert property (@(posedge clk) disable iff (!rst_n)
    (s_axil_rvalid && !s_axil_rready) |=> s_axil_rvalid);
  ap_rresp_legal    : assert property (@(posedge clk) disable iff (!rst_n)
    s_axil_rvalid |-> (s_axil_rresp inside {2'b00, 2'b11}));

  // ---- A-REQ / A-RSP : native handshake stability ----
  ap_req_stable      : assert property (@(posedge clk) disable iff (!rst_n)
    (req_valid && !req_ready) |=> req_valid);
  ap_req_pay_stable  : assert property (@(posedge clk) disable iff (!rst_n)
    (req_valid && !req_ready) |=> $stable(req_addr) && $stable(req_we));
  ap_rsp_stable      : assert property (@(posedge clk) disable iff (!rst_n)
    (rsp_valid && !rsp_ready) |=> rsp_valid);
  ap_rsp_resp_legal  : assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid |-> (rsp_resp inside {2'b00, 2'b10}));

  // ---- A-INIT : request acceptance gated by init / refresh ----
  ap_req_gated_init    : assert property (@(posedge clk) disable iff (!rst_n)
    !init_done |-> !req_ready);
  ap_req_gated_refresh : assert property (@(posedge clk) disable iff (!rst_n)
    refresh_active |-> !req_ready);
endmodule
