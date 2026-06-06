# `sdram_lite_ctrl` — DUT Specification (M0)

| Field          | Value                                                        |
|----------------|--------------------------------------------------------------|
| Block          | `sdram_lite_ctrl`                                            |
| Version        | 0.1 (draft, awaiting approval)                              |
| Status         | **M0 — for review.** No RTL written yet.                     |
| Target RTL size| ~600–900 lines SystemVerilog                                 |
| Author         | Verification lead (clean-room; no vendor/OpenTitan VIP)      |

> **Purpose of this document.** Define the behavior of the DUT precisely enough
> that (a) the RTL can be written from it, (b) the verification plan (`docs/vplan.md`,
> M2) can trace every feature to tests/coverage/assertions, and (c) an untimed
> SystemVerilog reference model can predict read data, responses, and legal
> bank-timing windows. Every named feature below carries a provisional **F-ID**
> that the vplan will adopt verbatim.

---

## 1. Overview & Scope

### 1.1 What it is
`sdram_lite_ctrl` is a simplified, self-contained synchronous memory controller
with SDRAM-like bank/page/timing semantics. It exposes:

- an **AXI4-Lite subordinate** port for control/status registers (CSRs), and
- a **native request port** (`req`/`rsp` valid/ready handshakes) for memory traffic.

Internally it manages **4 banks**, each with an **open-page** (open-row) policy,
a per-bank state machine, CSR-programmable **activate / precharge / refresh**
timing (`tRCD` / `tRP` / `tREF`), an **in-order request queue**, an **auto-refresh**
manager, and **error responses** for out-of-range addresses.

Storage is modeled by an internal synchronous memory array so that read data is
deterministic and predictable by the scoreboard. The "SDRAM-ness" lives in the
*timing*, *bank/page management*, and *scheduling*, not in modeling DRAM cell
physics or an external DDR PHY.

### 1.2 Why this shape
- Small enough to verify near-exhaustively (few rows ⇒ page conflicts are common
  under random addressing) yet complex enough to hide realistic bugs.
- Two dissimilar interfaces (AXI4-Lite + native) exercise reusable agents, a RAL
  model, and virtual sequences across interfaces.
- Programmable timing + refresh + error flags create natural corners for
  constrained-random coverage and assertion-based checks.

### 1.3 Feature summary (provisional F-IDs → vplan, M2)

| F-ID  | Feature                                                                   |
|-------|---------------------------------------------------------------------------|
| F-001 | AXI4-Lite write channel handshake (AW/W/B) protocol compliance             |
| F-002 | AXI4-Lite read channel handshake (AR/R) protocol compliance               |
| F-003 | CSR read/write semantics per register map (RW / RO / W1C / reserved)       |
| F-004 | CSR reset (default) values                                                |
| F-005 | Decode error (`DECERR`) on access to undefined CSR offset                  |
| F-006 | Native request handshake (`req_valid`/`req_ready`) incl. back-pressure     |
| F-007 | Native response handshake (`rsp_valid`/`rsp_ready`) incl. back-pressure    |
| F-008 | In-order responses (response order == request order)                       |
| F-009 | Request queue fill/drain; `QUEUE_FULL`/`QUEUE_EMPTY` status                 |
| F-010 | Address decode into {bank, row, column}                                    |
| F-011 | Write with byte strobes (`req_wstrb`) — partial-word update                |
| F-012 | Read returns last-written data (with byte granularity)                     |
| F-013 | Open-page **page hit** (same bank, same open row) — fast path              |
| F-014 | **Page miss** (bank idle) — ACTIVATE then access                           |
| F-015 | **Page conflict** (bank active, different row) — PRECHARGE, ACTIVATE, access|
| F-016 | Per-bank FSM legal transitions (IDLE/ACTIVATING/ACTIVE/PRECHARGING)        |
| F-017 | `tRCD` honored: no CAS (READ/WRITE) until tRCD after ACTIVATE              |
| F-018 | `tRP` honored: no ACTIVATE until tRP after PRECHARGE                        |
| F-019 | `tREF` honored: auto-refresh issued within the programmed interval         |
| F-020 | Auto-refresh closes all banks (rows closed) and stalls traffic during tRFC |
| F-021 | Refresh vs. request arbitration (in-flight request completes first)        |
| F-022 | Out-of-range address ⇒ `ERROR` response, no memory side effect             |
| F-023 | `ERR_STATUS` sticky range-error flag; W1C clear                            |
| F-024 | `ERR_ADDR` latches the first offending address until cleared               |
| F-025 | Reset returns all FSMs/queue/CSRs to defaults (no state leak)              |
| F-026 | Enable→init sequence; `INIT_DONE`; requests stalled until init complete    |
| F-027 | Mid-traffic CSR reprogramming of timing takes effect at next command       |
| F-028 | One-hot / legal-encoding per-bank state (white-box invariant)              |
| F-029 | `irq` asserts on enabled error condition; gated by `CTRL.IRQ_EN`           |

### 1.4 Out of scope (explicit non-features)
- No external DDR/SDR PHY, DQS, ODT, mode-register training, or I/O timing.
- Single clock domain — **no CDC** between AXI-Lite and native ports.
- AXI4-Lite only (no bursts, no `AxSIZE`/`AxLEN`, no exclusive access, no `AxCACHE`).
- No ECC, no write data masking beyond byte strobes, no reordering / out-of-order
  completion (in-order only — see §13 for the OoO thought experiment).
- No power-down / self-refresh / clock-stop low-power states.

---

## 2. Parameters

| Parameter      | Default | Meaning / constraint                                              |
|----------------|---------|------------------------------------------------------------------|
| `DATA_W`       | 32      | Data width (AXI-Lite and native). Fixed at 32 for v0.1.          |
| `STRB_W`       | 4       | `= DATA_W/8`. Byte-strobe width.                                 |
| `BANKS`        | 4       | Number of banks. `BANK_W = $clog2(BANKS) = 2`.                   |
| `ROW_W`        | 4       | Row-address bits ⇒ 16 rows/bank (few rows ⇒ frequent conflicts). |
| `COL_W`        | 8       | Column-address bits ⇒ 256 words/row.                            |
| `ADDR_W`       | 32      | Native request address width (word address).                    |
| `AXIL_ADDR_W`  | 8       | AXI4-Lite address width (CSR space, 4-byte stride).             |
| `Q_DEPTH`      | 8       | In-order request queue depth.                                   |
| `TCL`          | 2       | CAS latency (cycles from CAS issue to data), fixed param.       |
| `TRFC`         | 8       | Refresh duration in cycles, fixed param.                        |
| `T_INIT`       | 16      | Init delay (cycles) after `ENABLE` before init refreshes.       |
| `N_INIT_REF`   | 2       | Number of refreshes issued during initialization.               |

**Derived capacity.** `CAPACITY_WORDS = BANKS * 2**ROW_W * 2**COL_W = 4*16*256 = 16384` words.
Usable word-address range is `[0, CAPACITY_WORDS)`. Any address `>= CAPACITY_WORDS`
(equivalently, any set bit above `BANK_W+ROW_W+COL_W-1 = 13`) is **out of range**.

> Note: `tRCD`, `tRP`, `tREF` are **runtime CSR-programmable** (§4), not parameters.
> `TCL`/`TRFC` are compile-time parameters in v0.1; promoting them to CSRs is a
> documented future extension (does not change the verification architecture).

---

## 3. Interfaces

### 3.1 Clock & Reset
| Signal  | Dir | Width | Description                                                  |
|---------|-----|-------|--------------------------------------------------------------|
| `clk`   | in  | 1     | Single clock for all ports and the core.                     |
| `rst_n` | in  | 1     | Active-low reset. **Asynchronous assert, synchronous deassert.** All flops reset to defaults. |

### 3.2 AXI4-Lite CSR subordinate port (prefix `s_axil_`)
Standard AXI4-Lite, `DATA_W=32`, `AXIL_ADDR_W=8`. No bursts.

| Channel | Signals                                                                 |
|---------|-------------------------------------------------------------------------|
| AW      | `s_axil_awvalid` (in), `s_axil_awready` (out), `s_axil_awaddr[7:0]` (in), `s_axil_awprot[2:0]` (in) |
| W       | `s_axil_wvalid` (in), `s_axil_wready` (out), `s_axil_wdata[31:0]` (in), `s_axil_wstrb[3:0]` (in) |
| B       | `s_axil_bvalid` (out), `s_axil_bready` (in), `s_axil_bresp[1:0]` (out)   |
| AR      | `s_axil_arvalid` (in), `s_axil_arready` (out), `s_axil_araddr[7:0]` (in), `s_axil_arprot[2:0]` (in) |
| R       | `s_axil_rvalid` (out), `s_axil_rready` (in), `s_axil_rdata[31:0]` (out), `s_axil_rresp[1:0]` (out) |

**Response codes** (`bresp`/`rresp`): `OKAY=2'b00`, `SLVERR=2'b10`, `DECERR=2'b11`.
- Access to an **undefined offset** ⇒ `DECERR` (F-005).
- Write to a **read-only** register ⇒ `OKAY`, write ignored (no side effect).
- `awprot`/`arprot` are accepted and ignored (no protection checking in v0.1).

**Ordering rules.** AW and W may arrive in any order / same cycle; the write commits
when both have been accepted. One outstanding transaction per direction is supported
(depth-1); the controller may accept the next address only after the corresponding
response handshake. (A simple, fully-specified subset — easy to assert.)

### 3.3 Native request port (prefix `req_` / `rsp_`)
| Signal       | Dir | Width    | Description                                                |
|--------------|-----|----------|------------------------------------------------------------|
| `req_valid`  | in  | 1        | Request present.                                           |
| `req_ready`  | out | 1        | Controller can accept this cycle (de-asserts on back-pressure / queue full / init / refresh). |
| `req_we`     | in  | 1        | 1 = write, 0 = read.                                       |
| `req_addr`   | in  | `ADDR_W` | **Word** address.                                          |
| `req_wdata`  | in  | `DATA_W` | Write data (ignored for reads).                            |
| `req_wstrb`  | in  | `STRB_W` | Per-byte write enable (ignored for reads).                |
| `rsp_valid`  | out | 1        | Response present.                                          |
| `rsp_ready`  | in  | 1        | Master can accept the response this cycle.                 |
| `rsp_rdata`  | out | `DATA_W` | Read data (`0` for writes).                               |
| `rsp_resp`   | out | 2        | `OKAY=2'b00`, `ERROR=2'b10` (out-of-range).               |

**Handshake semantics (both channels): standard valid/ready.** A beat transfers on
the rising edge where `valid && ready`. Once `valid` is asserted it must remain
asserted with stable payload until `ready` (no payload change, no withdrawal).
`req_ready`/`rsp_ready` may be de-asserted freely (back-pressure). These rules are
checked by bind-in SVA (F-006, F-007).

**In-order guarantee (F-008).** Responses are emitted in exactly the order requests
were accepted, including error responses (an out-of-range request still consumes its
ordered response slot).

---

## 4. CSR Register Map

Byte offsets, 32-bit registers, 4-byte stride. `AXIL_ADDR_W=8` ⇒ offsets `0x00–0xFF`;
only those listed are defined (others ⇒ `DECERR`).

| Offset | Name         | Access | Reset       | Fields                                                                                 |
|--------|--------------|--------|-------------|----------------------------------------------------------------------------------------|
| 0x00   | `CTRL`       | RW     | 0x0000_0000 | `[0] ENABLE`, `[1] REFRESH_EN`, `[2] IRQ_EN`, `[31:3]` reserved (RAZ/WI)               |
| 0x04   | `STATUS`     | RO     | 0x0000_0010 | `[0] INIT_DONE`, `[1] BUSY`, `[2] REFRESH_PENDING`, `[3] QUEUE_FULL`, `[4] QUEUE_EMPTY`, `[11:8] BANK_ACTIVE[3:0]` |
| 0x08   | `T_RCD`      | RW     | 0x0000_0003 | `[3:0] tRCD` cycles (legal 1–15)                                                       |
| 0x0C   | `T_RP`       | RW     | 0x0000_0003 | `[3:0] tRP` cycles (legal 1–15)                                                        |
| 0x10   | `T_REF`      | RW     | 0x0000_0400 | `[15:0] tREF` refresh interval in cycles (legal ≥ `TRFC+8`; default 1024)              |
| 0x14   | `ERR_STATUS` | W1C    | 0x0000_0000 | `[0] RANGE_ERR` (sticky, write-1-to-clear), `[31:1]` reserved                          |
| 0x18   | `ERR_ADDR`   | RO     | 0x0000_0000 | `[ADDR_W-1:0]` first offending word address since last clear                           |
| 0x1C   | `SCRATCH`    | RW     | 0x0000_0000 | `[31:0]` general-purpose scratch (no hardware effect; used for RAL bit-bash sanity)    |

**Notes for RAL (M4).**
- `RW` registers (`CTRL`, `T_RCD`, `T_RP`, `T_REF`, `SCRATCH`) ⇒ exercised by
  `uvm_reg_bit_bash_seq` / `uvm_reg_access_seq`.
- `RO` registers (`STATUS`, `ERR_ADDR`) ⇒ `uvm_reg_hw_reset_seq` checks reset value;
  predicted by the reference model, not written by RAL.
- `ERR_STATUS` is `W1C` (model with `uvm_reg_field` access `W1C`).
- Reserved bits read as 0 and ignore writes (RAZ/WI) — covered by access tests.
- **`STATUS` reset = 0x10** because `QUEUE_EMPTY=1` out of reset (`[4]`), `INIT_DONE=0`.

**Timing-CSR legality.** Writing 0 to `T_RCD`/`T_RP` is illegal; hardware clamps to 1
(minimum 1 cycle). Writing `T_REF < TRFC+8` clamps to `TRFC+8`. Clamping behavior is a
defined, testable feature (and a deliberate corner for coverage).

---

## 5. Address Decoding & Memory Organization

Native **word** address `req_addr[ADDR_W-1:0]` decodes as:

```
 bit:  ADDR_W-1 ........ 14 13 12 .... 8 7 ........ 0
       [   out-of-range  ][ bank ][   row   ][   col   ]
                            2 bits   4 bits     8 bits
 col  = req_addr[COL_W-1 : 0]                 = req_addr[7:0]
 row  = req_addr[COL_W+ROW_W-1 : COL_W]       = req_addr[11:8]
 bank = req_addr[COL_W+ROW_W+BANK_W-1 : COL_W+ROW_W] = req_addr[13:12]
 oor  = | req_addr[ADDR_W-1 : COL_W+ROW_W+BANK_W]     (any upper bit set)
```

- Storage is a flat behavioral array `mem[0 : CAPACITY_WORDS-1]` of `DATA_W` bits,
  byte-writable via `req_wstrb`.
- "Open page" = the currently-activated **row** within a bank. The controller keeps,
  per bank, an `open_row[bank]` register and a validity bit (bank ACTIVE).

---

## 6. Per-Bank State Machine (F-016, F-028)

Each of the 4 banks has an independent FSM. Encoding is one-hot (white-box
invariant asserted in M5). Refresh is a controller-level overlay (§9) that forces
all banks through PRECHARGE→IDLE.

```
            ACTIVATE (scheduler)                 tRCD elapsed
   IDLE  ───────────────────────►  ACTIVATING  ───────────────►  ACTIVE
    ▲                                                              │
    │                                                             │ CAS (READ/WRITE),
    │  tRP elapsed                                                 │ page hit stays ACTIVE
    │                                                             │
 PRECHARGING ◄──────────────────────────────────────────────────┘
        PRECHARGE (page conflict, or refresh, or idle close)
```

| State        | Meaning                                  | Legal exits                                            |
|--------------|------------------------------------------|--------------------------------------------------------|
| `IDLE`       | No open row (precharged).                | →`ACTIVATING` on ACTIVATE.                              |
| `ACTIVATING` | ACTIVATE issued, counting `tRCD`.        | →`ACTIVE` when tRCD counter expires.                    |
| `ACTIVE`     | Row open; CAS allowed.                    | stays `ACTIVE` on page hit; →`PRECHARGING` on conflict/refresh/close. |
| `PRECHARGING`| PRECHARGE issued, counting `tRP`.        | →`IDLE` when tRP counter expires.                       |

**Open-page policy:** after a CAS, the bank remains `ACTIVE` with its row open (no
auto-precharge). A later access to the same {bank,row} is a **page hit**.

---

## 7. Command Scheduling & Page Policy

Single in-order scheduler. Per accepted request (head of queue), the scheduler
inspects the target bank state and `open_row`:

| Condition                                   | Classification | Command sequence before CAS         |
|---------------------------------------------|----------------|-------------------------------------|
| bank `ACTIVE` and `open_row==row`           | **page hit** (F-013)    | none — issue CAS directly  |
| bank `IDLE`                                 | **page miss** (F-014)   | ACTIVATE, wait `tRCD`, CAS |
| bank `ACTIVE` and `open_row!=row`           | **page conflict** (F-015)| PRECHARGE, wait `tRP`, ACTIVATE, wait `tRCD`, CAS |
| bank `ACTIVATING`/`PRECHARGING`             | stall          | wait for in-progress timing to finish, then re-classify |

- **CAS phase:** READ returns data `TCL` cycles after CAS issue; WRITE commits at CAS
  issue (byte-masked by `req_wstrb`) and reports completion after `TCL` (uniform latency
  keeps the response pipe simple and in-order). `rsp_resp=OKAY`.
- **Out-of-range** head request (F-022): no command issued, no bank state change, no
  memory write; emit `rsp_resp=ERROR`, set `ERR_STATUS.RANGE_ERR`, latch `ERR_ADDR`
  (first only), assert `irq` if enabled. The error still consumes its in-order slot.
- The scheduler processes one request to completion (CAS or error) before advancing,
  preserving in-order responses. Refresh may pre-empt only at request boundaries (§9).

---

## 8. Timing Parameters & Rules

All counters are in `clk` cycles. "≥ N after X" means at least N cycles must elapse
between event X and the gated event (inclusive count model defined below).

| Param   | Source     | Rule (assertion target)                                                            |
|---------|------------|------------------------------------------------------------------------------------|
| `tRCD`  | `T_RCD` CSR| No CAS to bank *b* until ≥ `tRCD` cycles after that bank's ACTIVATE (F-017).        |
| `tRP`   | `T_RP` CSR | No ACTIVATE to bank *b* until ≥ `tRP` cycles after that bank's PRECHARGE (F-018).   |
| `tREF`  | `T_REF` CSR| A refresh must be issued at least every `tREF` cycles while enabled (F-019).        |
| `TCL`   | param      | READ data valid `TCL` cycles after CAS; response latency for R and W (F-012).      |
| `TRFC`  | param      | Refresh occupies the controller for `TRFC` cycles; no CAS during refresh (F-020).  |

**Counting convention (to be matched exactly by RTL and reference model).** A timing
counter is loaded with `N` on the cycle the triggering command is issued and
decrements each subsequent cycle; the gated command becomes legal on the cycle the
counter reaches 0. Thus ACTIVATE at cycle *t* with `tRCD=3` ⇒ earliest CAS at cycle
*t+3*. This precise convention is the natural home for **off-by-one** bugs (M6) and is
asserted directly.

---

## 9. Refresh (F-019, F-020, F-021)

- A down-counter `ref_cnt` loads `T_REF` and decrements each cycle while
  `ENABLE & REFRESH_EN & INIT_DONE`. Reaching 0 sets `STATUS.REFRESH_PENDING`.
- At the next **request boundary** (no CAS in flight), the refresh manager:
  1. PRECHARGEs every `ACTIVE`/`ACTIVATING` bank (respecting `tRP` from any just-issued
     precharge), driving all banks to `IDLE`;
  2. issues a REFRESH that occupies `TRFC` cycles (`req_ready=0`, no CAS);
  3. reloads `ref_cnt=T_REF`, clears `REFRESH_PENDING`. All banks remain `IDLE`
     (rows closed) afterward — the next access to any bank is necessarily a page miss.
- An in-flight request's CAS completes before refresh begins (in-order preserved).
- Refresh has priority over new requests once pending (prevents starvation/`tREF` miss).

---

## 10. Error Handling (F-022, F-023, F-024, F-029)

| Condition                | Response / effect                                                         |
|--------------------------|---------------------------------------------------------------------------|
| Native out-of-range addr | `rsp_resp=ERROR`; no memory effect; `ERR_STATUS.RANGE_ERR←1` (sticky); `ERR_ADDR←addr` if not already set since last clear; `irq←1` if `CTRL.IRQ_EN`. |
| Undefined CSR offset     | `bresp`/`rresp = DECERR`; no register side effect.                         |
| Write to RO register     | `bresp = OKAY`; ignored.                                                   |
| Illegal timing value     | Clamped to legal (§4); access still `OKAY`.                                |

`ERR_STATUS.RANGE_ERR` is **sticky**: it remains set until software writes 1 to clear
(W1C). `irq` is a level output = `(RANGE_ERR & CTRL.IRQ_EN)`. (The "sticky error flag"
and "interrupt never clears" are classic injected-bug targets for M6.)

---

## 11. Reset & Initialization (F-025, F-026)

**Reset (`rst_n=0`).** All CSRs → reset values (§4), all bank FSMs → `IDLE`,
`open_row` invalid, request queue flushed/empty, `ref_cnt` idle, `INIT_DONE=0`,
`irq=0`, all `*_ready` outputs to safe defaults, all `*_valid` outputs deasserted.
No state may survive reset ("reset leak" is a deliberate M6 bug class — F-025).

**Initialization (software sets `CTRL.ENABLE` 0→1).**
1. `BUSY=1`, `req_ready=0` (requests stalled).
2. Wait `T_INIT` cycles.
3. PRECHARGE all banks (already idle), then issue `N_INIT_REF` refreshes.
4. Set `STATUS.INIT_DONE=1`, `BUSY` reflects queue activity thereafter.

Requests presented before `INIT_DONE` are **not** accepted (`req_ready=0`). Clearing
`ENABLE` returns the controller to an un-initialized, quiescent state (queue must be
empty; behavior with a non-empty queue at disable is defined as: finish draining then
go idle).

---

## 12. Latency Model (reference-model summary)

Cycle counts from CAS-eligible scheduling, excluding queue wait and refresh stalls:

| Scenario                  | Pre-CAS cycles            | + data           | Total (defaults tRCD=tRP=3, TCL=2) |
|---------------------------|---------------------------|------------------|-------------------------------------|
| Page hit                  | 0                         | `TCL`            | 2                                   |
| Page miss (bank idle)     | `tRCD`                    | `TCL`            | 5                                   |
| Page conflict             | `tRP + tRCD`              | `TCL`            | 8                                   |
| + refresh collision       | add `(precharge) + TRFC`  | —                | scenario-dependent                  |

The reference model (M4) computes expected `rsp_rdata`, `rsp_resp`, and the **legal
window** for each issued bank command; the scoreboard checks data/response/order while
bind-in SVA checks the per-command timing legality. The passive timing/refresh monitor
feeds both.

---

## 13. Verification Hooks (white-box observability)

The RTL will expose these internal signals (plain module-internal nets/regs, readable
by bind-in SVA and coverage — **no RTL edits for verification**):

| Signal (hierarchical)          | Use                                                       |
|--------------------------------|-----------------------------------------------------------|
| `bank_state[b]` (enum, one-hot)| FSM transition coverage; one-hot assertion (F-028).       |
| `open_row[b]`, `bank_active[b]`| page hit/miss/conflict classification coverage.           |
| `trcd_cnt[b]`, `trp_cnt[b]`    | timing-corner coverage; off-by-one assertions.            |
| `ref_cnt`, `refresh_active`    | refresh-interval assertion; refresh-collision coverage.   |
| `q_level` (queue occupancy)    | queue-occupancy coverage (0..`Q_DEPTH`).                  |
| `cmd_issue` (ACT/PRE/REF/CAS)  | command-type coverage; cross(page_state × cmd).           |

**Out-of-order thought experiment (for the M0 quiz / future extension):** if responses
were allowed to complete out of order, the scoreboard would change from a FIFO compare
to a **tag-indexed associative** model (predict by transaction ID, match on completion
ID), and an extra "all issued IDs eventually complete exactly once" check would be
needed. v0.1 is strictly in-order, so a FIFO scoreboard suffices.

---

## 14. Assumptions & Simplifications
1. Single clock, single reset; async-assert/sync-deassert reset.
2. One outstanding AXI-Lite transaction per direction (depth-1 CSR port).
3. Native port is word-granular; sub-word writes via `req_wstrb` only.
4. Uniform `TCL` latency for reads and writes keeps the response pipe in-order/simple.
5. Internal behavioral memory models storage; no external PHY/DDR signaling.
6. Timing values are small integers (cycles), enabling exhaustive corner coverage.
7. `TCL`, `TRFC`, `T_INIT`, `N_INIT_REF` are compile-time params in v0.1.

---

## 15. Open Questions / Decisions for Approval

Please confirm or redirect before I write RTL (M1):

1. **Memory size.** 4 banks × 16 rows × 256 cols = 16 K words (64 KB). Small rows make
   page conflicts frequent under random stimulus. OK, or prefer different dims?
2. **Uniform write latency = `TCL`.** I made writes report completion after `TCL`
   (like reads) for an in-order, single-latency response pipe. Acceptable, or do you
   want writes to retire in 1 cycle (adds a small reorder/merge concern)?
3. **Timing-value clamping vs. SLVERR.** Illegal `T_RCD/T_RP/T_REF` writes are *clamped*
   (and that's a tested corner). Alternative: return `SLVERR` and reject. Preference?
4. **AXI-Lite depth-1.** I specified one outstanding transaction per direction to keep
   the CSR protocol assertions crisp. OK, or do you want pipelined CSR accesses?
5. **Scope of `tRAS`/`tRC`.** I deliberately left `tRAS` (ACT→PRE min) and `tRC`
   (ACT→ACT) out to keep the headline timing set to `tRCD/tRP/tREF` per the brief.
   Want me to add `tRAS` as a 4th programmable timing (richer corners + 1 more assertion)?

---

### Revision history
| Ver  | Date       | Change                          |
|------|------------|---------------------------------|
| 0.1  | 2026-06-06 | Initial draft for M0 approval.  |
