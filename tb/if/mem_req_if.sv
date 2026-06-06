// Native request/response interface for the sdram_lite_ctrl memory port.
interface mem_req_if #(parameter int AW = 32, parameter int DW = 32)
                     (input logic clk, input logic rst_n);
  localparam int SW = DW/8;

  logic            req_valid, req_ready, req_we;
  logic [AW-1:0]   req_addr;
  logic [DW-1:0]   req_wdata;
  logic [SW-1:0]   req_wstrb;
  logic            rsp_valid, rsp_ready;
  logic [DW-1:0]   rsp_rdata;
  logic [1:0]      rsp_resp;

  // Master (driver) clocking block: drives requests + rsp_ready back-pressure
  clocking mst_cb @(posedge clk);
    default input #1step output #1;
    output req_valid, req_we, req_addr, req_wdata, req_wstrb, rsp_ready;
    input  req_ready, rsp_valid, rsp_rdata, rsp_resp;
  endclocking

  // Passive monitor clocking block
  clocking mon_cb @(posedge clk);
    default input #1step;
    input req_valid, req_ready, req_we, req_addr, req_wdata, req_wstrb,
          rsp_valid, rsp_ready, rsp_rdata, rsp_resp;
  endclocking

  modport mst (clocking mst_cb, input clk, rst_n);
  modport mon (clocking mon_cb, input clk, rst_n);
endinterface
