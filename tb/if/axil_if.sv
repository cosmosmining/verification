// AXI4-Lite interface for the sdram_lite_ctrl CSR port.
// Clocking blocks give race-free sampling (preponed) and driving.
interface axil_if #(parameter int AW = 8, parameter int DW = 32)
                   (input logic clk, input logic rst_n);
  localparam int SW = DW/8;

  logic            awvalid, awready;
  logic [AW-1:0]   awaddr;
  logic [2:0]      awprot;
  logic            wvalid,  wready;
  logic [DW-1:0]   wdata;
  logic [SW-1:0]   wstrb;
  logic            bvalid,  bready;
  logic [1:0]      bresp;
  logic            arvalid, arready;
  logic [AW-1:0]   araddr;
  logic [2:0]      arprot;
  logic            rvalid,  rready;
  logic [DW-1:0]   rdata;
  logic [1:0]      rresp;

  // Master (driver) clocking block
  clocking mst_cb @(posedge clk);
    default input #1step output #1;
    output awvalid, awaddr, awprot, wvalid, wdata, wstrb, bready,
           arvalid, araddr, arprot, rready;
    input  awready, wready, bvalid, bresp, arready, rvalid, rdata, rresp;
  endclocking

  // Passive monitor clocking block
  clocking mon_cb @(posedge clk);
    default input #1step;
    input awvalid, awready, awaddr, awprot, wvalid, wready, wdata, wstrb,
          bvalid, bready, bresp, arvalid, arready, araddr, arprot,
          rvalid, rready, rdata, rresp;
  endclocking

  modport mst (clocking mst_cb, input clk, rst_n);
  modport mon (clocking mon_cb, input clk, rst_n);
endinterface
