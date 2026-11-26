"""Withhold one real partition-0 ACK while partition 1 commits independently."""
import cocotb
import numpy as np
from cocotb.triggers import Timer
from linear_driver import LinearFrontEnd
from mma_driver import Accumulation, descriptor
from fa4_model import pack


def masked_mma(op, partition):
    enabled = ((1 << 32)-1) << (32*partition)
    return pack((58, op), (3, 0), (4, 0), (4, 0), (2, 0), (1, 0), (1, 0),
                (1, 0), (5, 0), (4, 0), (2, 0), (2, 0), (128, enabled ^ ((1 << 128)-1)),
                (7, 0), (64, descriptor(8192)), (64, descriptor(12288)),
                (32, 128*partition), (32, 0), (32, 0))


async def exercise(d, fail):
    fe = Accumulation(d)
    def probe(name):
        return d._id("ack_client[0].ack_route[0].observed.probe."+name, extended=False)
    await fe.edge()
    await fe.edge()
    d.rst_n.value = 1
    await fe.send("open_req", 1)
    await fe.wait_until(lambda: "open_rsp" in fe.lifecycle, f"open response for epoch {fe.epoch}")
    a = fe.sign(320)
    await fe.send("tmem_manage", pack((58, a), (2, 0), (32, 0), (10, 512)))
    await fe.result(a, "tmem_manage_rsp")
    barrier = 256
    await fe.result(await fe.barrier(barrier, 0, count=1), "bar_rsp")
    # Two panels provide real source values for both engines and every core.
    await fe.write_panel(8192, np.ones((128, 16)))
    await fe.write_panel(12288, np.ones((128, 16)))
    old, young = fe.sign(5), fe.sign(6)
    token = (7 << 8) | (1 << 5)
    probe("target").value = pack((58, old), (4, 0), (16, token))
    probe("stall").value = 1
    await fe.send("mma_cmd", masked_mma(old, 0))
    await fe.send("mma_cmd", masked_mma(young, 1))
    commit = fe.sign(6)
    await fe.send("tc_commit", pack((58, commit), (32, barrier)))
    await Timer(1, units="ns")
    captured = int(d._id("tracker.pending", extended=False)[0].value)
    assert captured.bit_count() == 1
    index = captured.bit_length()-1
    assert int(d._id("tracker.ops", extended=False)[index].value) == young
    await fe.result(young, "tc_op_done")
    await fe.result(commit, "tc_commit_done")
    await fe.wait_barrier(barrier, issuer=64)
    assert old not in fe.results
    assert int(probe("in_valid").value) and int(probe("matched").value)
    live = fe.read("live")
    entries = [(live >> (61*i)) & ((1 << 61)-1) for i in range(3)]
    assert [v & ((1 << 58)-1) for v in entries if v >> 60] == [old, young]
    probe("inject_memory").value = int(fail)
    probe("stall").value = 0
    if fail:
        for _ in range(8):
            await Timer(1, units="ns")
            assert not fe.read("tc_op_done_valid") and not fe.read("tc_commit_done_valid")
            if fe.read("fault"):
                break
            d.clk.value = 1
            await Timer(1, units="ns")
            d.clk.value = 0
        assert fe.read("fault")
    else:
        await fe.result(old, "tc_op_done")
        await fe.shutdown([barrier])
        assert not fe.results


@cocotb.test()
async def younger_notifies_before_older_ack(dut):
    await exercise(dut, False)


@cocotb.test()
async def old_write_error_after_younger_arrival(dut):
    await exercise(dut, True)


@cocotb.test()
async def empty_commits_and_lifecycle_exclusion(d):
    fe = LinearFrontEnd(d)
    await fe.open()
    a, b = 256, 264
    await fe.result(await fe.barrier(b, 0, count=1), "bar_rsp")
    d.bar_rsp_ready.value = 0
    init = await fe.barrier(a, 0, count=1)
    await fe.wait_until(lambda: fe.read("bar_rsp_valid"), f"barrier response for {init}")
    held = fe.read("bar_rsp_payload")
    assert held >> 5 == init

    other = fe.sign(6)
    await fe.send("tc_commit", pack((58, other), (32, b)))
    same = fe.sign(5)
    d.tc_commit_payload.value = pack((58, same), (32, a))
    d.tc_commit_valid.value = 1
    for _ in range(100):
        assert not await fe.edge("tc_commit_ready")
        assert fe.read("bar_rsp_valid") and fe.read("bar_rsp_payload") == held
        if other in fe.results:
            break
    assert other in fe.results
    d.bar_rsp_ready.value = 1
    await fe.wait_edge("tc_commit_ready", transaction=same)
    d.tc_commit_valid.value = 0
    await fe.result(init, "bar_rsp")
    for op in (other, same):
        await fe.result(op, "tc_commit_done")

    d.order_req_ready.value = 0
    wait = await fe.barrier(a, 4)
    await fe.wait_until(lambda: fe.read("order_req_valid"), f"order request for barrier wait {wait}")
    order = fe.read("order_req_payload")
    for _ in range(4):
        await fe.edge()
        assert fe.read("order_req_valid") and fe.read("order_req_payload") == order
        assert wait not in fe.results
    d.order_req_ready.value = 1
    assert await fe.result(wait, "bar_rsp") & 1
    await fe.wait_barrier(b)
    # A held INVAL result reserves its address through its result handshake.
    d.bar_rsp_ready.value = 0
    inv = await fe.barrier(a, 1)
    await fe.wait_until(lambda: fe.read("bar_rsp_valid"), f"barrier response for {inv}")
    d.tc_commit_payload.value = pack((58, fe.sign(7)), (32, a))
    for _ in range(3):
        assert not await fe.edge("tc_commit_ready")
    d.bar_rsp_ready.value = 1
    await fe.result(inv, "bar_rsp")
    await fe.result(await fe.barrier(b, 1), "bar_rsp")
    await fe.send("close_req")
    await fe.wait_until(lambda: "close_rsp" in fe.lifecycle, f"close response for epoch {fe.epoch}")
