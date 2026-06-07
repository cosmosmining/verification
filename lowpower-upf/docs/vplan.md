# Low-Power Verification Plan — `pg_top` (UPF isolation + retention)

| Field    | Value                                                                       |
|----------|-----------------------------------------------------------------------------|
| DUT      | `pg_top` — always-on PMU + a power-gated counter core (PD_TOP / PD_CORE)     |
| Intent   | [`upf/pg_top.upf`](../upf/pg_top.upf) — IEEE-1801 power switch + isolation + retention |
| Method   | cocotb power-aware scoreboard on **Icarus Verilog (4-state)**; the isolation/retention cells are modelled in RTL and driven by the PMU |
| Sign-off | clean build passes A/B/C across the seed set; every injected `PG_BUG_*` produces a counterexample |

This is the **DV + low-power** companion (the Qualcomm clock/power axis the
SDRAM README called out as out-of-scope). It exercises the part of low-power
verification that is *functional*: the **isolation and retention power
sequence**, and the X-propagation hazards a wrong sequence creates.

---

## 1. Why Icarus, not Verilator (the honest tooling note)

Isolation is fundamentally an **X-propagation** property — a power-gated
register is *unknown*, and the isolation cell exists to keep that unknown out of
the always-on domain. That can only be observed on a **4-state** simulator, so
this project uses **Icarus Verilog**, not the 2-state Verilator used elsewhere
in the repo. No license-free simulator consumes UPF, so:

- `upf/pg_top.upf` is the **authoritative intent** (power switch, isolation
  strategy clamp=0, retention save/restore) — the artifact a real
  VCS-NLP/Questa-PA/Xcelium-LP flow would consume to auto-insert the cells. It
  is syntax-checked license-free by `upf/upf_lint.tcl`.
- The **RTL models exactly those strategies** (isolation mux, retention shadow,
  X-on-gate) so the same sequencing is simulatable here. This is a *modelled*
  low-power demo, not a UPF-tool sign-off — stated plainly.

---

## 2. Properties & coverage

| ID | Property  | Checked by (every cycle)                                                        |
|----|-----------|---------------------------------------------------------------------------------|
| A  | Isolation | `cnt_obs` is never X/Z — the AON domain never samples the gated core             |
| B  | Retention | the first AON value after wake == the last AON value before sleep (state kept)   |
| C  | Function  | while powered & un-isolated, `cnt_obs` follows the enable (+1 / hold)             |

Sequence coverage exercised by the directed/seeded `sleep_cycle` driver:
quiesce → **isolate → save → power-off** → (asleep N) → **power-on → restore →
de-isolate** → resume, over randomized awake/asleep durations.

---

## 3. Injected-fault campaign (proves teeth)

[`bugs/run_bug_demo.sh`](../bugs/run_bug_demo.sh) → [`bugs/BUGS.md`](../bugs/BUGS.md):

| Fault         | Injected defect                                              | Caught by |
|---------------|-------------------------------------------------------------|-----------|
| `PG_BUG_ISO`  | isolation cell removed                                      | A (X-leak) |
| `PG_BUG_RET`  | retention shadow never saved → state lost                  | B (continuity) |
| `PG_BUG_SEQ`  | power-off before isolate/save → retention captures X       | A (X-leak on wake) |

`PG_BUG_SEQ` is the instructive one: getting the *order* wrong doesn't just risk
a glitch, it poisons the retention snapshot with X that resurfaces on wake — the
classic reason isolation/retention/power ordering is a sign-off item.

---

## 4. Honesty notes

- **Modelled, not tool-signed-off.** A real flow proves intent-vs-netlist with a
  UPF-aware tool and inserts the cells from UPF; here the cells are modelled in
  RTL for license-free 4-state sim. The UPF is real and lint-clean but not
  simulated by a UPF engine.
- **Scope.** One switchable domain, one retained register, coarse-grain gating,
  state-retention (not save-to-memory). Multi-rail, DVFS, level shifters, and
  power-state tables (PST) are out of scope.
