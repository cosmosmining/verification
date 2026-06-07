# Third-party AXI4-Lite crossbar — cocotb DV

Companion project to [`sdram_lite_ctrl`](../README.md): a constrained-random,
reference-model **verification environment for an IP I did *not* design** — the
[`axil_crossbar`](https://github.com/alexforencich/verilog-axi) from Alex
Forencich's widely-used `verilog-axi`, driven by the community
[`cocotbext-axi`](https://github.com/alexforencich/cocotbext-axi) VIP and run
license-free on Verilator.

> Upstream: the crossbar RTL + the AXI VIP (pinned, never vendored). Mine: the
> [verification plan](docs/vplan.md), the routing/isolation/integrity
> **scoreboard**, the scenarios, and an injected-fault demonstration.

---

## Result

**5 / 5 scenario tests PASS** against the 2×2 crossbar on Verilator
(directed routing, same-slave arbitration, cross-slave concurrency, byte-strobe
partial writes, and 200 random ops/seed). The injected-fault demo
([`bugs/BUGS.md`](bugs/BUGS.md)) shows the scoreboard goes **red** on a one-token
decode bug — so the green run has teeth.

```
** test_axil_crossbar_dv.directed_routing        PASS **
** test_axil_crossbar_dv.concurrent_same_slave   PASS **
** test_axil_crossbar_dv.concurrent_diff_slave   PASS **
** test_axil_crossbar_dv.partial_strobe          PASS **
** test_axil_crossbar_dv.random_traffic          PASS **
** TESTS=5 PASS=5 FAIL=0 SKIP=0 **
```

---

## Résumé extraction

**What I did** — Stood up a cocotb/Verilator DV environment against a **third-party
AXI4-Lite crossbar**, using the `cocotbext-axi` VIP for stimulus and an
**independent reference-model scoreboard** that proves the crossbar-specific
properties — address **routing**, slave **isolation**, data **integrity**
(incl. WSTRB partial writes), and **arbitration/concurrency** across two
masters — under directed and constrained-random traffic. Demonstrated the
scoreboard catches a real RTL defect via an injected decode fault.

**Tools** — cocotb 1.9, cocotbext-axi, Verilator, Python; pinned/reproducible
upstream; GitHub Actions CI.

**ATS keywords** — AMBA AXI4-Lite, interconnect/crossbar verification, cocotb,
cocotbext-axi, constrained-random, reference model / scoreboard, IP verification,
reuse of third-party VIP, Verilator, regression, CI.

---

## Quick start

```bash
pip install -r requirements.txt        # cocotb 1.9 + cocotbext-axi (matches the apt Verilator)
./setup.sh                             # fetch verilog-axi @516bd5d, generate the 2x2 wrapper
make                                   # run all 5 scenario tests on Verilator
python3 check_results.py               # gate: non-zero if any test failed
bash bugs/run_bug_demo.sh              # inject a decode bug, prove the scoreboard catches it

make SEED=7 N=500 TESTCASE=random_traffic   # heavier random sweep
make WAVES=1 TESTCASE=partial_strobe        # dump dump.vcd
```

`work/` (the upstream clone + generated wrapper) is gitignored and reproduced
by `setup.sh`.

---

## Honesty note

No confirmed upstream bug was found within this scope (AXI4-Lite, 2×2) — expected
for a mature, widely-deployed core. I do **not** manufacture a "found a bug"
claim; the env is built so a genuine failure produces a minimal seeded repro,
which I'd review with the maintainer before filing. See
[`docs/vplan.md` §4](docs/vplan.md) for the full scope + bug-filing policy.
