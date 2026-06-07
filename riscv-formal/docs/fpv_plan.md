# Formal Verification Plan — PicoRV32 under riscv-formal

| Field    | Value                                                              |
|----------|-------------------------------------------------------------------|
| DUT      | **PicoRV32** (`YosysHQ/picorv32`) — a third-party RV32IMC core I did **not** design |
| Harness  | **riscv-formal** (`YosysHQ/riscv-formal`) — the standard open-source FPV suite |
| Method   | RVFI bounded model checking + k-induction via **SymbiYosys**, engine `smtbmc yices` |
| Sign-off | 100% of the generated check set PASS at the configured depths; every injected test-bug produces a counterexample |

This is the companion to the `sdram_lite_ctrl` project, which verifies a design
**I authored**. The explicit goal here is the opposite muscle — **verifying
something I did not design** — using an industry-legible harness. My
contribution is the reproducible bring-up, engine selection, parallel results
capture, the injected-bug demonstration, and this analysis; the core and the
check methodology are upstream's, pinned by commit and content hash in
[`../setup.sh`](../setup.sh).

---

## 1. How riscv-formal proves a core correct (RVFI)

PicoRV32 exposes the **RISC-V Formal Interface (RVFI)**: a bundle of signals
(`rvfi_valid`, `rvfi_insn`, `rvfi_rs1/rs2_addr/rdata`, `rvfi_rd_addr/wdata`,
`rvfi_pc_rdata/wdata`, `rvfi_mem_*`, …) that reports, every time an instruction
retires, exactly what that instruction claims to have done. riscv-formal `bind`s
a set of **checker modules** to that interface and asks an SMT solver to prove —
over all reachable states up to a bounded depth — that the core's self-reported
behaviour matches a golden, formally-specified RISC-V ISA model.

Because the checks are driven by unconstrained inputs (any instruction stream,
any memory responses), a PASS is a proof over **all** programs within the depth
window, not a sample — this is what makes "passed riscv-formal" a meaningful
credential rather than a coverage number.

---

## 2. Check taxonomy — what each class proves

Generated from upstream's `cores/picorv32/checks.cfg` (`isa rv32imc`). 87 checks
in total; the per-instruction set is the bulk.

| Check class            | Proves                                                                                  | Depth |
|------------------------|-----------------------------------------------------------------------------------------|-------|
| `insn_<op>`            | Each retired `<op>` matches the ISA model: operands read, result, `rd`, and next-PC      | 20    |
| `reg`                  | The register file is coherent — what RVFI says was written to `xN` is what is later read  | 15→25 |
| `pc_fwd`               | PC moves forward correctly — no instruction is skipped (forward consistency)              | 10→30 |
| `pc_bwd`               | PC has a unique, correct predecessor — no instruction is invented (backward consistency)  | 10→30 |
| `liveness`             | The core always eventually retires an instruction — no deadlock (with a fairness assume)  | …→30  |
| `unique`               | State is a deterministic function of the input history (no hidden nondeterminism)         | …→30  |
| `causal`               | Each instruction's inputs were produced causally by earlier instructions/memory           | 10→30 |
| `csrw_<csr>`           | CSR writes to `mcycle`/`minstret` take effect with the right semantics                    | 15    |
| `csrc_inc/upcnt_<csr>` | The cycle/retire counters increment/update monotonically and correctly                    | 1→15  |
| `csr_ill_<addr>`       | Access to the listed illegal CSRs traps rather than silently succeeding                   | 15    |
| `cover`                | A reachability liveness cover — two instructions can actually retire (sanity that the
                           proof environment isn't vacuously stuck)                                                 | 15    |

The full per-check PASS/FAIL table with measured wall-times is auto-generated
into [`../results/RESULTS.md`](../results/RESULTS.md).

---

## 3. The M extension and `RISCV_FORMAL_ALTOPS` (honest scope)

`checks.cfg` defines `RISCV_FORMAL_ALTOPS`. A bit-exact 32×32 multiplier or a
restoring divider is hostile to an SMT solver, so riscv-formal substitutes
**alternative operations** for `MUL/MULH*/DIV*/REM*`: both the core and the
golden model compute a cheap, collision-resistant surrogate
(e.g. `(rs1 + rs2) ^ constant`) instead of the true product/quotient. This
**does** prove the M-extension *plumbing* — decode, operand routing, `rd`
selection, retirement timing, and that the right instruction produces the right
`rd` from the right operands — but it **does not** prove the arithmetic of the
multiplier/divider itself. That is a deliberate, documented limitation of the
ALTOPS methodology, not an oversight; verifying the actual arithmetic would be a
separate datapath proof. Calling this out explicitly rather than claiming a
stronger result than ALTOPS delivers.

Likewise the proofs are **bounded** at the depths above (BMC), strengthened by
`pc_fwd/pc_bwd/unique/causal` which add k-induction-style unbounded arguments
for the consistency properties. "Passed riscv-formal at the standard depths" is
the precise claim.

---

## 4. Injected-bug demonstration (does the suite have teeth?)

Mirroring the SDRAM project's bug-hunt: a green run only matters if the
environment can also go red. PicoRV32 ships five one-token fault hooks
(`PICORV32_TESTBUG_001..005`); [`../bugs/run_bug_demo.sh`](../bugs/run_bug_demo.sh)
activates each and runs the check that should catch it, confirming a
counterexample. See [`../bugs/BUGS.md`](../bugs/BUGS.md) for the measured table.

| Bug   | Injected fault (1-token mutation)                          | Class               | Caught by              |
|-------|------------------------------------------------------------|---------------------|------------------------|
| TB001 | writeback to wrong register: `cpuregs[rd ^ 1]`             | functional (regfile)| `reg`                  |
| TB002 | writeback wrong data: `cpuregs_wrdata ^ 1`                 | functional (regfile)| `reg` / `insn_*`       |
| TB003 | RVFI reports wrong `rd_addr`: `latched_rd ^ 1`             | trace/decode        | `insn_*` (e.g. `addi`) |
| TB004 | RVFI reports wrong `rd_wdata`: `… ^ 1`                     | trace/data          | `insn_*`               |
| TB005 | RVFI reports wrong next-PC: `… ^ 4`                        | control-flow        | `pc_fwd` / `insn_*`    |

---

## 5. Reproducibility & honesty notes

- **Pinned**: riscv-formal `@325a0f6`, picorv32 `@87c89ac`
  (`sha256:0836…0622`). `setup.sh` fetches the pinned commit because picorv32's
  default branch was renamed `master`→`main`, so upstream's own Makefile URL
  (`…/picorv32/master/picorv32.v`) now 404s — the pinned fetch is strictly more
  reproducible.
- **Engine**: `smtbmc yices` (Yices 2.7.0). z3 also works (`SOLVER=z3`) but is
  ~10× slower on these bit-vector BMC problems; boolector/yices is the norm.
- **Clean-room boundary**: I did not write picorv32 or the riscv-formal checks.
  What is mine: the pinned/reproducible flow, the engine bring-up, the parallel
  runner + results/JUnit capture, the injected-bug harness, and this analysis.
- **Scope**: one core, one config (RV32IMC + ALTOPS), bounded depths. CDC/STA/
  power are out of scope here (see the UPF companion project).
