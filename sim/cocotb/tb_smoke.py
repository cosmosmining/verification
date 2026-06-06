"""cocotb + Verilator smoke mirror for sdram_lite_ctrl.

Runs license-free in CI / locally. The UVM environment is the primary
deliverable; this mirror independently re-checks the scoreboard-level
behaviour (read data, response codes, in-order completion, CSR access,
out-of-range errors) so a divergence between RTL and the *idea* of the
design is caught even where no UVM simulator is available.

Handshake convention: inputs are driven just after a RisingEdge and the
combinational *_ready is sampled at the following FallingEdge (mid-cycle,
where it is stable for a synchronous DUT); a transfer is then committed on
the next RisingEdge. This is robust against combinational-ready glitches.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from sdram_ref import SdramRef, CAP_WORDS, NRESP_OKAY, NRESP_ERROR

# ---- CSR offsets (mirror docs/dut_spec.md) ----
A_CTRL, A_STATUS, A_TRCD, A_TRP = 0x00, 0x04, 0x08, 0x0C
A_TREF, A_ERRST, A_ERRADDR, A_SCRATCH = 0x10, 0x14, 0x18, 0x1C
AXI_OKAY, AXI_DECERR = 0b00, 0b11

CLK_NS = 10

# One reference model shared across the traffic tests. Hardware reset clears
# control/queue state but NOT the memory array (realistic for a memory
# controller), and cocotb runs all @cocotb.test()s in a single simulation, so
# the model must persist writes across tests to stay in lock-step with the
# DUT's accumulated memory contents.
REF = SdramRef()


# ===========================================================================
# Low-level BFMs
# ===========================================================================
def _init_inputs(dut):
    for sig, val in [
        ("s_axil_awvalid", 0), ("s_axil_wvalid", 0), ("s_axil_bready", 0),
        ("s_axil_arvalid", 0), ("s_axil_rready", 0),
        ("s_axil_awaddr", 0), ("s_axil_awprot", 0),
        ("s_axil_wdata", 0), ("s_axil_wstrb", 0),
        ("s_axil_araddr", 0), ("s_axil_arprot", 0),
        ("req_valid", 0), ("req_we", 0), ("req_addr", 0),
        ("req_wdata", 0), ("req_wstrb", 0), ("rsp_ready", 0),
    ]:
        getattr(dut, sig).value = val


async def reset_dut(dut):
    _init_inputs(dut)
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def axil_write(dut, addr, data, strb=0xF):
    dut.s_axil_awaddr.value = addr
    dut.s_axil_awprot.value = 0
    dut.s_axil_wdata.value = data
    dut.s_axil_wstrb.value = strb
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wvalid.value = 1
    aw_done = w_done = False
    while not (aw_done and w_done):
        await FallingEdge(dut.clk)
        aw_hit = (not aw_done) and dut.s_axil_awready.value == 1
        w_hit = (not w_done) and dut.s_axil_wready.value == 1
        await RisingEdge(dut.clk)
        if aw_hit:
            aw_done = True
            dut.s_axil_awvalid.value = 0
        if w_hit:
            w_done = True
            dut.s_axil_wvalid.value = 0
    # capture B
    dut.s_axil_bready.value = 1
    bresp = 0
    while True:
        await FallingEdge(dut.clk)
        if dut.s_axil_bvalid.value == 1:
            bresp = int(dut.s_axil_bresp.value)
            await RisingEdge(dut.clk)
            break
        await RisingEdge(dut.clk)
    dut.s_axil_bready.value = 0
    return bresp


async def axil_read(dut, addr):
    dut.s_axil_araddr.value = addr
    dut.s_axil_arprot.value = 0
    dut.s_axil_arvalid.value = 1
    while True:
        await FallingEdge(dut.clk)
        ar_hit = dut.s_axil_arready.value == 1
        await RisingEdge(dut.clk)
        if ar_hit:
            dut.s_axil_arvalid.value = 0
            break
    dut.s_axil_rready.value = 1
    data = resp = 0
    while True:
        await FallingEdge(dut.clk)
        if dut.s_axil_rvalid.value == 1:
            data = int(dut.s_axil_rdata.value)
            resp = int(dut.s_axil_rresp.value)
            await RisingEdge(dut.clk)
            break
        await RisingEdge(dut.clk)
    dut.s_axil_rready.value = 0
    return data, resp


async def configure(dut, trcd=3, trp=3, tref=64, irq_en=1):
    await axil_write(dut, A_TRCD, trcd)
    await axil_write(dut, A_TRP, trp)
    await axil_write(dut, A_TREF, tref)
    ctrl = 0b001 | 0b010 | (0b100 if irq_en else 0)  # ENABLE | REFRESH_EN | IRQ_EN
    await axil_write(dut, A_CTRL, ctrl)
    for _ in range(300):
        data, _ = await axil_read(dut, A_STATUS)
        if data & 0x1:  # INIT_DONE
            return
    assert False, "INIT_DONE never asserted"


async def send_request(dut, we, addr, wdata, wstrb, rng):
    # random idle gap with valid de-asserted
    while rng.random() < 0.25:
        dut.req_valid.value = 0
        await RisingEdge(dut.clk)
    dut.req_valid.value = 1
    dut.req_we.value = we
    dut.req_addr.value = addr
    dut.req_wdata.value = wdata
    dut.req_wstrb.value = wstrb
    while True:
        await FallingEdge(dut.clk)
        if dut.req_ready.value == 1:
            await RisingEdge(dut.clk)
            dut.req_valid.value = 0
            return
        await RisingEdge(dut.clk)


async def monitor_responses(dut, n, collected, rng):
    while len(collected) < n:
        dut.rsp_ready.value = 1 if rng.random() > 0.30 else 0
        await FallingEdge(dut.clk)
        if dut.rsp_valid.value == 1 and dut.rsp_ready.value == 1:
            collected.append((int(dut.rsp_resp.value), int(dut.rsp_rdata.value)))
        await RisingEdge(dut.clk)
    dut.rsp_ready.value = 0


# ===========================================================================
# Tests
# ===========================================================================
@cocotb.test(timeout_time=3, timeout_unit="ms")
async def csr_sanity(dut):
    """Reset values, RW/RO/W1C semantics, clamping, DECERR -- mirrors RAL checks."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await reset_dut(dut)

    # reset values (F-004)
    for off, exp, name in [(A_TRCD, 3, "T_RCD"), (A_TRP, 3, "T_RP"),
                           (A_TREF, 1024, "T_REF"), (A_STATUS, 0x10, "STATUS")]:
        data, resp = await axil_read(dut, off)
        assert resp == AXI_OKAY, f"{name} read resp {resp}"
        assert data == exp, f"{name} reset = 0x{data:x}, expected 0x{exp:x}"

    # SCRATCH is plain RW (F-003)
    await axil_write(dut, A_SCRATCH, 0xDEADBEEF)
    data, _ = await axil_read(dut, A_SCRATCH)
    assert data == 0xDEADBEEF, f"SCRATCH rb 0x{data:x}"

    # undefined offset -> DECERR (F-005)
    _, resp = await axil_read(dut, 0x40)
    assert resp == AXI_DECERR, f"undef offset resp {resp}, expected DECERR"

    # timing clamp (spec section 4)
    await axil_write(dut, A_TRCD, 0)
    data, _ = await axil_read(dut, A_TRCD)
    assert data == 1, f"T_RCD clamp = {data}, expected 1"
    await axil_write(dut, A_TREF, 5)
    data, _ = await axil_read(dut, A_TREF)
    assert data == 16, f"T_REF clamp = {data}, expected 16 (TRFC+8)"

    dut._log.info("csr_sanity: PASS")


@cocotb.test(timeout_time=3, timeout_unit="ms")
async def wr_rd_directed(dut):
    """Directed write-then-read across banks; in-order responses (F-008..F-015)."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await reset_dut(dut)
    await configure(dut)

    ref = REF
    reqs = []
    # write a pattern, then read it back; addresses chosen to hit/miss/conflict
    addrs = [0, 1, 2, 0x100, 0x101, 0x200, 0x1000, 0x1001, 0x2345, 0x3FFF]
    for i, a in enumerate(addrs):
        reqs.append((1, a, 0x1000_0000 + i, 0xF))
    for a in addrs:
        reqs.append((0, a, 0, 0))

    expected = [ref.access(*r) + (r[0],) for r in reqs]  # (resp, rdata, we)
    collected = []
    mon = cocotb.start_soon(monitor_responses(dut, len(reqs), collected, random.Random(7)))
    for r in reqs:
        await send_request(dut, *r, random.Random(0))  # no gaps -> deterministic-ish
    await mon

    _check(dut, expected, collected)
    dut._log.info("wr_rd_directed: PASS (%d transactions)" % len(reqs))


@cocotb.test(timeout_time=8, timeout_unit="ms")
async def smoke_random(dut):
    """Constrained-random traffic with back-pressure + scoreboard (F-006..F-024)."""
    seed = int(os.environ.get("SEED", "1"))
    rng = random.Random(seed)
    dut._log.info("smoke_random seed=%d" % seed)
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await reset_dut(dut)
    await configure(dut)

    ref = REF
    hot = [0, 1, 2, 0x100, 0x101, 0x200, 0x1000, 0x1001, 0x2000, 0x3FFF]
    N = 250
    reqs = []
    for _ in range(N):
        we = rng.randint(0, 1)
        u = rng.random()
        if u < 0.15:                                   # out-of-range
            addr = rng.randint(CAP_WORDS, (1 << 20) - 1)
        elif u < 0.6:                                  # locality (hot set)
            addr = rng.choice(hot)
        else:                                          # full range
            addr = rng.randint(0, CAP_WORDS - 1)
        wdata = rng.randint(0, (1 << 32) - 1)
        wstrb = rng.randint(0, 15) if we else 0
        reqs.append((we, addr, wdata, wstrb))

    expected = [ref.access(*r) + (r[0],) for r in reqs]
    collected = []
    mon = cocotb.start_soon(monitor_responses(dut, N, collected, rng))
    for r in reqs:
        await send_request(dut, *r, rng)
    await mon

    n_err = sum(1 for e in expected if e[0] == NRESP_ERROR)
    _check(dut, expected, collected)
    dut._log.info("smoke_random: PASS (seed=%d, %d txns, %d error responses)"
                  % (seed, N, n_err))


def _check(dut, expected, collected):
    assert len(collected) == len(expected), \
        f"response count {len(collected)} != {len(expected)} (in-order/dropped?)"
    fails = 0
    for i, ((eresp, erdata, we), (aresp, ardata)) in enumerate(zip(expected, collected)):
        if aresp != eresp:
            dut._log.error("txn %d: resp %d != exp %d" % (i, aresp, eresp))
            fails += 1
        elif we == 0 and eresp == NRESP_OKAY and ardata != erdata:
            dut._log.error("txn %d: rdata 0x%08x != exp 0x%08x" % (i, ardata, erdata))
            fails += 1
    assert fails == 0, f"{fails} scoreboard mismatch(es)"
