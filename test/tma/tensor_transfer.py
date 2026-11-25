"""Exercise both TMA directions, byte strobes, OOB and asymmetric tensor strides."""
from collections import deque
from struct import pack_into
import cocotb
from cocotb.triggers import Timer


def packed(*fields):
    n = 0
    for width, value in fields:
        n = (n << width) | (value & ((1 << width) - 1))
    return n


def descriptor(base, dim, strides):
    raw = bytearray(128)
    raw[:4] = bytes((0x10, 3, 6, 3))
    pack_into("<Q", raw, 4, base)
    pack_into("<5I", raw, 12, *(d - 1 for d in dim), 0)
    pack_into("<5Q", raw, 32, 0, *strides, 0)
    pack_into("<5H", raw, 72, 128, 3, 2, 1, 0)
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
        self.cycle = 0
        self.seq = 0
        self.map_reads = []
        self.store_acks = []
        self.hold_store_acks = False
        self.hold_reads = False
        self.held_reads = []
        self.read_cycles = []

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
            if not allow_fault:
                assert not self.val("fault"), self.cycle
            if self.pending and self.val("gmem_rsp_ready"):
                self.pending.popleft()
            if self.val("gmem_req_valid") and self.val("gmem_req_ready"):
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
                    assert not (p >> (suffix - 4)) & 15
                    assert p >> suffix not in self.results
                    self.results[p >> suffix] = p & ((1 << suffix) - 1)
        d.clk.value = 1
        await Timer(1, units="ns")
        d.clk.value = 0
        self.cycle += 1
        assert self.cycle < 20000
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

    async def tma(self, opcode, map_addr=0, coord=(0, 0, 0, 0)):
        key = self.id()
        coords = sum((c & 0xffffffff) << (i * 32) for i, c in enumerate(coord))
        await self.send("tma_cmd", packed((58, key), (3, opcode), (64, map_addr), (32, 0xf0),
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

    async def bar(self, op, count=0, nbytes=0, hint=0, addr=0x1000):
        key = self.id()
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


@cocotb.test()
async def panel_first_oob_roundtrip(dut):
    f = Fabric(dut)
    await f.reset()
    src = 0x2000
    dst = 0x4000
    f.mem[0:128] = descriptor(src, (110, 3, 2, 1), (512, 224, 2048))
    f.mem[128:256] = descriptor(dst, (144, 5, 2, 1), (640, 288, 4096))
    for k in range(2048):
        f.mem[src + k] = (k * 7 + k // 255 + 3) & 255
    await f.result(await f.bar(0, 1))
    await f.result(await f.bar(3, nbytes=1536))
    for _ in range(3):
        await f.result(await f.tma(6))
    assert f.map_reads == [0]
    load = await f.tma(0, 0, (-8, 1, 0, 0))
    assert await f.result(load) == 1536
    assert await f.result(await f.bar(4)) == 1
    expected = f.mem.copy()
    smem_expected = {}
    for z in range(2):
        for y in range(3):
            for x in range(128):
                a = src + 2 * (x - 8) + (y + 1) * 512 + z * 224
                b = dst + 2 * (x + 8) + (y + 1) * 640 + z * 288
                expected[b:b + 2] = f.mem[a:a + 2] if 0 <= x - 8 < 110 and y + 1 < 3 else b"\0\0"
                for byte in range(2):
                    bpos = 2 * x + byte
                    logical = 0xf0 + (((bpos // 128) * 6 + z * 3 + y) * 128) + bpos % 128
                    physical = logical ^ (((logical >> 7) & 7) << 4)
                    smem_expected[physical] = expected[b + byte]
    await f.check_smem(smem_expected)
    f.hold_store_acks = True
    store = await f.tma(1, 128, (8, 1, 0, 0))
    await f.result(await f.tma(3))
    await f.result(await f.tma(4))
    assert store not in f.results and f.store_acks
    f.pending.extend(reversed(f.store_acks))
    f.hold_store_acks = False
    assert await f.result(store) == 1536
    assert f.mem == expected
    assert f.map_reads == [0, 128]


@cocotb.test()
async def timeout_hint_and_phase_change(dut):
    f = Fabric(dut)
    await f.reset()
    await f.result(await f.bar(0, 1))
    times = []
    for hint in (0, 641):
        t = f.cycle
        assert await f.result(await f.bar(4, hint=hint)) == 0
        times.append(f.cycle - t)
    assert times[0] == times[1] and times[0] >= 64
    # A later arrival flips phase; a fresh TRY observes success following ACQUIRE.
    await f.result(await f.bar(2, 1))
    assert await f.result(await f.bar(4, hint=641)) == 1


@cocotb.test()
async def sixty_four_outstanding_and_sixteen_return_rows(dut):
    f = Fabric(dut)
    await f.reset()
    await f.result(await f.bar(0, 1))
    await f.result(await f.bar(3, nbytes=8192))
    await f.block_group(0)
    for i in range(8192):
        f.mem[0x4000 + i] = (7 * i + (i >> 8)) & 255
    f.hold_reads = True
    load = await f.linear(0x4000, 0x2000, 8192)
    while len(f.held_reads) < 64:
        await f.edge()
    assert f.read_cycles == list(range(f.read_cycles[0], f.read_cycles[0] + 64))
    # The head blocked behind a full write ACK FIFO occupies R_OUT, so
    # no row can be reused until the LSU releases its outstanding ACKs.
    f.pending.extend(reversed(f.held_reads))
    for _ in range(30):
        await f.edge()
    assert len(f.pending) == 48 and not f.val("gmem_rsp_ready")
    assert load not in f.results
    dut.smem_wr_ack_ready.value = 255
    assert await f.result(load) == 8192
    assert await f.result(await f.bar(4)) == 1
    await f.check_smem({0x2000 + i: f.mem[0x4000 + i] for i in range(8192)})


@cocotb.test()
async def third_copy_issues_with_two_older_blocked(dut):
    f = Fabric(dut)
    await f.reset()
    await f.result(await f.bar(0, 1))
    await f.result(await f.bar(3, nbytes=48))
    # Block the write return queues for groups 0 and 1 with older LSU ACKs.
    # One resident output may then stall, independently of generation/GMEM reads.
    await f.block_group(0)
    dut.smem_wr_ack_ready.value = 252
    tag = packed((58, f.id()), (4, 12), (16, 1))
    dut.smem_wr_payload[1].value = packed((78, tag), (32, 0x9010), (16, 65535), (128, 0))
    dut.smem_wr_valid.value = 2
    while not (await f.edge("smem_wr_ready")) & 2:
        pass
    dut.smem_wr_valid.value = 0
    copies = [await f.linear(16 * i, addr, 16) for i, addr in enumerate((0, 0x90, 0x120))]
    while len(f.read_cycles) < 3:
        await f.edge()
    assert not any(key in f.results for key in copies)
    dut.smem_wr_ack_ready.value = 255
    for key in copies:
        assert await f.result(key) == 16
    assert await f.result(await f.bar(4)) == 1


@cocotb.test()
async def adjacent_16k_panels(dut):
    f = Fabric(dut)
    await f.reset()
    await f.result(await f.bar(0, 1))
    await f.result(await f.bar(3, nbytes=32768))
    first = await f.linear(0, 0x4000, 16384)
    second = await f.linear(16384, 0x8000, 16384)
    assert await f.result(first) == 16384 and await f.result(second) == 16384
    assert f.read_cycles == list(range(f.read_cycles[0], f.read_cycles[0] + 256))
    assert await f.result(await f.bar(4)) == 1


@cocotb.test()
async def memory_on_final_store_ack(dut):
    f = Fabric(dut)
    await f.reset()
    f.mem[0:128] = descriptor(0x4000, (144, 5, 2, 1), (640, 288, 4096))
    f.hold_store_acks = True
    store = await f.tma(1, 0, (0, 1, 0, 0))
    await f.result(await f.tma(3))
    await f.result(await f.tma(4))
    # A stable no-request interval after source completion drains RD/Q/R_OUT.
    for _ in range(32):
        await f.edge()
    assert f.store_acks and store not in f.results
    f.store_acks[-1] |= 4
    f.pending.extend(f.store_acks)
    while not f.val("fault"):
        await f.edge(allow_fault=True)
    assert store not in f.results


@cocotb.test()
async def fault_keeps_a_presented_gmem_request(dut):
    f = Fabric(dut)
    await f.reset()
    await f.result(await f.bar(0, 1))
    await f.result(await f.bar(3, nbytes=4096))
    f.hold_reads = True
    load = await f.linear(0, 0x2000, 4096)
    while not f.held_reads:
        await f.edge()
    dut.gmem_req_ready.value = 0
    await f.edge()
    assert f.val("gmem_req_valid")
    stalled = f.val("gmem_req_payload")
    f.pending.append(f.held_reads[0] | 4)
    for _ in range(4):
        await f.edge(allow_fault=True)
        assert f.val("gmem_req_valid") and f.val("gmem_req_payload") == stalled
    assert f.val("fault") and not f.val("tma_cmd_ready")
    dut.gmem_req_ready.value = 1
    await f.edge(allow_fault=True)
    await f.edge(allow_fault=True)
    assert not f.val("gmem_req_valid") and load not in f.results


@cocotb.test()
async def full_wait_table_with_dirty_evictions(dut):
    f = Fabric(dut)
    await f.reset()
    addresses = [0x1000 + i * 8 for i in range(6)]
    dut.smem_wr_ack_ready.value = 255
    for addr in addresses:
        await f.result(await f.bar(0, 1, addr=addr))
    # The object cache holds four lines. Wait slots live independently, even
    # when software stalls all return traffic across repeated half-line fills.
    dut.bar_rsp_ready.value = 0
    pending = [await f.bar(4, addr=addresses[i % len(addresses)]) for i in range(32)]
    for _ in range(850):
        await f.edge()
    dut.bar_rsp_ready.value = 1
    for wait in pending:
        assert await f.result(wait) == 0
    # Early complete-tx produces negative T. ARRIVE_EXPECT_TX restores T to
    # zero with P=0, flipping once; this value must survive eviction.
    early = await f.linear(0x2000, 0, 16)
    assert await f.result(early) == 16
    await f.result(await f.bar(3, nbytes=16))
    for addr in addresses[1:]:
        assert await f.result(await f.bar(4, addr=addr)) == 0
    assert await f.result(await f.bar(4)) == 1


@cocotb.test()
async def stale_bound_producer_cannot_flip_phase(dut):
    f = Fabric(dut)
    await f.reset()
    await f.result(await f.bar(0, 1))
    f.hold_reads = True
    load = await f.linear(0, 0x2000, 16)
    while not f.held_reads:
        await f.edge()
    await f.result(await f.bar(2, count=1))
    assert await f.result(await f.bar(4)) == 1
    f.pending.extend(f.held_reads)
    while not f.val("fault"):
        await f.edge(allow_fault=True)
    assert load not in f.results
