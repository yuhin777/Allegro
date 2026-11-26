"""Drive the SMEM subsystem ports and model global memory and ordering responses."""

from collections import deque
from struct import pack_into

from cocotb.triggers import Timer


def packed(*fields):
    n = 0
    for width, value in fields:
        n = (n << width) | (value & ((1 << width) - 1))
    return n


def descriptor(base, dim, strides, box=(128, 3, 2, 1)):
    raw = bytearray(128)
    raw[:4] = bytes((0x10, 3, 6, 3))
    pack_into("<Q", raw, 4, base)
    pack_into("<5I", raw, 12, *(d - 1 for d in dim), 0)
    pack_into("<5Q", raw, 32, 0, *strides, 0)
    pack_into("<5H", raw, 72, *box, 0)
    raw[82:86] = bytes([1] * 4)
    return raw


class Fabric:
    def __init__(self, dut):
        self.d = dut
        self.d.clk.value = self.d.rst_n.value = 0
        self.d.epoch.value = self.d.stop.value = self.d.halt_i.value = 0
        for name in ("tma_cmd", "bar_cmd", "tc_req", "gmem_rsp", "order_rsp", "flush_req",
                     "tc_smem_req", "smem_rd", "smem_wr"):
            getattr(dut, name + "_valid").value = 0
        self.d.commit_addr_busy.value = 0
        self.d.tma_rsp_ready.value = self.d.bar_rsp_ready.value = self.d.gmem_req_ready.value = 1
        self.d.tc_rsp_ready.value = self.d.flush_rsp_ready.value = 1
        self.d.order_req_ready.value = 7
        self.d.smem_rd_rsp_ready.value = 255
        self.atoms = {}
        self.mem = bytearray([0xa5] * 65536)
        self.pending = deque()
        self.order = [deque() for _ in range(3)]
        self.results = {}
        self.expected_tma_status = {}
        self.cycle = 0
        self.seq = 0
        self.gmem_requests = 0
        self.map_reads = []
        self.store_acks = []
        self.hold_store_acks = False
        self.hold_reads = False
        self.held_reads = []
        self.read_cycles = []
        self.load_write_addresses = None

    def val(self, name):
        return int(getattr(self.d, name).value)

    async def edge(self, probe=None, allow_fault=False):
        d = self.d
        d.gmem_rsp_valid.value = bool(self.pending)
        d.gmem_rsp_payload.value = self.pending[0] if self.pending else 0
        d.order_rsp_valid.value = sum(bool(q) << i for i, q in enumerate(self.order))
        for i, q in enumerate(self.order):
            d.order_rsp_payload[i].value = q[0] if q else 0
        await Timer(1, units="ns")
        ready = self.val(probe) if probe else 0
        if self.val("rst_n"):
            if self.load_write_addresses is not None and self.val("t_req_v") & self.val("t_req_r") & 1:
                self.load_write_addresses.append((int(d.t_req[0].value) >> 144) & 0xffffffff)
            if not allow_fault:
                assert not self.val("fault"), self.cycle
            if self.pending and self.val("gmem_rsp_ready"):
                self.pending.popleft()
            if self.val("gmem_req_valid") and self.val("gmem_req_ready"):
                self.gmem_requests += 1
                p = self.val("gmem_req_payload") >> 64
                mask = p & ((1 << 128) - 1)
                data = (p >> 128) & ((1 << 1024) - 1)
                addr = (p >> 1152) & ((1 << 64) - 1)
                write = (p >> 1216) & 7
                key = p >> 1219
                assert addr < len(self.mem) and addr % 128 == 0
                if key >> 7:
                    self.map_reads.append(addr)
                if write:
                    for i in range(128):
                        if mask >> i & 1:
                            self.mem[addr + i] = (data >> (8 * i)) & 255
                    data = 0
                else:
                    data = int.from_bytes(self.mem[addr:addr + 128], "little")
                reply = packed((9, key), (1024, data), (4, 0))
                if not write and key >> 7 == 0:
                    self.read_cycles.append(self.cycle)
                if not write and self.hold_reads and key >> 7 == 0:
                    self.held_reads.append(reply)
                elif write and self.hold_store_acks:
                    self.store_acks.append(reply)
                else:
                    self.pending.append(reply)
            for i, q in enumerate(self.order):
                if q and self.val("order_rsp_ready") >> i & 1:
                    q.popleft()
                if self.val("order_req_valid") >> i & 1:
                    q.append((int(d.order_req_payload[i].value) >> 105) << 4)
            for g in range(8):
                if self.val("smem_rd_rsp_valid") >> g & 1:
                    val = int(d.smem_rd_rsp_payload[g].value)
                    assert not val & 15
                    self.atoms[val >> 132] = ((val >> 4) & ((1 << 128) - 1)).to_bytes(16, "little")
            for channel, suffix in [("tma_rsp", 68), ("bar_rsp", 5)]:
                if self.val(channel + "_valid") and self.val(channel + "_ready"):
                    p = self.val(channel + "_payload")
                    expected = self.expected_tma_status.pop(p >> suffix, 0) if channel == "tma_rsp" else 0
                    assert ((p >> (suffix - 4)) & 15) == expected
                    assert p >> suffix not in self.results
                    self.results[p >> suffix] = p & ((1 << suffix) - 1)
        d.clk.value = 1
        await Timer(1, units="ns")
        d.clk.value = 0
        self.cycle += 1
        if self.cycle >= 20000:
            raise TimeoutError(
                f"cycle {self.cycle}, probe={probe}, last sequence={self.seq}, "
                f"pending TMA IDs={list(self.expected_tma_status)}, "
                f"held reads={len(self.held_reads)}, held store ACKs={len(self.store_acks)}"
            )
        return ready

    async def reset(self):
        await self.edge()
        await self.edge()
        self.d.rst_n.value = self.d.epoch.value = 1
        await self.edge()

    async def send(self, name, payload):
        getattr(self.d, name + "_valid").value = 1
        getattr(self.d, name + "_payload").value = payload
        while not await self.edge(name + "_ready"):
            pass
        getattr(self.d, name + "_valid").value = 0

    def id(self):
        self.seq += 1
        return (1 << 42) | self.seq

    async def tma(self, opcode, map_addr=0, coord=(0, 0, 0, 0), smem=0xf0, expected_status=0):
        key = self.id()
        self.expected_tma_status[key] = expected_status
        coords = sum((c & 0xffffffff) << (i * 32) for i, c in enumerate(coord))
        await self.send("tma_cmd", packed((58, key), (3, opcode), (64, map_addr), (32, smem),
                                         (64, 0), (32, 0), (32, 0x1000), (128, coords), (64, 0), (1, 0)))
        return key

    async def linear(self, origin, target, size):
        key = self.id()
        await self.send("tma_cmd", packed((58, key), (3, 2), (64, 0), (32, target), (64, origin), (32, size),
                                         (32, 0x1000), (128, 0), (64, 0), (1, 0)))
        return key

    async def block_group(self, group):
        addr = 0x9000 + 16 * group
        self.d.smem_wr_ack_ready.value = 255 ^ (1 << group)
        for i in range(2):
            tag = packed((58, self.id()), (4, 12), (16, i))
            self.d.smem_wr_payload[group].value = packed((78, tag), (32, addr), (16, 65535), (128, 0))
            self.d.smem_wr_valid.value = 1 << group
            while not (await self.edge("smem_wr_ready")) & (1 << group):
                pass
        self.d.smem_wr_valid.value = 0

    async def bar(self, op, count=0, nbytes=0, hint=0, addr=0x1000, issuer=0):
        key = self.id() | (issuer << 32)
        await self.send("bar_cmd", packed((58, key), (4, op), (32, addr), (32, count), (32, nbytes),
                                         (1, 0), (1, 0), (32, hint)))
        return key

    async def check_smem(self, addresses):
        for atom in sorted({addr & ~15 for addr in addresses}):
            g = atom >> 4 & 7
            tag = packed((58, self.id()), (4, 12), (16, g))
            self.d.smem_rd_payload[g].value = packed((78, tag), (32, atom), (16, 65535))
            self.d.smem_rd_valid.value = 1 << g
            while not (await self.edge("smem_rd_ready")) & (1 << g):
                pass
            self.d.smem_rd_valid.value = 0
            while tag not in self.atoms:
                await self.edge()
            data = self.atoms.pop(tag)
            for i in range(16):
                if atom + i in addresses:
                    assert data[i] == addresses[atom + i], (hex(atom + i), data[i], addresses[atom + i])

    async def result(self, key):
        while key not in self.results:
            await self.edge()
        return self.results.pop(key)
