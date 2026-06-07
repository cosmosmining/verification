"""Power-aware scoreboard for pg_top — isolation + retention sequencing.

Runs on Icarus Verilog (4-state) so the isolation property is meaningful: a
power-gated core register is driven to X, and the isolation cell must keep that
X out of the always-on (AON) domain. A 2-state simulator could not show this.

Checks, enforced every cycle by a monitor:
  A. ISOLATION — cnt_obs is never X/Z (the AON domain never samples a gated core).
  B. RETENTION — the counter value is preserved across sleep: the first value the
                 AON sees after wake equals the value it last saw before sleep.
  C. FUNCTION  — while powered & un-isolated, cnt_obs tracks the enable: +1 when
                 en=1, held when en=0.

Protocol: like a real system, the AON domain QUIESCES the block (en=0) before
asserting sleep_req, so the value saved into retention is exactly the value the
AON last agreed on.

Injected faults each violate exactly one property:
  PG_BUG_ISO -> A   PG_BUG_RET -> B   PG_BUG_SEQ -> A (X-leak window before iso).
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

W = 8
MASK = (1 << W) - 1


def binstr(sig):
    return sig.value.binstr.lower()


class PowerScoreboard:
    """Samples the AON observation every cycle and enforces A/B/C."""

    def __init__(self, dut):
        self.dut = dut
        self.prev_obs = None
        self.prev_active = False
        self.prev_en = 0
        self.frozen = None        # value the AON last agreed on before low-power
        self.slept = False        # a sleep happened since the last retention check
        self.cycles = 0
        self.sleeps_checked = 0

    async def run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            self.cycles += 1
            iso = int(dut.iso_en.value)
            pwr = int(dut.pwr_on.value)
            asleep = int(dut.is_asleep.value)
            en = int(dut.en.value)

            # ---- A. ISOLATION: no X/Z may reach the AON domain ----
            b = binstr(dut.cnt_obs)
            assert "x" not in b and "z" not in b, (
                f"[cycle {self.cycles}] isolation failure: X/Z leaked into AON domain "
                f"cnt_obs={b} (iso_en={iso} pwr_on={pwr} is_asleep={asleep})")
            obs = int(b, 2)

            active = (iso == 0 and pwr == 1)
            if asleep:
                self.slept = True

            # entering low-power: remember the last value the AON agreed on
            if self.prev_active and not active:
                self.frozen = self.prev_obs

            if active:
                if self.prev_active:
                    # ---- C. FUNCTION: the edge used the previous-cycle enable ----
                    expect = (self.prev_obs + (1 if self.prev_en else 0)) & MASK
                    assert obs == expect, (
                        f"[cycle {self.cycles}] count error: obs={obs} expected {expect} "
                        f"(prev_obs={self.prev_obs} prev_en={self.prev_en})")
                elif self.slept and self.frozen is not None:
                    # ---- B. RETENTION: first active obs after wake == frozen ----
                    assert obs == (self.frozen & MASK), (
                        f"[cycle {self.cycles}] retention lost: woke with {obs}, "
                        f"expected preserved value {self.frozen & MASK}")
                    self.sleeps_checked += 1
                    self.slept = False

            self.prev_obs = obs
            self.prev_active = active
            self.prev_en = en


async def reset(dut):
    dut.en.value = 1
    dut.sleep_req.value = 0
    dut.rst_n.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def sleep_cycle(dut, awake_n, asleep_n):
    """One quiesce -> sleep -> wake -> resume cycle (the AON-side protocol)."""
    dut.en.value = 1
    for _ in range(awake_n):
        await RisingEdge(dut.clk)
    dut.en.value = 0                        # quiesce the block before sleeping
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.sleep_req.value = 1                  # request sleep (PMU: iso -> save -> off)
    for _ in range(asleep_n):
        await RisingEdge(dut.clk)
    dut.sleep_req.value = 0                  # request wake (PMU: on -> restore -> de-iso)
    dut.en.value = 1                         # may reassert; core stays gated until de-iso
    for _ in range(awake_n):
        await RisingEdge(dut.clk)


@cocotb.test()
async def isolation_and_retention(dut):
    """Several quiesce/sleep/wake cycles; isolation + retention must hold."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    sb = PowerScoreboard(dut)
    cocotb.start_soon(sb.run())

    seed = int(os.environ.get("SEED", "1"))
    rng = random.Random(seed)
    for _ in range(int(os.environ.get("CYCLES", "6"))):
        await sleep_cycle(dut, awake_n=rng.randint(5, 14), asleep_n=rng.randint(3, 12))

    assert sb.sleeps_checked >= 1, "scoreboard never validated a wake — test ineffective"
    dut._log.info("isolation_and_retention: PASS "
                  "(%d cycles, %d sleep/wake retention checks, 0 X-leaks)"
                  % (sb.cycles, sb.sleeps_checked))
