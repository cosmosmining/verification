// ===========================================================================
// pg_pmu — always-on power-management sequencer for PD_CORE.
//
// Implements the canonical power-gating handshake:
//   sleep:  isolate -> save (retain) -> power OFF
//   wake:   power ON -> restore (retain) -> de-isolate
//
// The ORDER is the whole game in low-power verification: isolation must be
// asserted before power is removed and released only after power+retention are
// back, or the always-on domain samples X. The `PG_BUG_SEQ` hook deliberately
// powers the core off before isolating to exercise that failure.
// ===========================================================================
`timescale 1ns/1ps
module pg_pmu (
    input  wire clk,
    input  wire rst_n,
    input  wire sleep_req,     // 1 = request sleep, 0 = request wake
    output reg  pwr_on,
    output reg  iso_en,
    output reg  save,
    output reg  restore,
    output reg  is_asleep
);
    localparam [2:0] S_ACTIVE  = 3'd0,
                     S_ISO     = 3'd1,
                     S_SAVE    = 3'd2,
                     S_OFF     = 3'd3,
                     S_ON      = 3'd4,
                     S_RESTORE = 3'd5,
                     S_DEISO   = 3'd6;
    reg [2:0] st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_ACTIVE; pwr_on <= 1'b1; iso_en <= 1'b0;
            save <= 1'b0; restore <= 1'b0; is_asleep <= 1'b0;
        end else begin
            save <= 1'b0; restore <= 1'b0;          // 1-cycle pulses
            case (st)
                S_ACTIVE: if (sleep_req) begin
`ifdef PG_BUG_SEQ
                    pwr_on <= 1'b0;                 // BUG: power off BEFORE isolating
`else
                    iso_en <= 1'b1;                 // isolate first
`endif
                    st <= S_ISO;
                end
                S_ISO: begin
`ifdef PG_BUG_SEQ
                    iso_en <= 1'b1;                 // (too late: core already gated -> X leaked)
`endif
                    save <= 1'b1;                   // snapshot for retention
                    st <= S_SAVE;
                end
                S_SAVE: begin
                    pwr_on <= 1'b0; is_asleep <= 1'b1;
                    st <= S_OFF;
                end
                S_OFF: if (!sleep_req) begin
                    pwr_on <= 1'b1;                 // power back on
                    st <= S_ON;
                end
                S_ON: begin
                    restore <= 1'b1;                // reload retained state
                    st <= S_RESTORE;
                end
                S_RESTORE: begin
                    is_asleep <= 1'b0;
                    st <= S_DEISO;
                end
                S_DEISO: begin
                    iso_en <= 1'b0;                 // de-isolate last
                    st <= S_ACTIVE;
                end
                default: st <= S_ACTIVE;
            endcase
        end
    end
endmodule
