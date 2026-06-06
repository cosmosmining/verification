// ---------------------------------------------------------------------------
// sdram_lite_ctrl.sv : simplified SDRAM-like memory controller (DUT)
//
// See docs/dut_spec.md for the authoritative specification. Provisional
// feature IDs (F-0xx) from that spec are referenced in comments below.
//
// Clean-room RTL. No vendor / OpenTitan code. Single clock domain.
//
// Microarchitecture summary
//   - AXI4-Lite subordinate CSR port (depth-1 per direction).
//   - Native req/rsp valid-ready port feeding an in-order request FIFO.
//   - A single sequential scheduler pops one request at a time, classifies
//     the target bank as page hit / miss / conflict, issues ACTIVATE /
//     PRECHARGE / CAS honoring CSR-programmable tRCD / tRP, and returns an
//     in-order response. Per-bank rows stay open across requests (open-page).
//   - An auto-refresh manager pre-empts at request boundaries to honor tREF.
//   - Out-of-range addresses produce an ERROR response with a sticky flag.
//
// White-box observability (read by bind-in SVA / coverage; never edited):
//   bank_state[b], open_row[b], trcd_cnt, trp_cnt, ref_cnt, q_level,
//   act_issue/pre_issue/cas_issue/ref_issue (one-cycle command pulses),
//   cur_bank, sched_state.
// ---------------------------------------------------------------------------
`default_nettype none

module sdram_lite_ctrl #(
  parameter int DATA_W      = 32,
  parameter int STRB_W      = DATA_W/8,
  parameter int BANKS       = 4,
  parameter int BANK_W      = 2,            // $clog2(BANKS)
  parameter int ROW_W       = 4,            // 16 rows / bank
  parameter int COL_W       = 8,            // 256 words / row
  parameter int ADDR_W      = 32,           // native word-address width
  parameter int AXIL_ADDR_W = 8,            // CSR address width
  parameter int Q_DEPTH     = 8,            // request queue depth
  parameter int TCL         = 2,            // CAS latency (cycles)
  parameter int TRFC        = 8,            // refresh duration (cycles)
  parameter int T_INIT      = 16,           // init delay (cycles)
  parameter int N_INIT_REF  = 2             // refreshes during init
) (
  input  wire                   clk,
  input  wire                   rst_n,

  // ---- AXI4-Lite subordinate CSR port (F-001..F-005) ----
  input  wire                   s_axil_awvalid,
  output wire                   s_axil_awready,
  input  wire [AXIL_ADDR_W-1:0] s_axil_awaddr,
  input  wire [2:0]             s_axil_awprot,
  input  wire                   s_axil_wvalid,
  output wire                   s_axil_wready,
  input  wire [DATA_W-1:0]      s_axil_wdata,
  input  wire [STRB_W-1:0]      s_axil_wstrb,
  output reg                    s_axil_bvalid,
  input  wire                   s_axil_bready,
  output reg  [1:0]             s_axil_bresp,
  input  wire                   s_axil_arvalid,
  output wire                   s_axil_arready,
  input  wire [AXIL_ADDR_W-1:0] s_axil_araddr,
  input  wire [2:0]             s_axil_arprot,
  output reg                    s_axil_rvalid,
  input  wire                   s_axil_rready,
  output reg  [DATA_W-1:0]      s_axil_rdata,
  output reg  [1:0]             s_axil_rresp,

  // ---- Native request port (F-006..F-012) ----
  input  wire                   req_valid,
  output wire                   req_ready,
  input  wire                   req_we,
  input  wire [ADDR_W-1:0]      req_addr,
  input  wire [DATA_W-1:0]      req_wdata,
  input  wire [STRB_W-1:0]      req_wstrb,
  output reg                    rsp_valid,
  input  wire                   rsp_ready,
  output reg  [DATA_W-1:0]      rsp_rdata,
  output reg  [1:0]             rsp_resp,

  // ---- Interrupt (F-029) ----
  output wire                   irq
);

  // -------------------------------------------------------------------------
  // Local constants
  // -------------------------------------------------------------------------
  localparam int IDX_W       = BANK_W + ROW_W + COL_W;          // 14
  localparam int CAP_WORDS   = (1 << IDX_W);                    // 16384
  localparam logic [1:0] RESP_OKAY  = 2'b00;
  localparam logic [1:0] RESP_DECERR= 2'b11;
  localparam logic [15:0] TREF_MIN  = 16'(TRFC + 8);  // min legal refresh interval
  localparam logic [1:0] NRESP_OKAY = 2'b00;
  localparam logic [1:0] NRESP_ERROR= 2'b10;

  // CSR byte offsets
  localparam logic [AXIL_ADDR_W-1:0] A_CTRL   = 8'h00;
  localparam logic [AXIL_ADDR_W-1:0] A_STATUS = 8'h04;
  localparam logic [AXIL_ADDR_W-1:0] A_TRCD   = 8'h08;
  localparam logic [AXIL_ADDR_W-1:0] A_TRP    = 8'h0C;
  localparam logic [AXIL_ADDR_W-1:0] A_TREF   = 8'h10;
  localparam logic [AXIL_ADDR_W-1:0] A_ERRST  = 8'h14;
  localparam logic [AXIL_ADDR_W-1:0] A_ERRADDR= 8'h18;
  localparam logic [AXIL_ADDR_W-1:0] A_SCRATCH= 8'h1C;

  // Per-bank FSM, one-hot (F-016, F-028)
  localparam logic [3:0] BK_IDLE   = 4'b0001;
  localparam logic [3:0] BK_ACTING = 4'b0010;   // ACTIVATING
  localparam logic [3:0] BK_ACTIVE = 4'b0100;
  localparam logic [3:0] BK_PRECHG = 4'b1000;   // PRECHARGING

  // Scheduler FSM
  typedef enum logic [3:0] {
    S_OFF       = 4'd0,
    S_INIT_WAIT = 4'd1,
    S_INIT_REF  = 4'd2,
    S_IDLE      = 4'd3,
    S_DECODE    = 4'd4,
    S_PRE       = 4'd5,
    S_ACT       = 4'd6,
    S_CAS       = 4'd7,
    S_RESP      = 4'd8,
    S_REF_PRE   = 4'd9,
    S_REF_RUN   = 4'd10
  } sched_e;

  // -------------------------------------------------------------------------
  // CSR registers
  // -------------------------------------------------------------------------
  reg                ctrl_enable, ctrl_refresh_en, ctrl_irq_en;
  reg [3:0]          t_rcd_q, t_rp_q;
  reg [15:0]         t_ref_q;
  reg                err_range;          // ERR_STATUS[0], sticky (F-023)
  reg [ADDR_W-1:0]   err_addr_q;         // ERR_ADDR (F-024)
  reg                err_addr_valid;     // first-error latch guard
  reg [DATA_W-1:0]   scratch_q;

  // -------------------------------------------------------------------------
  // Memory + bank state
  // -------------------------------------------------------------------------
  reg [DATA_W-1:0]   mem [0:CAP_WORDS-1];
  reg [3:0]          bank_state [0:BANKS-1];
  reg [ROW_W-1:0]    open_row   [0:BANKS-1];

  // -------------------------------------------------------------------------
  // Request FIFO (in-order, F-008/F-009)
  // -------------------------------------------------------------------------
  localparam int QPTR_W = (Q_DEPTH <= 1) ? 1 : $clog2(Q_DEPTH);
  localparam logic [QPTR_W-1:0] Q_LAST = QPTR_W'(Q_DEPTH - 1);
  reg                qe_we   [0:Q_DEPTH-1];
  reg [ADDR_W-1:0]   qe_addr [0:Q_DEPTH-1];
  reg [DATA_W-1:0]   qe_data [0:Q_DEPTH-1];
  reg [STRB_W-1:0]   qe_strb [0:Q_DEPTH-1];
  reg [QPTR_W-1:0]   q_head, q_tail;
  reg [QPTR_W:0]     q_level;            // 0..Q_DEPTH
  wire q_full  = (q_level == Q_DEPTH[QPTR_W:0]);
  wire q_empty = (q_level == 0);

  // -------------------------------------------------------------------------
  // Scheduler / timing / refresh state
  // -------------------------------------------------------------------------
  sched_e            sched_state;
  reg [BANK_W-1:0]   cur_bank;
  reg [ROW_W-1:0]    cur_row;
  reg [IDX_W-1:0]    cur_index;
  reg                cur_we;
  reg [DATA_W-1:0]   cur_wdata, cur_rdata;
  reg [STRB_W-1:0]   cur_strb;
  reg                cur_oor;
  reg [ADDR_W-1:0]   cur_addr;

  reg [4:0]          trcd_cnt, trp_cnt;     // activate / precharge timers
  reg [4:0]          cas_cnt;               // CAS latency timer
  reg [5:0]          init_cnt;              // init delay / refresh-count
  reg [4:0]          trfc_cnt;              // refresh duration timer
  reg [2:0]          init_ref_cnt;          // refreshes left in init

  reg [15:0]         ref_cnt;               // refresh interval down-counter
  reg                refresh_pending;
  reg                refresh_active;
  reg                init_done;

  // White-box command pulses (for SVA / coverage)
  reg                act_issue, pre_issue, cas_issue, ref_issue;

  // -------------------------------------------------------------------------
  // Address decode (F-010, F-022)
  // -------------------------------------------------------------------------
  function automatic logic is_oor(input logic [ADDR_W-1:0] a);
    return |a[ADDR_W-1:IDX_W];
  endfunction
  function automatic logic [BANK_W-1:0] dec_bank(input logic [ADDR_W-1:0] a);
    return a[COL_W+ROW_W +: BANK_W];
  endfunction
  function automatic logic [ROW_W-1:0] dec_row(input logic [ADDR_W-1:0] a);
    return a[COL_W +: ROW_W];
  endfunction
  function automatic logic [IDX_W-1:0] dec_index(input logic [ADDR_W-1:0] a);
    return a[IDX_W-1:0];
  endfunction

  // -------------------------------------------------------------------------
  // Native request accept (decoupled from scheduler via FIFO)
  // req_ready: enabled, initialized, queue has room, not refreshing (F-006)
  // -------------------------------------------------------------------------
  assign req_ready = ctrl_enable & init_done & ~q_full & ~refresh_active;
  wire   req_fire  = req_valid & req_ready;

  assign irq = err_range & ctrl_irq_en;   // level interrupt (F-029)

  // =========================================================================
  // AXI4-Lite CSR access (depth-1 per direction)  (F-001..F-005)
  // =========================================================================
  // Write side
  reg aw_seen, w_seen;
  reg [AXIL_ADDR_W-1:0] awaddr_q;
  reg [DATA_W-1:0]      wdata_q;
  reg [STRB_W-1:0]      wstrb_q;

  // Combinational AXI-Lite readies (deassert the same cycle the beat is captured)
  assign s_axil_awready = ~aw_seen & ~s_axil_bvalid;
  assign s_axil_wready  = ~w_seen  & ~s_axil_bvalid;
  assign s_axil_arready = ~s_axil_rvalid;

  wire do_write = (aw_seen | (s_axil_awvalid & s_axil_awready)) &
                  (w_seen  | (s_axil_wvalid  & s_axil_wready));

  // Read side
  reg [DATA_W-1:0] status_word;
  always_comb begin
    status_word              = '0;
    status_word[0]           = init_done;
    status_word[1]           = ~q_empty | (sched_state != S_IDLE && sched_state != S_OFF);
    status_word[2]           = refresh_pending;
    status_word[3]           = q_full;
    status_word[4]           = q_empty;
    status_word[8  +: BANKS] = { (bank_state[3]==BK_ACTIVE),
                                 (bank_state[2]==BK_ACTIVE),
                                 (bank_state[1]==BK_ACTIVE),
                                 (bank_state[0]==BK_ACTIVE) };
  end

  // -------------------------------------------------------------------------
  // CSR write decode helper
  // -------------------------------------------------------------------------
  task automatic csr_write(input logic [AXIL_ADDR_W-1:0] addr,
                           input logic [DATA_W-1:0]      data,
                           input logic [STRB_W-1:0]      strb,
                           output logic [1:0]            resp);
    // byte-merge for partial writes
    resp = RESP_OKAY;
    unique case (addr)
      A_CTRL: begin
        if (strb[0]) begin
          ctrl_enable     <= data[0];
          ctrl_refresh_en <= data[1];
          ctrl_irq_en     <= data[2];
        end
      end
      A_TRCD:   if (strb[0]) t_rcd_q <= (data[3:0] == 4'd0) ? 4'd1 : data[3:0]; // clamp min 1
      A_TRP:    if (strb[0]) t_rp_q  <= (data[3:0] == 4'd0) ? 4'd1 : data[3:0];
      A_TREF: begin
        if (strb[0] | strb[1]) begin
          logic [15:0] nv = data[15:0];
          t_ref_q <= (nv < TREF_MIN) ? TREF_MIN : nv;                           // clamp min
        end
      end
      A_ERRST:  if (strb[0] && data[0]) begin err_range <= 1'b0; err_addr_valid <= 1'b0; end // W1C
      A_SCRATCH: begin
        for (int b = 0; b < STRB_W; b++)
          if (strb[b]) scratch_q[b*8 +: 8] <= data[b*8 +: 8];
      end
      A_STATUS, A_ERRADDR: ; // RO: ignore writes, OKAY
      default: resp = RESP_DECERR;                                              // F-005
    endcase
  endtask

  // -------------------------------------------------------------------------
  // CSR read mux
  // -------------------------------------------------------------------------
  function automatic logic [DATA_W-1:0] csr_read(input logic [AXIL_ADDR_W-1:0] addr,
                                                 output logic [1:0] resp);
    resp = RESP_OKAY;
    unique case (addr)
      A_CTRL:    return {29'd0, ctrl_irq_en, ctrl_refresh_en, ctrl_enable};
      A_STATUS:  return status_word;
      A_TRCD:    return {28'd0, t_rcd_q};
      A_TRP:     return {28'd0, t_rp_q};
      A_TREF:    return {16'd0, t_ref_q};
      A_ERRST:   return {31'd0, err_range};
      A_ERRADDR: return err_addr_q;
      A_SCRATCH: return scratch_q;
      default: begin resp = RESP_DECERR; return '0; end
    endcase
  endfunction

  // =========================================================================
  // Sequential logic
  // =========================================================================
  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // ---- reset all state (F-025: no leak) ----
      s_axil_bvalid   <= 1'b0;  s_axil_bresp  <= RESP_OKAY;
      s_axil_rvalid   <= 1'b0;
      s_axil_rdata    <= '0;    s_axil_rresp  <= RESP_OKAY;
      aw_seen <= 1'b0; w_seen <= 1'b0;
      awaddr_q <= '0; wdata_q <= '0; wstrb_q <= '0;

      ctrl_enable <= 1'b0; ctrl_refresh_en <= 1'b0; ctrl_irq_en <= 1'b0;
      t_rcd_q <= 4'd3; t_rp_q <= 4'd3; t_ref_q <= 16'd1024;
      err_range <= 1'b0; err_addr_q <= '0; err_addr_valid <= 1'b0;
      scratch_q <= '0;

      rsp_valid <= 1'b0; rsp_rdata <= '0; rsp_resp <= NRESP_OKAY;

      for (i = 0; i < BANKS; i++) begin
        bank_state[i] <= BK_IDLE;
        open_row[i]   <= '0;
      end
      q_head <= '0; q_tail <= '0; q_level <= '0;

      sched_state <= S_OFF;
      cur_bank <= '0; cur_row <= '0; cur_index <= '0;
      cur_we <= 1'b0; cur_wdata <= '0; cur_rdata <= '0; cur_strb <= '0; cur_oor <= 1'b0;
      cur_addr <= '0;
      trcd_cnt <= '0; trp_cnt <= '0; cas_cnt <= '0;
      init_cnt <= '0; trfc_cnt <= '0; init_ref_cnt <= '0;
      ref_cnt <= '0; refresh_pending <= 1'b0; refresh_active <= 1'b0;
      init_done <= 1'b0;
      act_issue <= 1'b0; pre_issue <= 1'b0; cas_issue <= 1'b0; ref_issue <= 1'b0;
    end else begin
      // default one-cycle pulses
      act_issue <= 1'b0; pre_issue <= 1'b0; cas_issue <= 1'b0; ref_issue <= 1'b0;

      // ===================================================================
      // AXI4-Lite write channel
      // ===================================================================
      if (s_axil_awvalid && s_axil_awready) begin
        awaddr_q <= s_axil_awaddr; aw_seen <= 1'b1;
      end
      if (s_axil_wvalid && s_axil_wready) begin
        wdata_q <= s_axil_wdata; wstrb_q <= s_axil_wstrb; w_seen <= 1'b1;
      end
      if (do_write && !s_axil_bvalid) begin
        logic [AXIL_ADDR_W-1:0] a = aw_seen ? awaddr_q : s_axil_awaddr;
        logic [DATA_W-1:0]      d = w_seen  ? wdata_q  : s_axil_wdata;
        logic [STRB_W-1:0]      s = w_seen  ? wstrb_q  : s_axil_wstrb;
        logic [1:0] wr;
        csr_write(a, d, s, wr);
        s_axil_bresp  <= wr;
        s_axil_bvalid <= 1'b1;
        aw_seen <= 1'b0; w_seen <= 1'b0;
      end
      if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 1'b0;

      // ===================================================================
      // AXI4-Lite read channel
      // ===================================================================
      if (s_axil_arvalid && s_axil_arready) begin
        logic [1:0] rr;
        s_axil_rdata  <= csr_read(s_axil_araddr, rr);
        s_axil_rresp  <= rr;
        s_axil_rvalid <= 1'b1;
      end
      if (s_axil_rvalid && s_axil_rready) s_axil_rvalid <= 1'b0;

      // ===================================================================
      // Request FIFO push (F-006/F-009)
      // ===================================================================
      if (req_fire) begin
        qe_we  [q_tail] <= req_we;
        qe_addr[q_tail] <= req_addr;
        qe_data[q_tail] <= req_wdata;
        qe_strb[q_tail] <= req_wstrb;
        q_tail <= (q_tail == Q_LAST) ? '0 : q_tail + 1'b1;
      end

      // ===================================================================
      // Refresh interval counter (F-019)
      // ===================================================================
      if (ctrl_enable && ctrl_refresh_en && init_done && !refresh_active) begin
        if (ref_cnt != 0) ref_cnt <= ref_cnt - 1'b1;
        else              refresh_pending <= 1'b1;
      end

      // ===================================================================
      // Scheduler FSM
      // ===================================================================
      unique case (sched_state)
        // ------------------------------------------------- OFF / init
        S_OFF: begin
          init_done <= 1'b0;
          if (ctrl_enable) begin
            init_cnt    <= T_INIT[5:0];
            sched_state <= S_INIT_WAIT;
          end
        end
        S_INIT_WAIT: begin
          if (!ctrl_enable) sched_state <= S_OFF;
          else if (init_cnt != 0) init_cnt <= init_cnt - 1'b1;
          else begin
            init_ref_cnt <= N_INIT_REF[2:0];
            trfc_cnt     <= TRFC[4:0];
            ref_issue    <= 1'b1;
            sched_state  <= S_INIT_REF;
          end
        end
        S_INIT_REF: begin
          if (trfc_cnt != 0) trfc_cnt <= trfc_cnt - 1'b1;
          else if (init_ref_cnt > 1) begin
            init_ref_cnt <= init_ref_cnt - 1'b1;
            trfc_cnt     <= TRFC[4:0];
            ref_issue    <= 1'b1;
          end else begin
            init_done   <= 1'b1;
            ref_cnt     <= t_ref_q;
            sched_state <= S_IDLE;
          end
        end

        // ------------------------------------------------- idle / dispatch
        S_IDLE: begin
          if (!ctrl_enable) sched_state <= S_OFF;
          else if (refresh_pending) begin
            // close all banks before refresh (F-020/F-021)
            refresh_active <= 1'b1;
            trp_cnt <= {1'b0, t_rp_q} ;
            for (i = 0; i < BANKS; i++)
              if (bank_state[i] != BK_IDLE) begin
                bank_state[i] <= BK_PRECHG;
              end
            pre_issue   <= 1'b1;
            sched_state <= S_REF_PRE;
          end else if (!q_empty) begin
            // pop head
            logic [ADDR_W-1:0] a = qe_addr[q_head];
            cur_we    <= qe_we[q_head];
            cur_wdata <= qe_data[q_head];
            cur_strb  <= qe_strb[q_head];
            cur_oor   <= is_oor(a);
            cur_bank  <= dec_bank(a);
            cur_row   <= dec_row(a);
            cur_index <= dec_index(a);
            cur_addr  <= a;
            sched_state <= S_DECODE;
          end
        end

        // ------------------------------------------------- classify (F-013/14/15)
        S_DECODE: begin
          if (cur_oor) begin
            // out-of-range: error response, no memory/bank effect (F-022/23/24)
            err_range <= 1'b1;
            if (!err_addr_valid) begin
              err_addr_q     <= cur_addr;
              err_addr_valid <= 1'b1;
            end
            cur_rdata <= '0;
            rsp_resp  <= NRESP_ERROR;
            sched_state <= S_RESP;
          end else if (bank_state[cur_bank] == BK_ACTIVE &&
                       open_row[cur_bank] == cur_row) begin
            cas_cnt     <= TCL[4:0];          // page hit
            cas_issue   <= 1'b1;
            sched_state <= S_CAS;
          end else if (bank_state[cur_bank] == BK_ACTIVE) begin
            bank_state[cur_bank] <= BK_PRECHG; // page conflict -> precharge first
            trp_cnt     <= {1'b0, t_rp_q};
            pre_issue   <= 1'b1;
            sched_state <= S_PRE;
          end else begin
            bank_state[cur_bank] <= BK_ACTING; // page miss (idle) -> activate
            open_row[cur_bank]   <= cur_row;
            trcd_cnt    <= {1'b0, t_rcd_q};
            act_issue   <= 1'b1;
            sched_state <= S_ACT;
          end
        end

        // ------------------------------------------------- precharge wait (F-018)
        S_PRE: begin
          if (trp_cnt != 0) trp_cnt <= trp_cnt - 1'b1;
          else begin
            bank_state[cur_bank] <= BK_ACTING;
            open_row[cur_bank]   <= cur_row;
            trcd_cnt    <= {1'b0, t_rcd_q};
            act_issue   <= 1'b1;
            sched_state <= S_ACT;
          end
        end

        // ------------------------------------------------- activate wait (F-017)
        S_ACT: begin
          if (trcd_cnt != 0) trcd_cnt <= trcd_cnt - 1'b1;
          else begin
            bank_state[cur_bank] <= BK_ACTIVE;
            cas_cnt     <= TCL[4:0];
            cas_issue   <= 1'b1;
            sched_state <= S_CAS;
          end
        end

        // ------------------------------------------------- CAS + data latency
        S_CAS: begin
          if (cas_cnt != 0) cas_cnt <= cas_cnt - 1'b1;
          else begin
            // perform access at CAS completion
            if (cur_we) begin
              for (int b = 0; b < STRB_W; b++)
                if (cur_strb[b]) mem[cur_index][b*8 +: 8] <= cur_wdata[b*8 +: 8];
              cur_rdata <= '0;
            end else begin
              cur_rdata <= mem[cur_index];
            end
            rsp_resp    <= NRESP_OKAY;
            sched_state <= S_RESP;
          end
        end

        // ------------------------------------------------- response (F-007/F-008)
        S_RESP: begin
          rsp_valid <= 1'b1;
          rsp_rdata <= cur_rdata;
          if (rsp_valid && rsp_ready) begin
            rsp_valid <= 1'b0;
            // advance queue head
            q_head <= (q_head == Q_LAST) ? '0 : q_head + 1'b1;
            sched_state <= S_IDLE;
          end
        end

        // ------------------------------------------------- refresh: precharge all
        S_REF_PRE: begin
          if (trp_cnt != 0) trp_cnt <= trp_cnt - 1'b1;
          else begin
            for (i = 0; i < BANKS; i++) bank_state[i] <= BK_IDLE;
            trfc_cnt    <= TRFC[4:0];
            ref_issue   <= 1'b1;
            sched_state <= S_REF_RUN;
          end
        end
        // ------------------------------------------------- refresh: run tRFC
        S_REF_RUN: begin
          if (trfc_cnt != 0) trfc_cnt <= trfc_cnt - 1'b1;
          else begin
            refresh_active  <= 1'b0;
            refresh_pending <= 1'b0;
            ref_cnt         <= t_ref_q;
            sched_state     <= S_IDLE;
          end
        end
        default: sched_state <= S_OFF;
      endcase

      // ---- queue level bookkeeping (push/pop combined) ----
      case ({req_fire, (sched_state==S_RESP && rsp_valid && rsp_ready)})
        2'b10: q_level <= q_level + 1'b1;
        2'b01: q_level <= q_level - 1'b1;
        default: ; // 00 or 11 -> unchanged
      endcase
    end
  end

endmodule

`default_nettype wire
