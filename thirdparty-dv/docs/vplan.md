# Verification Plan — third-party AXI4-Lite crossbar (`verilog-axi`)

| Field    | Value                                                                 |
|----------|-----------------------------------------------------------------------|
| DUT      | `axil_crossbar` from **alexforencich/verilog-axi** (pinned `516bd5d`) — a widely-used MIT IP I did **not** design |
| Config   | 2 masters × 2 slaves (`axil_crossbar_wrap_2x2`); 32-bit data/addr; each slave decodes a 16 MB region (`0x0000_0000`, `0x0100_0000`); 64 KB modelled per slave |
| Method   | `cocotbext-axi` VIP (AxiLiteMaster × 2 driving, AxiLiteRam × 2 responding) + an independent **reference-model scoreboard**, on Verilator |
| Sign-off | All scenarios pass across the random seed set; the injected-fault demo produces a scoreboard failure |

This is the "verify something I did **not** design" companion to the SDRAM
project. The crossbar and the VIP are upstream; **mine** is the verification
plan, the reference-model scoreboard (routing / isolation / integrity), the
scenarios, and the injected-fault demonstration.

---

## 1. What the scoreboard proves (about the crossbar, not the RAMs)

The two slave-side `AxiLiteRam`s are themselves correct memories, so a naive
"write then read the same port" would prove nothing about the *crossbar*. The
scoreboard instead keeps an **independent golden model** (`ref[slave][offset]`)
of what each slave's memory must contain *if the crossbar routes and carries
data correctly*, and checks the RAM backing stores **directly** (bypassing the
crossbar). That isolates crossbar behaviour:

| Property        | How it's checked                                                                 |
|-----------------|----------------------------------------------------------------------------------|
| **Routing**     | a master write to a global address must land in the decoded slave at the right offset (`check_backing` compares each RAM to its golden model) |
| **Isolation**   | traffic to slave A must not perturb slave B (the *other* RAM must still equal its golden model) |
| **Data integrity** | read-back **through the crossbar** (from a *different* master) returns the written bytes, including byte-strobed partial writes |
| **Arbitration** | two masters to the **same** slave both complete with correct data |
| **Concurrency** | two masters to **different** slaves proceed in parallel with correct data |

---

## 2. Test list & traceability

| Test (`TESTCASE`)        | Intent                                                        | Properties        |
|--------------------------|---------------------------------------------------------------|-------------------|
| `directed_routing`       | every master writes a distinct pattern to every slave/offset, reads back cross-master, verifies backing stores | routing, isolation, integrity |
| `concurrent_same_slave`  | both masters write the same slave simultaneously               | arbitration       |
| `concurrent_diff_slave`  | masters target different slaves in parallel                    | concurrency       |
| `partial_strobe`         | sub-word writes change only the addressed byte lanes           | integrity (WSTRB) |
| `random_traffic`         | constrained-random interleaved R/W with a full scoreboard (seeded, `N` ops) | all of the above |

---

## 3. Injected-fault demonstration

[`bugs/run_bug_demo.sh`](../bugs/run_bug_demo.sh) mutates the decoder
(`m_select_next = i;` → `i ^ 1;`, routing to the wrong slave — the analogue of
the SDRAM project's "wrong bank decode"), confirms the scoreboard fails, and
reverts. Result table: [`bugs/BUGS.md`](../bugs/BUGS.md).

---

## 4. Honesty notes & upstream-bug policy

- **Scope**: AXI4-**Lite** (no bursts), 2×2 config, single 1 MB-aligned region
  per slave, default register slices. Wider configs / full AXI4 bursts / the
  AxiLite→Axi adapters are out of scope here.
- **No confirmed upstream bug** was found within this scope — expected for a
  mature, widely-deployed core. The headline DV signal the task text describes
  ("public GitHub issue with your name on a confirmed RTL bug") therefore is
  **not** manufactured here. The environment is structured so that *if* a check
  fails on clean upstream RTL, it yields a minimal, seeded repro ready to file —
  and I would surface that to the repo owner for review **before** opening any
  upstream issue, never auto-filing.
- **Clean-room boundary**: the crossbar and `cocotbext-axi` are upstream; the
  scoreboard, scenarios, and bug demo are mine.
