"""Measure native four-core QK/PV streams with published operands and steady service."""
import os

import cocotb
import numpy as np

from fa4_model import CASES, mma_payload, tile
from fa4_replay import FrontEnd


class DotMonitor:
    def __init__(self, frontend):
        self.fe = frontend
        self.issued = {}
        self.ports = []
        for core in range(4):
            def port(name):
                return frontend.d._id(f"cores[{core}].core.{name}", extended=False)
            self.ports.append((port("operand_valid"), port("operand_ready"), port("operand_tag")))

    def watch(self, op):
        self.issued[op] = [[] for _ in self.ports]

    def sample(self):
        for core, (valid, ready, operand_tag) in enumerate(self.ports):
            if not (int(valid.value) and int(ready.value)):
                continue
            tag = int(operand_tag.value)
            op = tag >> 18
            block, row = (tag >> 10) & 63, (tag >> 8) & 3
            assert (tag >> 16) & 3 == core and tag & 255 == block // 2
            edges = self.issued[op][core]
            assert len(edges) == 4 * block + row
            edges.append(self.fe.cycle)


async def measure(frontend, case, stage, pv, slot, reference):
    steps = 8 if pv else case.depth // 16
    q = (case.depth if pv else 128) // 2
    monitor = DotMonitor(frontend)
    frontend.observe = monitor.sample

    # Fill A/B and both sides of the round-robin before the first measured
    # instruction. This command uses the same descriptor and an independent D.
    warmup = frontend.sign(384)
    monitor.watch(warmup)
    independent_d = (256 + 128 * (1-stage)) if pv else 256
    warm_cmd = mma_payload(case, warmup, pv, stage, 0, slot, False)
    warm_cmd = (warm_cmd & ~(0xffffffff << 64)) | (independent_d << 64)
    await frontend.send("mma_cmd", warm_cmd)

    ops = []
    for step in range(steps):
        op = frontend.sign(384)
        ops.append(op)
        monitor.watch(op)
        await frontend.send("mma_cmd", mma_payload(case, op, pv, stage, step, slot, step != 0))
    for op in [warmup, *ops]:
        await frontend.result(op, "tc_op_done")
    frontend.observe = lambda: None

    first = monitor.issued[ops[0]][0][0]
    firsts = [monitor.issued[op][0][0] for op in ops]
    frontend.d._log.info("D%d %s stage %d measured first-dot edges %s",
                         case.depth, "PV" if pv else "QK", stage, firsts)
    for step, op in enumerate(ops):
        expected = list(range(first + step*q, first + (step+1)*q))
        for core, edges in enumerate(monitor.issued[op]):
            assert edges == expected, (stage,pv,step,core,edges,expected)

    # The small dyadic inputs accumulate exactly in FP32. RF readback starts
    # after the last completion, leaving the measured TMEM service uninterrupted.
    dest = (256 if pv else 0) + 128*stage
    cells = await frontend.get_rf(dest, 2*q)
    np.testing.assert_array_equal(cells.view("<f4"), reference)


@cocotb.test()
async def published_fa4_windows(dut):
    for target in os.environ.get("FA4_CASE", "F1,F2").split(","):
        case = CASES[target]
        fe = FrontEnd(dut, case, "coordinate")
        barrier = {64: 1}
        await fe.lifecycle_start(barrier)
        stages = [int(os.environ["FA4_TIMING_STAGE"])] if "FA4_TIMING_STAGE" in os.environ else range(case.stages)
        for stage in stages:
            assert 0 <= stage < case.stages
            for product in os.environ.get("FA4_TIMING_PRODUCT", "QK,PV").split(","):
                assert product in ("QK","PV")
                pv = product == "PV"
                slot = int(pv)
                if pv:
                    r, k = np.indices((128, 128))
                    p = ((3*r + 2*k + stage) % 5 - 2).astype("<f2")
                    await fe.put_rf(64+128*stage, p.view("<u4"))
                    v = tile(case, "V", 0, 128, 0, 0, "coordinate")
                    reference = p.astype("<f4") @ v.astype("<f4")
                else:
                    qrow = 128*stage
                    await fe.copy("Q", case.q_smem(stage), qrow, 0, 0, 64)
                    q = tile(case, "Q", qrow, 128, 0, 0, "coordinate")
                    k = tile(case, "K", 0, 128, 0, 0, "coordinate")
                    reference = q.astype("<f4") @ k.astype("<f4").T
                await fe.copy("V" if pv else "K", case.kv_smem(slot), 0, 0, 0, 64)
                await measure(fe, case, stage, pv, slot, reference)
        await fe.shutdown(barrier)
