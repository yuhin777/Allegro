"""Present one out-of-contract transaction per simulation."""

import cocotb

from smem_fabric_driver import Fabric, descriptor, packed


async def await_assertion(fabric):
    for _ in range(256):
        await fabric.edge()
    raise AssertionError("TMA contract assertion did not fire")


@cocotb.test()
async def reserved_opcode(dut):
    f = Fabric(dut)
    await f.reset()
    await f.tma(7)
    await await_assertion(f)


@cocotb.test()
async def misaligned_map(dut):
    f = Fabric(dut)
    await f.reset()
    await f.tma(0, map_addr=1)
    await await_assertion(f)


async def unsolicited_return(dut, response_class):
    f = Fabric(dut)
    await f.reset()
    f.pending.append(packed((2, response_class), (6, 0), (1, 0), (1024, 0), (4, 0)))
    await await_assertion(f)


@cocotb.test()
async def unsolicited_descriptor_return(dut):
    await unsolicited_return(dut, 1)


@cocotb.test()
async def unsolicited_data_return(dut):
    await unsolicited_return(dut, 0)


async def tensor_store(dut, smem=0, gmem=0x4000, version=0x10):
    f = Fabric(dut)
    await f.reset()
    # One full 128-byte sector. Move a single aligned endpoint to straddle a limit.
    shape = (64, 1, 1, 1)
    f.mem[:128] = descriptor(gmem, shape, (128, 128, 128), box=shape)
    f.mem[0] = version
    await f.tma(1, smem=smem)
    await await_assertion(f)


@cocotb.test()
async def malformed_descriptor(dut):
    await tensor_store(dut, version=0)


@cocotb.test()
async def expanded_smem_overflow(dut):
    await tensor_store(dut, smem=228 * 1024 - 16)


@cocotb.test()
async def expanded_gmem_overflow(dut):
    await tensor_store(dut, gmem=2**64 - 16)
