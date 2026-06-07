"""cocotb DV environment for a THIRD-PARTY AXI4-Lite crossbar.

DUT: ``axil_crossbar`` from alexforencich/verilog-axi, instantiated 2 masters ×
2 slaves via the generated ``axil_crossbar_wrap_2x2`` wrapper. This is the
"verify something I did **not** design" companion to the SDRAM project: a real
reference-model scoreboard plus directed + constrained-random scenarios, driven
by the community ``cocotbext-axi`` VIP, running license-free on Verilator.

What the scoreboard actually proves about the *crossbar* (not the RAMs):
  * **Routing** — a master write to a global address lands in the *correct*
    slave at the correct offset (decode is right).
  * **Isolation** — traffic to slave A never perturbs slave B's memory.
  * **Data integrity** — read-back through the crossbar returns what was written,
    including byte-strobed partial writes.
  * **Arbitration / concurrency** — two masters hitting the same slave, and
    different slaves in parallel, all complete with correct data.

Address map (wrapper defaults: M*_ADDR_WIDTH=24): slave k decodes
[k·0x0100_0000, …); we model 64 KB of RAM per slave and only touch offsets
inside it, so the scoreboard is exact.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotbext.axi import AxiLiteBus, AxiLiteMaster, AxiLiteRam

S_COUNT = 2
M_COUNT = 2
SLAVE_STRIDE = 1 << 24      # each slave interface decodes a 16 MB region
RAM_SIZE = 1 << 16          # model 64 KB of memory behind each slave
WORD = 4


def gaddr(slave: int, offset: int) -> int:
    """Global address that the crossbar must route to `slave` at `offset`."""
    return slave * SLAVE_STRIDE + (offset & (RAM_SIZE - 1))


class Tb:
    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log
        cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
        self.master = [AxiLiteMaster(AxiLiteBus.from_prefix(dut, f"s{k:02d}_axil"),
                                     dut.clk, dut.rst) for k in range(S_COUNT)]
        self.ram = [AxiLiteRam(AxiLiteBus.from_prefix(dut, f"m{k:02d}_axil"),
                               dut.clk, dut.rst, size=RAM_SIZE) for k in range(M_COUNT)]
        # golden model: what each slave's memory *should* contain if the crossbar
        # routes and carries data correctly. Starts zero, in lock-step with the RAMs.
        self.ref = [bytearray(RAM_SIZE) for _ in range(M_COUNT)]

    async def reset(self):
        self.dut.rst.value = 1
        for _ in range(8):
            await RisingEdge(self.dut.clk)
        self.dut.rst.value = 0
        for _ in range(8):
            await RisingEdge(self.dut.clk)

    async def wr(self, master: int, slave: int, offset: int, data: bytes):
        await self.master[master].write(gaddr(slave, offset), data)
        self.ref[slave][offset:offset + len(data)] = data

    async def rd(self, master: int, slave: int, offset: int, length: int) -> bytes:
        res = await self.master[master].read(gaddr(slave, offset), length)
        return bytes(res.data)

    def check_backing(self, msg=""):
        """Every slave RAM must match the golden model (routing + isolation)."""
        for k in range(M_COUNT):
            got = bytes(self.ram[k].read(0, RAM_SIZE))
            exp = bytes(self.ref[k])
            if got != exp:
                # find first divergence for a useful message
                i = next(j for j in range(RAM_SIZE) if got[j] != exp[j])
                raise AssertionError(
                    f"{msg}: slave {k} backing memory mismatch at offset 0x{i:04x}: "
                    f"got {got[i]:02x} exp {exp[i]:02x} (routing/isolation bug?)")


@cocotb.test()
async def directed_routing(dut):
    """Each master writes a distinct pattern to each slave; verify routing,
    read-back, and that slaves stay isolated."""
    tb = Tb(dut)
    await tb.reset()
    offs = [0x0000, 0x0004, 0x0040, 0x1000, 0xFFFC]
    for m in range(S_COUNT):
        for s in range(M_COUNT):
            for i, off in enumerate(offs):
                val = (0xA0 + m * 0x10 + s) .to_bytes(1, "little") * 3 + bytes([i])
                await tb.wr(m, s, off, val)
    # read back through the crossbar from the *other* master to prove the path
    for m in range(S_COUNT):
        for s in range(M_COUNT):
            for off in offs:
                got = await tb.rd((m + 1) % S_COUNT, s, off, WORD)
                assert got == bytes(tb.ref[s][off:off + WORD]), \
                    f"read-back m{m} s{s} off{off:#x}: {got.hex()} != {bytes(tb.ref[s][off:off+WORD]).hex()}"
    tb.check_backing("directed_routing")
    dut._log.info("directed_routing: PASS")


@cocotb.test()
async def concurrent_same_slave(dut):
    """Both masters write the SAME slave at the same time (arbitration)."""
    tb = Tb(dut)
    await tb.reset()
    s = 1
    t0 = cocotb.start_soon(tb.wr(0, s, 0x0100, b"\x11\x22\x33\x44"))
    t1 = cocotb.start_soon(tb.wr(1, s, 0x0200, b"\xaa\xbb\xcc\xdd"))
    await t0
    await t1
    assert await tb.rd(0, s, 0x0100, WORD) == b"\x11\x22\x33\x44"
    assert await tb.rd(1, s, 0x0200, WORD) == b"\xaa\xbb\xcc\xdd"
    tb.check_backing("concurrent_same_slave")
    dut._log.info("concurrent_same_slave: PASS")


@cocotb.test()
async def concurrent_diff_slave(dut):
    """Masters target different slaves in parallel (no false serialization)."""
    tb = Tb(dut)
    await tb.reset()
    t0 = cocotb.start_soon(tb.wr(0, 0, 0x0010, b"\x01\x02\x03\x04"))
    t1 = cocotb.start_soon(tb.wr(1, 1, 0x0010, b"\x05\x06\x07\x08"))
    await t0
    await t1
    assert await tb.rd(0, 0, 0x0010, WORD) == b"\x01\x02\x03\x04"
    assert await tb.rd(1, 1, 0x0010, WORD) == b"\x05\x06\x07\x08"
    tb.check_backing("concurrent_diff_slave")
    dut._log.info("concurrent_diff_slave: PASS")


@cocotb.test()
async def partial_strobe(dut):
    """Byte-strobed partial writes change only the addressed bytes."""
    tb = Tb(dut)
    await tb.reset()
    await tb.wr(0, 0, 0x0020, b"\xde\xad\xbe\xef")
    await tb.wr(0, 0, 0x0021, b"\x99")            # touch only byte 1
    await tb.wr(1, 0, 0x0022, b"\x77\x88")        # touch bytes 2..3
    got = await tb.rd(1, 0, 0x0020, WORD)
    assert got == b"\xde\x99\x77\x88", got.hex()
    tb.check_backing("partial_strobe")
    dut._log.info("partial_strobe: PASS")


@cocotb.test()
async def random_traffic(dut):
    """Constrained-random interleaved traffic with a full scoreboard."""
    seed = int(os.environ.get("SEED", "1"))
    rng = random.Random(seed)
    tb = Tb(dut)
    await tb.reset()
    N = int(os.environ.get("N", "200"))
    inflight = []
    for _ in range(N):
        m = rng.randrange(S_COUNT)
        s = rng.randrange(M_COUNT)
        off = rng.randrange(0, RAM_SIZE - WORD) & ~0x3
        if rng.random() < 0.6:
            data = bytes(rng.randrange(256) for _ in range(WORD))
            inflight.append(cocotb.start_soon(tb.wr(m, s, off, data)))
        else:
            # read must observe prior writes -> drain inflight first
            for t in inflight:
                await t
            inflight = []
            got = await tb.rd(m, s, off, WORD)
            assert got == bytes(tb.ref[s][off:off + WORD]), \
                f"seed{seed}: m{m} s{s} off{off:#x} {got.hex()} != {bytes(tb.ref[s][off:off+WORD]).hex()}"
        if len(inflight) > 8:
            for t in inflight:
                await t
            inflight = []
    for t in inflight:
        await t
    tb.check_backing(f"random_traffic seed={seed}")
    dut._log.info("random_traffic: PASS (seed=%d, %d ops)" % (seed, N))
