"""Linear GMEM service and readback for integrated subsystem tests."""
from struct import pack as word_pack

from fa4_model import CASES, pack
from frontend import FrontEnd


class LinearMemory:
    def read(self, addr):
        assert 0 <= addr < 32768 and addr % 128 == 0
        return word_pack("<32I", *range(addr // 4 + 1, addr // 4 + 33))


class LinearFrontEnd(FrontEnd):
    def __init__(self, dut):
        super().__init__(dut, CASES["F1"], "uniform")
        self.mem = LinearMemory()
        self.atoms = {}
        self.order_kinds = []
        self.observe = self.capture

    def capture(self):
        if not self.read("rst_n"):
            return
        if self.read("order_req_valid") and self.read("order_req_ready"):
            self.order_kinds.append((self.read("order_req_payload") >> 102) & 7)
        for group in range(8):
            if self.read("smem_rd_rsp_valid") & self.read("smem_rd_rsp_ready") & (1 << group):
                value = int(self.d.smem_rd_rsp_payload[group].value)
                tag = value >> 132
                assert value & 15 == 0 and tag not in self.atoms
                self.atoms[tag] = ((value >> 4) & ((1 << 128) - 1)).to_bytes(16, "little")

    async def open(self):
        await self.edge()
        await self.edge()
        self.d.rst_n.value = 1
        await self.send("open_req", self.epoch)
        await self.wait_until(lambda: "open_rsp" in self.lifecycle, f"open response for epoch {self.epoch}")
        self.lifecycle.discard("open_rsp")

    async def load(self, origin, target, size, barrier):
        op = self.sign(0)
        await self.send("tma_cmd", pack((58, op), (3, 2), (64, 0), (32, target), (64, origin),
                                        (32, size), (32, barrier), (128, 0), (64, 0), (1, 0)))
        return op

    async def read_line(self, base):
        tags = []
        self.d.lsu_quiescent.value = 0
        for group in range(8):
            tag = pack((58, self.sign(0)), (4, 12), (16, group))
            tags.append(tag)
            self.d.smem_rd_payload[group].value = pack((78, tag), (32, base + group * 16), (16, 65535))
        await self.transfer_groups("smem_rd", 255, base)
        await self.wait_until(lambda: all(tag in self.atoms for tag in tags), f"readback for SMEM line {base:#x}")
        self.d.lsu_quiescent.value = 1
        return b"".join(self.atoms.pop(tag) for tag in tags)
