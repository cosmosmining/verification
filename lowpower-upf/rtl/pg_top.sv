// ===========================================================================
// pg_top — integration of the always-on PMU + the switchable counter core.
//
// Power domains (see ../upf/pg_top.upf):
//   PD_TOP  (always-on) : pmu, the retention shadow, the isolation cell
//   PD_CORE (switchable): the counter register (gated by the PMU power switch)
//
// White-box power-intent signals (pwr_on/iso_en/save/restore/is_asleep) are
// brought to the top so the cocotb scoreboard can predict cnt_obs exactly and
// check both isolation (no X into the AON domain) and retention (state survives
// the power cycle).
// ===========================================================================
`timescale 1ns/1ps
module pg_top #(
    parameter integer W = 8
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          en,         // functional count enable
    input  wire          sleep_req,  // 1 = sleep, 0 = wake
    output wire [W-1:0]  cnt_obs,    // isolated observation (AON domain)
    output wire          is_asleep,
    // white-box observability for the verification scoreboard
    output wire          pwr_on,
    output wire          iso_en,
    output wire          save,
    output wire          restore
);
    pg_pmu u_pmu (
        .clk(clk), .rst_n(rst_n), .sleep_req(sleep_req),
        .pwr_on(pwr_on), .iso_en(iso_en), .save(save),
        .restore(restore), .is_asleep(is_asleep)
    );

    // Functional enable is frozen once isolation asserts, so the value saved
    // into retention is exactly the value the AON domain last observed.
    pg_counter #(.W(W)) u_core (
        .clk(clk), .rst_n(rst_n),
        .en(en & pwr_on & ~iso_en),
        .pwr_on(pwr_on), .save(save), .restore(restore), .iso_en(iso_en),
        .cnt_obs(cnt_obs)
    );
endmodule
