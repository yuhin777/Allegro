"""Linear bulk two-phase workload and isolated recovery on the integrated subsystem."""
from struct import unpack

import cocotb
from cocotb.triggers import Timer

from fa4_model import pack
from linear_driver import LinearFrontEnd


def packed_control(op, opcode):
    return pack((58, op), (3, opcode), (417, 0))


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
    await fe.result(await fe.barrier(barrier, 1, issuer=0), "bar_rsp")
    await fe.send("close_req")
    await fe.wait_until(lambda: "close_rsp" in fe.lifecycle, f"close response for epoch {fe.epoch}")
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
    await fe.wait_until(lambda: fe.pending_memory, f"GMEM read for TMA operation {load}")
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
    await fe.wait_until(lambda: "close_rsp" in fe.lifecycle, f"close response for epoch {fe.epoch}")
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
    def close_order_pending():
        if fe.read("order_req_valid"):
            return True
        assert not fe.read("close_rsp_valid"), f"close response preceded ordering at cycle {fe.cycle}"
        return False
    await fe.wait_until(close_order_pending, "close ordering request")
    request = fe.read("order_req_payload")
    assert (request >> 102) & 7 == 4
    for _ in range(5):
        await fe.edge()
        assert fe.read("order_req_valid") and fe.read("order_req_payload") == request
        assert fe.read("stopped") and not fe.read("close_rsp_valid")
    dut.close_rsp_ready.value = 0
    dut.order_req_ready.value = 1
    await fe.wait_until(lambda: fe.read("close_rsp_valid"), "close response after ordering")
    for _ in range(3):
        await fe.edge()
        assert fe.read("close_rsp_valid") and not fe.read("open_req_ready")
    dut.close_rsp_ready.value = 1
    await fe.edge()
    # Normal reopen changes epoch without resetting storage. Read the actual
    # SMEM line through LSU to check both masked dirty writebacks.
    fe.epoch = 2
    await fe.open(release_reset=False)
    data = await fe.read_line(base)
    objects = unpack("<QQ", data[:16])
    assert objects == tuple((1 << 62) | (count << 20) | (count-1) for count in (3, 5))
