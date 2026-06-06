// ---------------------------------------------------------------------------
// tb_top.sv : UVM top. clk/reset, interfaces, DUT instance, config_db, run_test.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import sdram_pkg::*;

  // ---- clock ----
  logic clk = 0;
  always #5 clk = ~clk;          // 100 MHz

  // ---- power-on reset, AND-combined with test-controllable reset ----
  logic por_rst_n;
  initial begin
    por_rst_n = 1'b0;
    repeat (6) @(posedge clk);
    por_rst_n = 1'b1;
  end

  sdram_rst_if rst_if(.clk(clk));
  wire rst_n = por_rst_n & rst_if.rst_n;

  // ---- interfaces ----
  axil_if    #(.AW(8),  .DW(32)) axil(.clk(clk), .rst_n(rst_n));
  mem_req_if #(.AW(32), .DW(32)) mem (.clk(clk), .rst_n(rst_n));

  // ---- DUT ----
  sdram_lite_ctrl dut (
    .clk(clk), .rst_n(rst_n),
    .s_axil_awvalid(axil.awvalid), .s_axil_awready(axil.awready),
    .s_axil_awaddr (axil.awaddr),  .s_axil_awprot (axil.awprot),
    .s_axil_wvalid (axil.wvalid),  .s_axil_wready (axil.wready),
    .s_axil_wdata  (axil.wdata),   .s_axil_wstrb  (axil.wstrb),
    .s_axil_bvalid (axil.bvalid),  .s_axil_bready (axil.bready), .s_axil_bresp(axil.bresp),
    .s_axil_arvalid(axil.arvalid), .s_axil_arready(axil.arready),
    .s_axil_araddr (axil.araddr),  .s_axil_arprot (axil.arprot),
    .s_axil_rvalid (axil.rvalid),  .s_axil_rready (axil.rready),
    .s_axil_rdata  (axil.rdata),   .s_axil_rresp  (axil.rresp),
    .req_valid(mem.req_valid), .req_ready(mem.req_ready), .req_we(mem.req_we),
    .req_addr (mem.req_addr),  .req_wdata(mem.req_wdata), .req_wstrb(mem.req_wstrb),
    .rsp_valid(mem.rsp_valid), .rsp_ready(mem.rsp_ready),
    .rsp_rdata(mem.rsp_rdata), .rsp_resp (mem.rsp_resp),
    .irq()
  );

  // ---- publish virtual interfaces, launch UVM ----
  initial begin
    uvm_config_db#(virtual axil_if)    ::set(null, "*", "axil_vif", axil);
    uvm_config_db#(virtual mem_req_if) ::set(null, "*", "mem_vif",  mem);
    uvm_config_db#(virtual sdram_rst_if)::set(null, "*", "rst_vif", rst_if);
    run_test();
  end

  // ---- optional waves: +WAVES ----
  initial begin
    if ($test$plusargs("WAVES")) begin
      $dumpfile("waves.vcd");
      $dumpvars(0, tb_top);
    end
  end

  // ---- global watchdog ----
  initial begin
    #5ms;
    `uvm_fatal("TB_TOP", "global timeout reached")
  end
endmodule
