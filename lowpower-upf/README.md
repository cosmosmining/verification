# Power-aware verification — UPF isolation & retention

The **DV + low-power** companion to [`sdram_lite_ctrl`](../README.md) — the
clock/power axis that project explicitly scoped out. A small power-gated design
(`pg_top`) with an **IEEE-1801 UPF** intent file, an always-on PMU that runs the
**isolation → retention → power-gate** sequence, and a cocotb scoreboard on
**Icarus Verilog (4-state)** that catches deliberately injected power-gating
bugs.

> **Honest framing:** no license-free simulator consumes UPF, so the UPF here is
> the authoritative *intent* (syntax-checked by `upf/upf_lint.tcl`) and the RTL
> *models* the isolation/retention cells a real flow would auto-insert. This is
> a **modelled** low-power demo, not a UPF-tool sign-off — see
> [`docs/vplan.md` §1](docs/vplan.md).

---

## Result

**Clean build PASSES; 3/3 injected power-gating bugs caught** with
counterexamples — [`bugs/BUGS.md`](bugs/BUGS.md):

| Fault | Breaks | Caught |
|-------|--------|--------|
| `PG_BUG_ISO` | isolation removed → core X reaches the AON domain | ✅ (isolation) |
| `PG_BUG_RET` | retention never saved → state lost on wake | ✅ (retention) |
| `PG_BUG_SEQ` | power-off before isolate/save → retention snapshots X | ✅ (isolation, on wake) |

```
isolation_and_retention: PASS (162 cycles, 6 sleep/wake retention checks, 0 X-leaks)
UPF LINT OK: pg_top.upf
```

---

## Résumé extraction

**What I built** — A power-aware verification environment for a UPF power-gated
block: an **IEEE-1801 UPF** describing a power switch + an **isolation** strategy
(clamp-0) + a **state-retention** strategy, an always-on PMU sequencing
**isolate → save → power-off / power-on → restore → de-isolate**, and a cocotb
scoreboard on a **4-state** simulator that proves (A) **isolation** — no X
reaches the always-on domain, (B) **retention** — state survives the power
cycle, and (C) function. Caught **3/3** injected power-gating faults, including a
**sequencing** bug that corrupts the retention snapshot.

**Tools** — UPF (IEEE 1801), cocotb, Icarus Verilog (4-state X-prop), Tcl (UPF
lint), Python.

**ATS keywords** — low-power verification, UPF / IEEE 1801, power gating,
isolation cells, state retention, power domains, X-propagation, power sequencing,
PMU, cocotb, Icarus, RTL verification.

---

## Quick start

```bash
sudo apt-get install -y iverilog          # 4-state simulator (and tcl for the UPF lint)
pip install -r requirements.txt           # cocotb 1.9
make                                       # run the isolation/retention scoreboard
tclsh upf/upf_lint.tcl                     # syntax-check the UPF intent
bash bugs/run_bug_demo.sh                  # inject 3 power bugs, prove each is caught

make SEED=4 CYCLES=10                       # more sleep/wake cycles
make BUG=PG_BUG_SEQ                         # run one injected fault directly
```

---

## Layout

```
upf/   pg_top.upf  upf_lint.tcl       # IEEE-1801 intent + license-free Tcl lint
rtl/   pg_top.sv pg_pmu.sv pg_counter.sv   # PMU + switchable core (modelled iso/retention)
tb/    test_pg.py                      # power-aware scoreboard (A isolation / B retention / C function)
bugs/  run_bug_demo.sh  BUGS.md        # injected power-gating fault campaign
docs/  vplan.md                        # low-power verification plan + honesty notes
Makefile  check_results.py             # cocotb+Icarus driver; JUnit -> exit-code gate
```
