"""Eight in-place N128 commands against the top-level reference vector."""
import cocotb
import numpy as np
from fa4_model import CASES, pack
from fa4_replay import FrontEnd


def descriptor(start):
    return (1 << 46) | (16 << 32) | (8 << 16) | (start >> 4)


def command(op, start, destination=0, input_d=1):
    return pack((58, op), (3, 0), (4, 0), (4, 0), (2, 1),
                (1, 0), (1, 0), (1, input_d), (5, 0), (4, 0),
                (2, 0), (2, 0), (128, 0), (7, 0),
                (64, descriptor(start)), (64, descriptor(start + 4096)),
                (32, destination), (32, 0), (32, 0))


class Accumulation(FrontEnd):
    def __init__(self, dut):
        super().__init__(dut, CASES["F1"], "uniform")
        self.observe = self.capture
        self.active = False
        self.first_dots = []
        self.events = {}
        self.first_for_id = {}

    def capture(self):
        if not self.active:
            return
        d = self.d
        def core(name):
            return d._id("cores[0].core."+name, extended=False)
        if int(core("operand_valid").value) and int(core("operand_ready").value):
            op = int(core("dot_command").value) >> 388
            if op not in self.first_for_id:
                self.first_for_id[op] = self.cycle
                self.first_dots.append(self.cycle)
        writes = int(core("tm_wr_req_valid").value) & int(core("tm_wr_req_ready").value)
        writing = d._id("tmem.fabric.part[0].partition.writing", extended=False)
        if int(writing.value) & 1:
            self.events[self.last_write_id]["actual_write"] = self.cycle
        if writes & 1:
            self.last_write_id = int(core("tm_wr_req_payload")[0].value) >> 178
            self.events.setdefault(self.last_write_id, {})["write"] = self.cycle
        if int(core("tm_wr_ack_valid").value) & int(core("tm_wr_ack_ready").value) & 1:
            op = int(core("tm_wr_ack_payload")[0].value) >> 24
            self.events.setdefault(op, {})["ack"] = self.cycle
        if self.read("engine_done_valid") and self.read("engine_done_ready"):
            op = self.read("engine_done_payload") >> 4
            self.events.setdefault(op, {})["tracker"] = self.cycle

    async def write_panel(self, start, values):
        # Each 128B half contains one 16B atom in every physical group.
        for group in range(16):
            for half in range(2):
                valid = 255
                tags = []
                for lane in range(8):
                    addr = start + 256*group + 128*half + 16*lane
                    op = self.sign(256)
                    tag = pack((58, op), (4, 12), (16, lane))
                    atom = values[8*group+lane, 8*half:8*half+8].astype("<f2")
                    data = int.from_bytes(atom.tobytes(), "little")
                    self.d.smem_wr_payload[lane].value = pack((78, tag), (32, addr), (16, 65535), (128, data))
                    self.written_atoms[tag] = addr
                    tags.append(tag)
                self.d.lsu_quiescent.value = 0
                while valid:
                    self.d.smem_wr_valid.value = valid
                    valid &= ~await self.edge("smem_wr_ready")
                self.d.smem_wr_valid.value = 0
        while self.written_atoms:
            await self.edge()
        self.d.lsu_quiescent.value = 1


@cocotb.test()
async def eight_accumulations(dut):
    fe = Accumulation(dut)
    await fe.edge()
    await fe.edge()
    dut.rst_n.value = 1
    await fe.send("open_req", 1)
    while "open_rsp" not in fe.lifecycle:
        await fe.edge()
    alloc = fe.sign(320)
    await fe.send("tmem_manage", pack((58, alloc), (2, 0), (32, 0), (10, 512)))
    await fe.result(alloc, "tmem_manage_rsp")
    m, k = np.arange(128)[:, None], np.arange(16)[None, :]
    expected = m - 2*np.arange(128)[None, :]
    await fe.put_rf(0, expected.astype("<f4").view("<u4"))
    starts = [8192 + i*8192 for i in range(8)]
    for i, start in enumerate(starts):
        a = ((3*m + 2*k + i*(k+1)) % 7) - 3
        b = ((m + 3*k + i*(m+2)) % 9) - 4
        await fe.write_panel(start, a)
        await fe.write_panel(start+4096, b)
        expected += a @ b.T
    # Fill the cold pipeline with an independent operation. Its D range is
    # disjoint from the reference accumulator and its A/B reads have the same
    # service demand. Relative cycle zero is the first measured instruction.
    warmup = fe.sign(5)
    await fe.send("mma_cmd", command(warmup, starts[0], destination=256, input_d=0))
    fe.active = True
    ops = []
    for start in starts:
        op = fe.sign(5)
        ops.append(op)
        await fe.send("mma_cmd", command(op, start))
    for op in ops:
        await fe.result(op, "tc_op_done")
    await fe.result(warmup, "tc_op_done")
    fe.active = False
    actual = await fe.get_rf(0, 128)
    np.testing.assert_array_equal(actual, expected.astype("<f4").view("<u4"))
    dut._log.info("N128 first-dot edges %s, last write/ACK/tracker edges %s", fe.first_dots, fe.events)
    measured = [fe.first_for_id[op] for op in ops]
    assert len(fe.first_for_id) == 9
    assert [c-measured[0] for c in measured] == list(range(0, 512, 64))
    for i, op in enumerate(ops):
        assert fe.events[op]["write"] == measured[i]+70
        assert fe.events[op]["actual_write"] == measured[i]+71
        assert fe.events[op]["ack"] == measured[i]+72
        assert fe.events[op]["tracker"] == measured[i]+75
    await fe.shutdown({})


@cocotb.test()
async def native_fp4_scale_snapshots(dut):
    """Route two E8M0 factors from each TMEM scale operand to the FP4 dots."""
    fe = FrontEnd(dut, CASES["F1"], "uniform")
    await fe.lifecycle_start({})
    a, b = 8192, 12288
    one = int.from_bytes(bytes([0x22])*16, "little")
    await fe.write_smem_lines([[(base+offset+16*g, one) for g in range(8)]
                               for base, size in ((a, 4096), (b, 2048))
                               for offset in range(0, size, 128)])
    # Scale ID 2 selects bytes 2 and 3. K[0:32] sees 2 * 0.5 and
    # K[32:64] sees 4 * 1. The two unselected bytes encode other powers.
    sa, sb = 384, 400
    await fe.put_rf(sa, np.full((128,16),0x81807d7c,dtype="<u4"))
    await fe.put_rf(sb, np.full((128,16),0x7f7e7978,dtype="<u4"))
    op = fe.sign(384)
    mma = pack((58,op), (3,5), (4,7), (4,7), (2,0), (1,0), (1,0), (1,0),
               (5,0), (4,0), (2,0), (2,0), (128,0), (1,0), (2,2), (2,2), (2,2),
               (64,descriptor(a)), (64,descriptor(b)), (32,0), (32,sa), (32,sb))
    await fe.send("mma_cmd", mma)
    await fe.result(op, "tc_op_done")
    actual = await fe.get_rf(0, 64)
    np.testing.assert_array_equal(actual.view("<f4"), np.full((128,64),160.0,dtype="<f4"))
    await fe.shutdown({})
