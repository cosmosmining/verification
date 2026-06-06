# Verification Plan — `sdram_lite_ctrl`

| Field   | Value                                                       |
|---------|-------------------------------------------------------------|
| DUT     | `sdram_lite_ctrl` (see `docs/dut_spec.md`)                  |
| Method  | UVM 1.2 constrained-random + coverage-driven + ABV, with a license-free cocotb/Verilator mirror for scoreboard-level checks |
| Sign-off| 100% of the defined functional-coverage model + all assertions passing across the regression seed set; every waiver justified here |

This plan is the single source of truth for traceability. **Every covergroup,
assertion, and test in the code carries its F-ID in a header comment** so the
table below can be regenerated/audited. Feature IDs are inherited verbatim from
the DUT spec (F-001 … F-029).

---

## 1. Methodology & environment

- **Agents** (reusable VIP, clean-room):
  - `axi_lite_agent` — active master on the CSR port; drives RAL accesses.
  - `mem_req_agent` — active master on the native `req`/`rsp` port.
  - `timing_monitor` — passive; observes bank commands, timing counters,
    refresh, and feeds coverage + the scoreboard's timing predictor.
- **RAL** models the CSR map; built-in sequences (`uvm_reg_hw_reset_seq`,
  `uvm_reg_bit_bash_seq`, `uvm_reg_access_seq`) provide register-level checks.
- **Scoreboard** holds an untimed SV reference model predicting read data,
  response codes, and (for the timing predictor) legal bank-command windows.
- **Virtual sequencer / virtual sequences** coordinate CSR + native traffic for
  cross-interface scenarios (e.g. reprogram timing mid-traffic).
- **Assertions** live in **bind** files (`tb/sva/*.sv`) — never edited into RTL.
- **Mirror**: `sim/cocotb` re-implements the data/response/ordering checks in
  Python so the scoreboard logic is cross-validated license-free.

---

## 2. Functional coverage model

Covergroups are sampled by the passive monitors / scoreboard. Target = 100% of
all bins below unless a waiver row in §5 applies.

| CG ID  | Covergroup            | Coverpoints / bins                                                                 | Sampled on                |
|--------|-----------------------|------------------------------------------------------------------------------------|---------------------------|
| CG-BNK | `cg_bank_state`       | per-bank state {IDLE,ACTIVATING,ACTIVE,PRECHARGING}; **transitions** IDLE→ACT→ACTIVE→PRE→IDLE | bank FSM change           |
| CG-PG  | `cg_page`             | page outcome {HIT, MISS, CONFLICT}                                                  | each CAS dispatch         |
| CG-CMD | `cg_cmd`              | command {ACTIVATE, PRECHARGE, CAS_RD, CAS_WR, REFRESH}                              | command issue pulse       |
| CG-PGC | `cg_page_x_cmd`       | **cross** CG-PG × {CAS_RD, CAS_WR}                                                  | each CAS dispatch         |
| CG-TM  | `cg_timing`           | `tRCD` {1,2,3,mid,15}; `tRP` {1,2,3,mid,15}; `tREF` {min,small,default,large}       | at command using the value|
| CG-Q   | `cg_queue`            | queue occupancy bins {0,1,2..,Q_DEPTH-1,FULL}; full-then-drain                      | every clk while enabled   |
| CG-RSP | `cg_resp`            | native {OKAY,ERROR}; axi {OKAY,DECERR}; read-vs-write × resp                        | each response             |
| CG-ADR | `cg_addr`             | bank {0..3}; row hot/cold bins; col low/high; **oor vs in-range**                  | each accepted request     |
| CG-STB | `cg_wstrb`            | wstrb {0x0,0x1,0x3,0x7,0xF,single-byte,others}                                      | each write CAS            |
| CG-REF | `cg_refresh`          | banks-active-at-refresh {0,1,2,3,4}; refresh-vs-request collision                   | each refresh              |
| CG-RST | `cg_reset_traffic`    | reset asserted while {idle, queue non-empty, CAS in flight, refresh active}         | reset edge                |

---

## 3. Assertion list (bind-in SVA, `tb/sva/`)

| SVA ID  | Property                                                                 | Bound module / scope         |
|---------|-------------------------------------------------------------------------|------------------------------|
| A-AXIW  | AW/W/B: `*valid` stable + payload held until `*ready`; one B per write   | `sdram_axil_sva` on CSR port |
| A-AXIR  | AR/R: handshake stability; `rresp∈{OKAY,DECERR}`                         | `sdram_axil_sva`             |
| A-REQ   | `req_valid` stable & payload held until `req_ready`                      | `sdram_req_sva`              |
| A-RSP   | `rsp_valid` stable & payload held until `rsp_ready`; deasserts after     | `sdram_req_sva`              |
| A-TRCD  | no `cas_issue` to bank *b* within `tRCD` cycles after its `act_issue`    | `sdram_timing_sva` (white-box)|
| A-TRP   | no `act_issue` to bank *b* within `tRP` cycles after its `pre_issue`     | `sdram_timing_sva`           |
| A-TREF  | gap between consecutive `ref_issue` ≤ `t_ref` (+slack) while enabled     | `sdram_timing_sva`           |
| A-1HOT  | `$onehot(bank_state[b])` always                                          | `sdram_timing_sva`           |
| A-NCDR  | no `cas_issue` while `refresh_active`                                    | `sdram_timing_sva`           |
| A-INIT  | `req_ready` low until `init_done`; low during `refresh_active`           | `sdram_req_sva`              |
| A-ERRS  | once `err_range` set, stays set until a W1C write to `ERR_STATUS`        | `sdram_csr_sva`              |
| A-ORD   | native responses are in request order (tag check)                       | scoreboard (model-level)     |

---

## 4. Test list (`+UVM_TESTNAME`)

| Test                              | Intent                                                            |
|-----------------------------------|------------------------------------------------------------------|
| `sdram_base_test`                 | env build/connect; no stimulus (sanity of TB wiring)             |
| `sdram_smoke_test`                | a handful of directed write/read; quick green                    |
| `sdram_reg_test`                  | RAL built-in seqs: hw_reset, bit-bash, access                    |
| `sdram_random_test`               | constrained-random mixed traffic (knobs: locality, back-pressure)|
| `sdram_locality_test`             | high page-hit rate (hammer open rows)                            |
| `sdram_backpressure_test`         | dense `req`/`rsp` back-pressure; queue full/drain                |
| `sdram_illegal_addr_test`         | out-of-range bursts; error + sticky flag + ERR_ADDR              |
| `sdram_refresh_collision_test`    | small `tREF`; refresh colliding with active banks                |
| `sdram_allbanks_thrash_test`      | round-robin all 4 banks, alternating rows → constant conflicts   |
| `sdram_reset_during_traffic_test` | assert reset mid-traffic; verify clean recovery (no leak)        |
| `sdram_csr_reprogram_test`        | reprogram `tRCD/tRP/tREF` mid-traffic via virtual sequence       |

---

## 5. Master traceability matrix

> Legend: tests are abbreviated (base, smoke, reg, rand, loc, bp, illegal,
> refcol, thrash, rsttfc, reprog). “mirror” = the cocotb test that also covers it.

| F-ID  | Feature (short)                         | Tests                          | Coverage         | Assertions      | Mirror              |
|-------|-----------------------------------------|--------------------------------|------------------|-----------------|---------------------|
| F-001 | AXI-Lite write handshake                | reg, rand, smoke               | CG-RSP           | A-AXIW          | csr_sanity          |
| F-002 | AXI-Lite read handshake                 | reg, rand, smoke               | CG-RSP           | A-AXIR          | csr_sanity          |
| F-003 | CSR RW/RO/W1C semantics                 | reg                            | CG-RSP           | A-ERRS          | csr_sanity          |
| F-004 | CSR reset values                        | reg (hw_reset)                 | —                | —               | csr_sanity          |
| F-005 | DECERR on undefined offset              | reg, illegal                   | CG-RSP(axi)      | A-AXIR          | csr_sanity          |
| F-006 | Native req handshake + back-pressure    | bp, rand                       | CG-Q             | A-REQ, A-INIT   | smoke_random        |
| F-007 | Native rsp handshake + back-pressure    | bp, rand                       | CG-Q             | A-RSP           | smoke_random        |
| F-008 | In-order responses                      | rand, bp, thrash               | —                | A-ORD           | smoke/wr_rd_directed|
| F-009 | Queue fill/drain + status               | bp                             | CG-Q             | —               | smoke_random        |
| F-010 | Address decode {bank,row,col}           | rand, thrash                   | CG-ADR           | —               | wr_rd_directed      |
| F-011 | Byte-strobe partial writes              | rand                           | CG-STB           | —               | smoke_random        |
| F-012 | Read returns last-written data          | smoke, rand, loc               | CG-PGC           | A-ORD           | wr_rd_directed      |
| F-013 | Page hit fast path                      | loc, rand                      | CG-PG(HIT)       | —               | wr_rd_directed      |
| F-014 | Page miss (activate)                    | rand, thrash                   | CG-PG(MISS)      | A-TRCD          | wr_rd_directed      |
| F-015 | Page conflict (precharge+activate)      | thrash, rand                   | CG-PG(CONFLICT)  | A-TRP, A-TRCD   | wr_rd_directed      |
| F-016 | Per-bank FSM legal transitions          | rand, thrash                   | CG-BNK           | A-1HOT          | (implicit)          |
| F-017 | tRCD honored                            | rand, reprog                   | CG-TM(tRCD)      | A-TRCD          | (timing→UVM only)   |
| F-018 | tRP honored                             | thrash, reprog                 | CG-TM(tRP)       | A-TRP           | (timing→UVM only)   |
| F-019 | tREF honored                            | refcol, reprog                 | CG-TM(tREF)      | A-TREF          | (timing→UVM only)   |
| F-020 | Refresh closes banks / stalls           | refcol                         | CG-REF           | A-NCDR          | (implicit)          |
| F-021 | Refresh vs request arbitration          | refcol, rand                   | CG-REF           | A-NCDR          | smoke_random        |
| F-022 | Out-of-range → ERROR, no side effect    | illegal, rand                  | CG-RSP, CG-ADR   | —               | smoke_random        |
| F-023 | Sticky range-error flag (W1C)           | illegal                        | CG-RSP           | A-ERRS          | csr_sanity          |
| F-024 | ERR_ADDR latches first offender         | illegal                        | —                | —               | (UVM)               |
| F-025 | Reset clears all state (no leak)        | rsttfc                         | CG-RST           | —               | (UVM)               |
| F-026 | Enable→init; req gated until INIT_DONE   | base, smoke                    | —                | A-INIT          | configure()         |
| F-027 | Mid-traffic CSR reprogram               | reprog                         | CG-TM            | A-TRCD, A-TRP   | (UVM)               |
| F-028 | One-hot / legal FSM encoding            | rand, thrash                   | CG-BNK           | A-1HOT          | (UVM)               |
| F-029 | IRQ on enabled error                    | illegal                        | CG-RSP           | —               | configure(irq)      |

---

## 6. Coverage closure plan & waivers

- Drive `cg_*` to 100% using the seed set in `scripts/regress.py` (parallel
  seeds). Directed tests fill corners the random tests miss (thrash → conflicts,
  refcol → refresh collisions, reprog → timing corners).
- **Planned waivers (justified, not silent):**
  - `CG-TM tRCD/tRP = 15` (max) — exercised only by the directed `reprog` test;
    not reachable by default random ranges (knob-limited to ≤ 6 for sim speed).
    *Waiver:* covered explicitly by `sdram_csr_reprogram_test`, not waived away.
  - `CG-RST {CAS in flight}` — narrow timing window; hit by `rsttfc` with seeded
    reset offsets, not a blanket exclude.
  - `cg_bank_state` transition IDLE→PRECHARGING is **illegal** (must pass through
    ACTIVE) → declared an `illegal_bins`, so it is excluded by construction and
    additionally guarded by A-1HOT / FSM legality, not counted against closure.

No coverpoint is silently excluded; any `illegal_bins`/`ignore_bins` is listed
here with rationale.

---

## 7. Bug-hunt linkage (M6)

The injected-bug campaign (`docs/bug_log.md`) demonstrates the plan catches real
defects. Each bug is tagged with the F-ID it violates and whether it was caught
by an **assertion** or the **scoreboard** (or both) — the headline metric for the
resume bullets.
