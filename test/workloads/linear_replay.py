"""Linear bulk two-phase workload and CTA lifecycle on the integrated subsystem."""
from struct import unpack

import cocotb

from workload_protocol import pack
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
async def open_response_holds_until_accepted(dut):
    fe = LinearFrontEnd(dut)
    dut.open_rsp_ready.value = 0
    await fe.edge()
    dut.rst_n.value = 1
    dut.isolated.value = 0
    dut.open_req_payload.value = 1
    dut.open_req_valid.value = 1
    for _ in range(3):
        assert not await fe.edge("open_req_ready")
    dut.isolated.value = 1
    assert await fe.edge("open_req_ready")
    dut.open_req_valid.value = 0
    alloc = fe.sign(0)
    dut.tmem_manage_payload.value = pack((58, alloc), (2, 0), (32, 0), (10, 512))
    dut.tmem_manage_valid.value = 1
    for _ in range(4):
        assert await fe.edge("open_rsp_valid")
        assert fe.read("stopped") and not fe.read("tmem_manage_ready")
    dut.open_rsp_ready.value = 1
    assert not await fe.edge("tmem_manage_ready")
    assert await fe.edge("tmem_manage_ready")
    dut.tmem_manage_valid.value = 0
    assert await fe.result(alloc, "tmem_manage_rsp") == alloc << 32


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


@cocotb.test()
async def close_drains_queued_wait(dut):
    fe = LinearFrontEnd(dut)
    await fe.open()
    barrier = 256
    await fe.result(await fe.barrier(barrier, 0, count=1), "bar_rsp")
    dut.order_req_ready.value = 0
    arrival = await fe.barrier(barrier, 2, count=1)
    wait = await fe.barrier(barrier, 4)
    await fe.send("close_req")
    await fe.wait_until(lambda: fe.read("order_req_valid"), "release for queued arrival")
    assert fe.read("stopped") and wait not in fe.results
    dut.order_req_ready.value = 1
    await fe.result(arrival, "bar_rsp")
    assert await fe.result(wait, "bar_rsp") & 1
    await fe.wait_until(lambda: "close_rsp" in fe.lifecycle, "close after queued wait")
    assert fe.order_kinds == [0, 1, 4]
