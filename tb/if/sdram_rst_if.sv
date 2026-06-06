// Test-controllable reset. tb_top ANDs this with power-on reset, so a test can
// pulse rst_n low mid-traffic (reset-during-traffic scenario) without fighting
// the power-on reset driver.
interface sdram_rst_if (input logic clk);
  logic rst_n;
  initial rst_n = 1'b1;          // default: do not gate

  task automatic pulse(int cycles);
    @(posedge clk); rst_n <= 1'b0;
    repeat (cycles) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
  endtask
endinterface
