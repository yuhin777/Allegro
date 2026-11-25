"""Linear bulk two-phase workload and isolated recovery on the integrated subsystem."""
from struct import pack as word_pack, unpack

import cocotb
from cocotb.triggers import Timer

from fa4_model import CASES, pack
from fa4_replay import FrontEnd


def packed_control(op, opcode):
    return pack((58, op), (3, opcode), (417, 0))


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
        while "open_rsp" not in self.lifecycle:
            await self.edge()
        self.lifecycle.discard("open_rsp")

    async def load(self, origin, target, size, barrier):
        op = self.sign(0)
        await self.send("tma_cmd", pack((58, op), (3, 2), (64, 0), (32, target), (64, origin),
                                        (32, size), (32, barrier), (128, 0), (64, 0), (1, 0)))
        return op

    async def read_line(self, base):
        flags = 255
        tags = []
        self.d.lsu_quiescent.value = 0
        for group in range(8):
            tag = pack((58, self.sign(0)), (4, 12), (16, group))
            tags.append(tag)
            self.d.smem_rd_payload[group].value = pack((78, tag), (32, base + group * 16), (16, 65535))
        while flags:
            self.d.smem_rd_valid.value = flags
            flags &= ~await self.edge("smem_rd_ready")
        self.d.smem_rd_valid.value = 0
        while not all(tag in self.atoms for tag in tags):
            await self.edge()
        self.d.lsu_quiescent.value = 1
        return b"".join(self.atoms.pop(tag) for tag in tags)


@cocotb.test()
async def replay_linear_bulk(dut):
    fe = LinearFrontEnd(dut)
    await fe.open()
    barrier = 16384
    await fe.result(await fe.barrier(barrier, 0, count=1, issuer=0), "bar_rsp")
    fence = fe.sign(0)
    await fe.send("tma_cmd", packed_control(fence, 5))
    await fe.result(fence, "tma_rsp")
    checksums = []
    for phase in range(2):
        await fe.result(await fe.barrier(barrier, 3, nbytes=16384, issuer=0), "bar_rsp")
        copies = [await fe.load(phase * 16384 + index * 4096, index * 4096, 4096, barrier) for index in range(4)]
        await fe.wait_barrier(barrier, issuer=0)
        words = []
        for offset in range(0, 16384, 128):
            words.extend(unpack("<32I", await fe.read_line(offset)))
        assert words == list(range(phase * 4096 + 1, phase * 4096 + 4097))
        checksums.append(sum(words))
        for op in copies:
            assert await fe.result(op, "tma_rsp") & ((1 << 64) - 1) == 4096
    assert checksums == [8390656, 25167872]
    await fe.result(await fe.barrier(barrier, 1, issuer=0), "bar_rsp")
    await fe.send("close_req")
    while "close_rsp" not in fe.lifecycle:
        await fe.edge()
    assert fe.order_kinds == [2, 0, 1, 0, 1, 4]
    dut._log.info("linear_bulk_two_phase checksums %s, %d cycles through close", checksums, fe.cycle)


@cocotb.test()
async def memory_failure_and_isolated_reopen(dut):
    fe = LinearFrontEnd(dut)
    await fe.open()
    barrier = 16384
    await fe.result(await fe.barrier(barrier, 0, count=1, issuer=0), "bar_rsp")
    await fe.result(await fe.barrier(barrier, 3, nbytes=16, issuer=0), "bar_rsp")
    load = await fe.load(0, 0, 16, barrier)
    while not fe.pending_memory:
        await fe.edge()
    # Fail the already-issued data READ under its original ID.
    fe.pending_memory[0] |= 4
    await fe.edge()
    for _ in range(8):
        await Timer(1, units="ns")
        assert not int(dut.tma_rsp_valid.value) and not int(dut.close_rsp_valid.value)
        if int(dut.fault.value):
            break
        dut.clk.value = 1
        await Timer(1, units="ns")
        dut.clk.value = 0
    assert int(dut.fault.value) and not int(dut.tma_cmd_ready.value)
    assert load not in fe.results
    # Disconnect old responses and apply synchronous isolated reset before opening.
    fe.pending_memory.clear()
    fe.pending_order.clear()
    dut.gmem_rsp_valid.value = 0
    dut.isolated.value = 1
    dut.rst_n.value = 0
    fe.epoch = 2
    await fe.open()
    await fe.result(await fe.barrier(barrier, 0, count=1, issuer=0), "bar_rsp")
    await fe.send("close_req")
    while "close_rsp" not in fe.lifecycle:
        await fe.edge()
    assert fe.order_kinds[-1] == 4


@cocotb.test()
async def fault_with_held_open_response(dut):
    """Consume an already presented response exactly once after halt."""
    fe = LinearFrontEnd(dut)
    async def clock():
        await Timer(1, units="ns")
        dut.clk.value = 1
        await Timer(1, units="ns")
        dut.clk.value = 0
        await Timer(1, units="ns")

    dut.open_rsp_ready.value = 0
    await clock()
    dut.rst_n.value = 1
    dut.open_req_payload.value = 1
    dut.open_req_valid.value = 1
    await clock()
    dut.open_req_valid.value = 0
    assert fe.read("open_rsp_valid")
    dut.order_rsp_valid.value = 1
    dut.order_rsp_payload.value = 0
    await clock()
    dut.order_rsp_valid.value = 0
    assert fe.read("fault") and fe.read("open_rsp_valid") and fe.read("open_rsp_payload") == 0
    await clock()
    assert fe.read("open_rsp_valid")
    dut.open_rsp_ready.value = 1
    await clock()
    assert not fe.read("open_rsp_valid") and fe.read("stopped") and fe.read("fault")


@cocotb.test()
async def close_flushes_both_halves_before_ordering(dut):
    fe = LinearFrontEnd(dut)
    await fe.open()
    base = 256
    for address, count in ((base, 3), (base+8, 5)):
        await fe.result(await fe.barrier(address, 0, count=count), "bar_rsp")
        await fe.result(await fe.barrier(address, 2, count=1), "bar_rsp")
    dut.order_req_ready.value = 0
    await fe.send("close_req")
    while not fe.read("order_req_valid"):
        assert not fe.read("close_rsp_valid")
        await fe.edge()
    request = fe.read("order_req_payload")
    assert (request >> 102) & 7 == 4
    for _ in range(5):
        await fe.edge()
        assert fe.read("order_req_valid") and fe.read("order_req_payload") == request
        assert fe.read("stopped") and not fe.read("close_rsp_valid")
    dut.close_rsp_ready.value = 0
    dut.order_req_ready.value = 1
    while not fe.read("close_rsp_valid"):
        await fe.edge()
    for _ in range(3):
        await fe.edge()
        assert fe.read("close_rsp_valid") and not fe.read("open_req_ready")
    dut.close_rsp_ready.value = 1
    await fe.edge()
    # Normal reopen changes epoch without resetting storage. Read the actual
    # SMEM line through LSU to check both masked dirty writebacks.
    await fe.send("open_req", 2)
    while "open_rsp" not in fe.lifecycle:
        await fe.edge()
    fe.epoch = 2
    data = await fe.read_line(base)
    objects = unpack("<QQ", data[:16])
    assert objects == tuple((1 << 62) | (count << 20) | (count-1) for count in (3, 5))
