# riscv-formal on PicoRV32 — Formal Property Verification

Companion project to [`sdram_lite_ctrl`](../README.md). That project verifies a
controller **I designed**; this one closes the complementary gap — **formally
verifying a third-party RISC-V core I did *not* design** — by standing up the
industry-standard open-source FPV suite, [**riscv-formal**](https://github.com/YosysHQ/riscv-formal),
against [**PicoRV32**](https://github.com/YosysHQ/picorv32) and running it to
green, license-free, in CI.

> Both the core *and* the harness are upstream, pinned by commit + content hash.
> What's mine: the reproducible bring-up, SMT-engine selection, a parallel
> runner with measured results / JUnit capture, an injected-bug demonstration,
> and the [verification plan](docs/fpv_plan.md). Nothing third-party is vendored.

---

## Result

**87 / 87 riscv-formal checks PASS** on PicoRV32 (RV32IMC), proved with
SymbiYosys + Yices, fanned out across 4 cores. Full auto-generated per-check
table with wall-times: [`results/RESULTS.md`](results/RESULTS.md).

Injected-bug demonstration — all 5 of PicoRV32's fault hooks produce a
counterexample (the suite has teeth, not just a green light):
[`bugs/BUGS.md`](bugs/BUGS.md).

---

## Résumé extraction (for ASIC/DV applications)

**1. What I did** — Brought up **riscv-formal**, the standard open-source
RISC-V formal-verification suite, on the third-party **PicoRV32** RV32IMC core
and proved **all 87 generated checks** at the configured depths: per-instruction
ISA conformance (RV32I + M via ALTOPS + C), register-file consistency, forward
& backward PC consistency, liveness, determinism (`unique`), causality, and CSR
counter/illegal-access semantics. Then **demonstrated the suite catches real
defects** by activating five injected RTL faults and capturing a counterexample
trace for each.

**2. Tools** — SymbiYosys / Yosys (formal front-end), `smtbmc` with **Yices 2.7**
(z3 fallback), the **RVFI** methodology, Python (parallel runner, results/JUnit),
GitHub Actions CI. License-free end to end.

**3. Quantified** — **87/87** proofs PASS; **5/5** injected bugs caught with
counterexamples; runs in CI on every push; upstream pinned (riscv-formal
`@325a0f6`, picorv32 `@87c89ac`, `sha256:0836…0622`) for bit-reproducibility.

**4. ATS keywords** — formal property verification (FPV), model checking, BMC,
k-induction, SymbiYosys, Yosys, SMT, RISC-V, RV32IM, ISA conformance, RVFI,
processor verification, counterexample debug, assertion-based verification,
reproducible builds, CI.

---

## How it works (one paragraph)

PicoRV32 exposes the **RISC-V Formal Interface (RVFI)** — every retired
instruction self-reports its operands, result, destination register and
next-PC. riscv-formal `bind`s checker modules to that interface and an SMT
solver proves, over *all* instruction streams up to a bounded depth, that the
self-report matches a golden ISA model. A PASS is therefore a proof, not a
sampled coverage point. See [`docs/fpv_plan.md`](docs/fpv_plan.md) for the check
taxonomy, depths, and an honest account of what `RISCV_FORMAL_ALTOPS` does and
does not prove about the multiplier/divider.

---

## Quick start

```bash
# tools: yosys + SymbiYosys + a solver (yices recommended; z3 works).
# In CI these come from apt + a pinned yices binary (see .github workflow).
./setup.sh                              # pin+fetch riscv-formal & picorv32, genchecks
python3 run_checks.py --jobs $(nproc)   # run all 87 checks -> results/RESULTS.md + junit.xml
bash bugs/run_bug_demo.sh               # activate the 5 fault hooks, prove each is caught

# narrow runs while iterating:
python3 run_checks.py --only insn_      # just the per-instruction checks
SOLVER=z3 ./setup.sh                     # regenerate for the z3 engine
```

`work/` (the upstream clone + generated check workdirs) is gitignored and fully
reproduced by `setup.sh`.

---

## Layout

```
setup.sh           pin + fetch riscv-formal & picorv32, select engine, genchecks
run_checks.py      parallel sby runner -> results/{RESULTS.md,results.json,junit.xml}
docs/fpv_plan.md   the FPV plan: check taxonomy, depths, ALTOPS scope, honesty notes
bugs/              run_bug_demo.sh + BUGS.md   (injected-fault -> counterexample)
results/           measured outputs (committed)
work/              [gitignored] upstream clone + generated checks
```

---

## Honesty notes

- **I did not author** PicoRV32 or the riscv-formal checks — that is the entire
  point (verify what you didn't design). My work is the reproducible, measured,
  CI-wired flow + the bug demonstration + the analysis.
- **Bounded depths + ALTOPS.** Proofs hold to the configured BMC depths;
  M-extension *arithmetic* is abstracted by ALTOPS (the datapath/decode is
  proven, the multiplier's math is not). Detailed in the plan.
- **Engine.** Measured numbers use Yices; z3 reproduces the same PASS set more
  slowly. Solver choice does not change PASS/FAIL, only wall-time.
