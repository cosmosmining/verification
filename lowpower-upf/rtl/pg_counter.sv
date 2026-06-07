// ===========================================================================
// pg_counter — switchable counter core with MODELLED retention + isolation.
//
// In a real low-power flow the retention and isolation CELLS are inferred from
// the UPF (see ../upf/pg_top.upf) and inserted by the implementation tool. No
// license-free simulator consumes UPF, so here those cells are modelled
// explicitly in RTL and driven by the PMU, making the isolation/retention
// power sequence simulatable on a 4-state simulator (Icarus Verilog).
//
// 4-state matters: a powered-down core register is driven to X, and the whole
// point of the isolation cell is to stop that X reaching the always-on domain.
// A 2-state simulator (Verilator) cannot show that, which is why this project
// uses Icarus.
//
// Injected power-gating bugs are guarded by `PG_BUG_*` (see bugs/run_bug_demo.sh).
// ===========================================================================
`timescale 1ns/1ps
module pg_counter #(
    parameter integer W = 8
)(
    input  wire          clk,
    input  wire          rst_n,     // always-on reset
    input  wire          en,        // functional count enable
    // ---- power-intent controls, driven by the always-on PMU ----
    input  wire          pwr_on,    // 1 = core powered, 0 = power-gated
    input  wire          save,      // pulse: snapshot state into retention
    input  wire          restore,   // pulse: reload state from retention
    input  wire          iso_en,    // 1 = isolate core outputs (clamp)
    output wire [W-1:0]  cnt_obs    // isolated observation into the AON domain
);

    // Switchable core register: loses state (-> X) while power-gated.
    reg [W-1:0] cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        cnt <= {W{1'b0}};
        else if (!pwr_on)  cnt <= {W{1'bx}};   // gated: non-retained state unknown
        else if (restore)  cnt <= cnt_ret;     // retention restore on wake
        else if (en)       cnt <= cnt + 1'b1;
    end

    // Retention shadow: lives in the always-on supply, survives power-down.
    reg [W-1:0] cnt_ret;
`ifdef PG_BUG_RET
    // BUG: retention storage is never updated on `save`, so the core wakes with
    // stale/zero state — state is silently lost across the power cycle.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt_ret <= {W{1'b0}};
    end
`else
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      cnt_ret <= {W{1'b0}};
        else if (save)   cnt_ret <= cnt;
    end
`endif

    // Isolation cell on the core output to the always-on domain.
`ifdef PG_BUG_ISO
    // BUG: isolation removed — the gated core's X drives straight into the AON
    // domain whenever the core is off.
    assign cnt_obs = cnt;
`else
    assign cnt_obs = iso_en ? {W{1'b0}} : cnt;   // clamp to 0 when isolated
`endif

endmodule
