# sdram_lite_ctrl — UVM Verification Project

A portfolio-grade, clean-room **design-and-verification** project: a simplified
SDRAM-like memory controller (the DUT) plus a reusable **UVM 1.2** environment,
a **license-free cocotb + Verilator** scoreboard mirror that runs in CI, Python
regression/coverage tooling, bind-in **SVA**, and an **injected-bug campaign**.

> Built to exercise the full IP-level DV loop end-to-end: test planning →
> constrained-random + coverage-driven verification → assertion-based
> verification → coverage closure → bug hunt → sign-off docs.

---

## Résumé extraction (for ASIC/DV applications)

**1. What I built** — `sdram_lite_ctrl`, a ~640-line synthesizable SystemVerilog
memory controller: **AXI4-Lite** CSR subordinate + native request/response port,
**4-bank one-hot open-page FSM**, CSR-programmable **tRCD/tRP/tREF** timing, an
auto-refresh manager, an in-order request queue, and out-of-range error handling
with a sticky flag. Verified with a reusable **UVM 1.2** environment: two active
agents (AXI4-Lite master + native master), a **RAL** register model, an untimed
**reference-model scoreboard**, a **virtual sequencer / virtual sequences**, 11
covergroups, and 12 bind-in **SVA** properties — with full traceability from 29
numbered features to tests/coverage/assertions.

**2. Tools & languages** — SystemVerilog (UVM 1.2, SVA, RAL/`uvm_reg`,
constrained-random, functional coverage), Python (cocotb, regression + coverage
tooling), C/C++ (Verilator-generated model), Make, GitHub Actions CI. Simulators:
Verilator (license-free, here) and Questa/VCS/Xcelium/DSim/xsim (UVM campus run).

**3. Quantified results** — **8/8** injected RTL bugs caught (6 by scoreboard, 2
by assertions); **78.7% structural coverage** (toggle 78% / line 75% / branch
89%) merged over a seed sweep in the mirror; clean across a **5-seed** sweep at
**250 constrained-random transactions/seed**; **11 UVM tests + 5 cocotb tests**;
**29 features** traced; **12 SVA** properties + **11 covergroups**; RTL passes
`verilator --lint-only -Wall` with zero warnings.

**4. ATS keywords** — ASIC design verification, SystemVerilog, UVM, OOP,
constrained-random verification, functional coverage, coverage closure,
assertion-based verification (ABV/SVA), bind, RAL (register abstraction layer),
reference model / scoreboard, AMBA **AXI4-Lite** protocol, memory controller,
SDRAM, finite-state machine, pipelining, valid/ready handshake, back-pressure,
reusable verification components / VIP, virtual sequences, test plan, regression,
JUnit, cocotb, Verilator, Python, Makefile, CI, debug/waveform, post-silicon
mindset, tape-out.
> Out of scope here (single clock domain by design): CDC, STA, clock-tree
> synthesis, UPF/low-power. Called out honestly rather than keyword-stuffed.

---

## Architecture

```
                    +--------------------- UVM test ---------------------+
                    |                     sdram_env                      |
  AXI4-Lite  +------+-------+   ap    +----------------------+           |
  CSR  <====>| axi_lite_    |-------->| uvm_reg_predictor    |           |
             | agent (RAL)  |         +----------+-----------+           |
             +--------------+                    | mirror               |
                    |  virtual sequences   +-----v------+                |
   vseqr -----------+  (configure/random/  | sdram RAL  |                |
                    |   thrash/illegal/    +------------+                |
                    |   refcol/reprogram/                                |
  native   +--------+------+   reset)   +------------------+             |
  req/rsp <=| mem_req_     |----------->| mem_req_monitor  |             |
            | agent        |  ap_req/   |  (req + rsp)     |             |
            +--------------+  ap_rsp    +---+----------+---+             |
                    |                       |          |                 |
                    |              +---------v--+  +----v------+          |
                    |              | scoreboard |  | coverage  |          |
                    |              | + refmodel |  | subscriber|          |
                    |              +------------+  +-----------+          |
                    +----------------------------------------------------+
            clk/rst  |                                  ^ bind (no RTL edits)
                     v                                  |
            +--------------------+      +---------------+-----------+
            |  sdram_lite_ctrl   |<-----| sdram_protocol_sva (A-AXI/REQ/RSP)
            |  DUT (~640 lines)  |      | sdram_timing_sva   (A-TRCD/TRP/TREF/1HOT)
            +--------------------+      +---------------------------+

  License-free mirror (runs here + CI):  sim/cocotb  ->  Verilator
     sdram_ref.py (untimed model)  +  tb_smoke.py (BFMs + scoreboard + SVA)
```

The native scheduler is **in-order** and **serialized**: it pops one request,
classifies the target bank as **page hit / miss / conflict**, issues
ACTIVATE/PRECHARGE/CAS honoring the programmed timing, and returns a response —
while per-bank rows stay open across requests (open-page). See
[`docs/dut_spec.md`](docs/dut_spec.md) for the full specification and
[`docs/vplan.md`](docs/vplan.md) for the traceability matrix.

---

## Repository layout

```
docs/    dut_spec.md  vplan.md  bug_log.md          # spec, plan, bug hunt
rtl/     sdram_lite_ctrl.sv                          # the DUT
tb/      if/  pkg/  sva/  tb_top.sv  sdram.f         # UVM env, assertions, top
sim/     cocotb/ (sdram_ref.py, tb_smoke.py, Makefile)   # license-free mirror
scripts/ regress.py  merge_coverage.py  campus_regress.sh
bugs/    run_bug_hunt.py  patches/  RESULTS.md       # injected-bug campaign
Makefile  .github/workflows/ci.yml
```

---

## Quick start

```bash
# license-free (installs nothing exotic: Verilator + cocotb)
pip install -r sim/cocotb/requirements.txt
make smoke                 # cocotb scoreboard mirror on Verilator
make lint                  # Verilator lint of RTL + bound SVA
python3 scripts/regress.py --num-seeds 8 --jobs 4   # parallel regression -> JUnit/HTML
python3 scripts/merge_coverage.py --num-seeds 4     # structural coverage -> HTML
python3 bugs/run_bug_hunt.py                        # inject 8 bugs, prove each caught

# UVM on a campus / license-free-UVM simulator
make uvm SIM=dsim   UVM_TEST=sdram_random_test SEED=1     # or xsim/questa/vcs/xcelium
SIM=questa ./scripts/campus_regress.sh                    # full regression sweep
```

---

## Coverage summary

Functional covergroups (UVM, merged on campus sims) + structural coverage
(Verilator mirror, here):

| Layer                 | Model                                                | Status |
|-----------------------|------------------------------------------------------|--------|
| Functional (UVM)      | 11 covergroups; page×command cross; timing corners; queue occupancy; error/resp; FSM transitions | driven by 11 tests; closure on campus sims |
| Structural (mirror)   | Verilator toggle / line / branch on the DUT          | 78.7% (toggle 78% / line 75% / branch 89%) merged over 4 seeds |

Closure plan and justified waivers: [`docs/vplan.md` §6](docs/vplan.md).

---

## Bug-hunt digest

Eight realistic RTL bugs injected as revertible patches
([`bugs/patches/`](bugs/patches/)); each proven caught and documented
symptom → failing test/assertion → root cause → fix in
[`docs/bug_log.md`](docs/bug_log.md). Auto-generated results:
[`bugs/RESULTS.md`](bugs/RESULTS.md).

| # | Bug                                   | Class       | Caught by   |
|---|---------------------------------------|-------------|-------------|
| 1 | Wrong bank decode (overlaps row bits) | functional  | scoreboard  |
| 2 | Dropped response back-pressure        | functional  | scoreboard  |
| 3 | tRCD off-by-one (CAS one cycle early) | timing      | assertion (A-TRCD) |
| 4 | Error flag not sticky                 | functional  | scoreboard  |
| 5 | Out-of-range returns OKAY             | functional  | scoreboard  |
| 6 | Byte strobes ignored on write         | functional  | scoreboard  |
| 7 | Reset leak (err_range survives reset) | functional  | scoreboard  |
| 8 | tREF starved (no auto-refresh)        | timing      | assertion (A-TREF) |

**Result: 8/8 caught — 6 by the scoreboard/reference model, 2 by assertions.**

---

## Status & honesty notes

- The **cocotb + Verilator mirror, lint, regression, coverage merge, and bug
  hunt all run here and in CI** (no license). Numbers above are measured.
- The **UVM tree is the primary deliverable** and is authored to UVM-1.2 idioms;
  it executes on a UVM-capable simulator (Questa/VCS/Xcelium/DSim/xsim) via the
  documented `make uvm` / `campus_regress.sh` flow. No UVM simulator is bundled
  in this environment, so UVM functional-coverage closure is run on those tools.
- Clean-room: no agents/VIP copied from OpenTitan or vendor examples.
