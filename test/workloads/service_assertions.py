"""Run each illegal external service response in an independent simulation."""
import cocotb

from linear_driver import LinearFrontEnd


@cocotb.test()
async def non_ok_memory(dut):
    fe = LinearFrontEnd(dut)
    await fe.open()
    barrier = 256
    await fe.result(await fe.barrier(barrier, 0, count=1), "bar_rsp")
    await fe.load(0, 0, 16, barrier)
    await fe.wait_until(lambda: fe.pending_memory, "outstanding GMEM read")
    fe.pending_memory[0] |= 4
    await fe.edge()
    raise AssertionError("GMEM service error escaped the interface assertion")


@cocotb.test()
async def non_ok_ordering(dut):
    fe = LinearFrontEnd(dut)
    await fe.open()
    await fe.send("close_req")
    await fe.wait_until(lambda: fe.pending_order, "outstanding CTA close ordering")
    fe.pending_order[0] |= 4
    await fe.edge()
    raise AssertionError("Ordering service error escaped the interface assertion")
