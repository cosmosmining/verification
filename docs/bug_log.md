# Bug-hunt log — `sdram_lite_ctrl`

Once the environment was green, eight realistic RTL bugs were injected — one at a
time — to demonstrate the testbench catches real defects. Each bug is a small,
revertible mutation of `rtl/sdram_lite_ctrl.sv`, saved as a patch under
[`bugs/patches/`](../bugs/patches/). The driver
[`bugs/run_bug_hunt.py`](../bugs/run_bug_hunt.py) applies each bug, runs the
matching check, confirms it fails, then restores clean RTL via `git checkout`.

> **Single-branch workflow note.** The brief calls for a bug-hunt *branch*; this
> repo's workflow is single-branch, so the bugs live as independent patches
> instead — which is strictly more reproducible (each can be applied/reverted on
> its own and re-run in seconds). Apply one with
> `git apply bugs/patches/bug_03.patch`.

## Result

**8 / 8 caught — 6 by the scoreboard/reference model, 2 by bind-in assertions.**
This split is itself a headline metric: functional defects fall to the untimed
reference model; pure-timing defects (no data/ordering effect) fall to SVA. Raw
auto-generated table: [`bugs/RESULTS.md`](../bugs/RESULTS.md).

| # | Bug (patch)                              | Violates | Caught by                | Domain     |
|---|------------------------------------------|----------|--------------------------|------------|
| 1 | Wrong bank decode                        | F-010    | scoreboard               | functional |
| 2 | Dropped response back-pressure           | F-007    | scoreboard (+ A-RSP)     | functional |
| 3 | tRCD off-by-one                          | F-017    | assertion A-TRCD         | timing     |
| 4 | Error flag not sticky                    | F-023    | scoreboard (`error_flag_sticky`) | functional |
| 5 | Out-of-range returns OKAY                | F-022    | scoreboard               | functional |
| 6 | Byte strobes ignored on write            | F-011    | scoreboard               | functional |
| 7 | Reset leak (err_range survives reset)    | F-025    | scoreboard (`reset_clears_error`) | functional |
| 8 | tREF starved (no auto-refresh)           | F-019    | assertion A-TREF         | timing     |

**Waveform evidence:** every case is reproducible with a dump —
`make smoke WAVES=1` (mirror → `sim/cocotb/dump.vcd`) or
`make uvm SIM=<sim> WAVES=1 ...` (→ `waves.vcd`). Each entry below names the
exact signal relationship to inspect.

---

## Bug 1 — Wrong bank decode (F-010)
- **Patch:** `bugs/patches/bug_01.patch` — `dec_bank` reads `a[COL_W +: BANK_W]`
  (overlapping the row field) instead of `a[COL_W+ROW_W +: BANK_W]`.
- **Symptom:** reads return the wrong word; the directed and random tests report
  `rdata mismatch` because writes and reads resolve to different physical banks.
- **Caught by:** scoreboard (`wr_rd_directed`, `smoke_random`) — reference model
  decodes the bank correctly, DUT does not, so predicted ≠ observed read data.
- **Waveform:** at a CAS, compare `cur_bank`/`cur_index` against `req_addr[13:12]`.
- **Root cause:** bank field sliced from the wrong bit offset.
- **Fix:** restore `a[COL_W+ROW_W +: BANK_W]`.

## Bug 2 — Dropped response back-pressure (F-007)
- **Patch:** `bugs/patches/bug_02.patch` — `S_RESP` advances on `rsp_valid` alone,
  ignoring `rsp_ready`.
- **Symptom:** under response back-pressure the controller retires a response the
  master never accepted; the monitor sees fewer responses than requests →
  `response count != expected`.
- **Caught by:** scoreboard (in-order pairing detects the missing response); the
  bound assertion **A-RSP** (`rsp_valid` must hold until `rsp_ready`) also fires.
- **Waveform:** `rsp_valid` deasserting in a cycle where `rsp_ready==0`.
- **Root cause:** handshake completion gated on `valid` only.
- **Fix:** require `rsp_valid && rsp_ready`.

## Bug 3 — tRCD off-by-one (F-017)
- **Patch:** `bugs/patches/bug_03.patch` — activate loads `trcd_cnt = t_rcd_q - 1`,
  so CAS is issued one cycle early.
- **Symptom:** no functional/data error (read data is still correct), so the
  scoreboard stays silent — this is a **pure timing** defect.
- **Caught by:** assertion **A-TRCD** (`ap_trcd`): the elapsed cycles between
  `act_issue` and the following `cas_issue` drop below the captured `tRCD`.
  Verilator (`make smoke ASSERT=1`) reports `Assertion failed ... ap_trcd`.
- **Waveform:** cycles between `act_issue` and `cas_issue` = `tRCD-1`.
- **Root cause:** off-by-one in the counter preload.
- **Fix:** load `trcd_cnt = {1'b0, t_rcd_q}`.

## Bug 4 — Error flag not sticky (F-023)
- **Patch:** `bugs/patches/bug_04.patch` — the refresh block clears `err_range`
  every enabled cycle, so the sticky range-error flag drops after one cycle.
- **Symptom:** after an out-of-range access the CSR read of `ERR_STATUS` reads 0.
- **Caught by:** scoreboard mirror test `error_flag_sticky`
  (`assert ... "RANGE_ERR not set after out-of-range access"`).
- **Waveform:** `err_range` pulsing high for one cycle then forced low.
- **Root cause:** spurious unconditional clear of a sticky bit.
- **Fix:** remove the clear; `err_range` is set on error and only cleared by W1C.

## Bug 5 — Out-of-range returns OKAY (F-022)
- **Patch:** `bugs/patches/bug_05.patch` — OOR path drives `rsp_resp = OKAY`.
- **Symptom:** an out-of-range request returns `OKAY` instead of `ERROR`.
- **Caught by:** scoreboard (`smoke_random`) — `resp 0 != exp 2` on OOR addresses.
- **Waveform:** `rsp_resp` on a request whose `req_addr >= 0x4000`.
- **Root cause:** wrong response constant on the error path.
- **Fix:** drive `NRESP_ERROR`.

## Bug 6 — Byte strobes ignored on write (F-011)
- **Patch:** `bugs/patches/bug_06.patch` — the CAS write loop drops the
  `if (cur_strb[b])` guard and writes all four bytes unconditionally.
- **Symptom:** partial-word writes corrupt the bytes that should have been
  preserved; later reads mismatch.
- **Caught by:** scoreboard (`smoke_random`) — `rdata mismatch` after a masked write.
- **Waveform:** a write with `req_wstrb != 0xF` updating masked-out byte lanes.
- **Root cause:** byte-enable guard removed.
- **Fix:** restore per-byte `if (cur_strb[b])`.

## Bug 7 — Reset leak: err_range survives reset (F-025)
- **Patch:** `bugs/patches/bug_07.patch` — `err_range` is dropped from the reset
  assignment list.
- **Symptom:** after asserting reset, `ERR_STATUS.RANGE_ERR` is still set from a
  pre-reset error — state leaks across reset.
- **Caught by:** scoreboard mirror test `reset_clears_error`
  (`assert ... "reset leak: ERR_STATUS not cleared by reset"`).
- **Waveform:** `err_range` remaining 1 across the `rst_n` low pulse.
- **Root cause:** missing reset of a state element.
- **Fix:** reset `err_range <= 1'b0`.

## Bug 8 — tREF starved (F-019)
- **Patch:** `bugs/patches/bug_08.patch` — the refresh counter never asserts
  `refresh_pending` (`<= 1'b0`), so auto-refresh never runs.
- **Symptom:** no data error (the behavioral memory does not decay), so the
  scoreboard is silent — another **pure timing** defect.
- **Caught by:** assertion **A-TREF** (`ap_tref`): active cycles since the last
  `ref_issue` exceed `tREF + slack` while refresh is enabled. Verilator reports
  `Assertion failed ... ap_tref`.
- **Waveform:** `ref_issue` never pulses after init while `ctrl_refresh_en==1`.
- **Root cause:** refresh request suppressed.
- **Fix:** assert `refresh_pending <= 1'b1` when the interval counter expires.

---

### Methodology takeaways
- The **untimed reference model** is the workhorse for functional bugs (data,
  response code, ordering, sticky/reset state) — and it is cross-checked by an
  independent Python re-implementation in the cocotb mirror.
- **Assertions** earn their keep on **timing-only** defects that leave data
  correct (bugs 3 and 8) — exactly the bugs a data scoreboard cannot see.
- Keeping each bug as an isolated patch makes the campaign a repeatable
  regression: `python3 bugs/run_bug_hunt.py` re-proves all eight in one run.
