"""Untimed scoreboard-level reference model for sdram_lite_ctrl.

This mirrors the *functional* prediction the UVM scoreboard's SV reference
model performs (read data, response code, in-order). It deliberately does NOT
model cycle-accurate timing -- bank-timing legality (tRCD/tRP/tREF) is checked
by SVA in the UVM environment. Keeping a second, independent implementation of
the data/response prediction in Python is the "keep you honest" cross-check.

Defaults match the RTL parameter defaults in rtl/sdram_lite_ctrl.sv:
  BANKS=4, ROW_W=4, COL_W=8  ->  capacity = 4*16*256 = 16384 words.
"""

CAP_WORDS = 4 * (1 << 4) * (1 << 8)   # 16384
IDX_MASK = CAP_WORDS - 1              # 0x3FFF

NRESP_OKAY = 0b00
NRESP_ERROR = 0b10


class SdramRef:
    """Predicts native-port responses for an in-order request stream."""

    def __init__(self, cap_words: int = CAP_WORDS):
        self.cap = cap_words
        self.mask = cap_words - 1
        # Verilator zero-initialises regs, so an unwritten location reads 0.
        self.mem = {}

    def is_oor(self, addr: int) -> bool:
        return addr >= self.cap

    def access(self, we: int, addr: int, wdata: int, wstrb: int):
        """Apply one request, return (resp, rdata).

        rdata is meaningful only for an OKAY read; it is 0 otherwise (matching
        the RTL, which drives rsp_rdata=0 for writes and errors).
        """
        if self.is_oor(addr):
            return NRESP_ERROR, 0

        idx = addr & self.mask
        if we:
            cur = self.mem.get(idx, 0)
            new = cur
            for b in range(4):
                if (wstrb >> b) & 1:
                    byte = (wdata >> (b * 8)) & 0xFF
                    new = (new & ~(0xFF << (b * 8))) | (byte << (b * 8))
            self.mem[idx] = new & 0xFFFFFFFF
            return NRESP_OKAY, 0
        else:
            return NRESP_OKAY, self.mem.get(idx, 0)
