"""Integration scenarios for the SMEM subsystem."""

from random import Random
from struct import pack_into

import cocotb
from cocotb.triggers import RisingEdge

from smem_fabric_driver import Fabric, descriptor, packed


# Tensor addressing, swizzle and clipping

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
async def signed_origin_and_outer_carries(dut):
    class StalledFabric(Fabric):
        async def edge(self, probe=None):
            self.d.gmem_req_ready.value = rng.randrange(4) != 0
            return await super().edge(probe)

    rng = Random(0xB1AC)
    f = StalledFabric(dut)
    await f.reset()
    box = (256, 3, 2, 2)
    dims = (238, 2, 2, 2)
    strides = (0x820, 0x270, 0x140)
    origin = (-11, -1, 0, -1)
    base = 0x400
    f.mem[0:128] = descriptor(base, dims, strides, box)
    for k in range(base, 0x2000):
        f.mem[k] = rng.randrange(256)
    await f.result(await f.bar(0, 1))
    total = 2 * box[0] * box[1] * box[2] * box[3]
    await f.result(await f.bar(3, nbytes=total))
    assert await f.result(await f.tma(0, 0, origin)) == total
    assert await f.result(await f.bar(4)) == 1
    expected = {}
    for w in range(box[3]):
        for z in range(box[2]):
            for y in range(box[1]):
                row = (w * box[2] + z) * box[1] + y
                for b in range(2 * box[0]):
                    u = (origin[0] + b // 2, origin[1] + y, origin[2] + z, origin[3] + w)
                    addr = base + 2 * u[0] + sum(i * s for i, s in zip(u[1:], strides)) + b % 2
                    panel_row = (b // 128) * (box[1] * box[2] * box[3]) + row
                    x = 0xf0 + 128 * panel_row + b % 128
                    expected[x ^ (((x >> 7) & 7) << 4)] = (
                        f.mem[addr] if all(0 <= i < d for i, d in zip(u, dims)) else 0
                    )
    await f.check_smem(expected)


@cocotb.test()
async def clipped_stores_at_end_of_smem(dut):
    f = Fabric(dut)
    await f.reset()
    limit, src, dst = 228 * 1024, 0x1000, 0x4000
    cases = [
        # Only the first 128-byte row exists in the destination tensor.
        ((64, 2, 1, 1), (64, 1, 1, 1), (0, 0, 0, 0)),
        # Clip every dimension. Panel and row pitches still use the original box.
        ((144, 3, 3, 3), (77, 3, 3, 3), (5, 1, 1, 1)),
    ]
    await f.result(await f.bar(0, 1))
    for i, (box, dim, origin) in enumerate(cases):
        strides = (160, 512, 1536)
        image = descriptor(dst, dim, strides)
        pack_into("<5H", image, 72, *box, 0)
        f.mem[128*i:128*(i+1)] = image
        offsets = {}
        for w in range(dim[3] - origin[3]):
            for z in range(dim[2] - origin[2]):
                for y in range(dim[1] - origin[1]):
                    row = y + box[1] * (z + box[2]*w)
                    for x in range(dim[0] - origin[0]):
                        g = dst + 2*(x+origin[0]) + sum(a*b for a, b in
                            zip((y+origin[1], z+origin[2], w+origin[3]), strides))
                        for byte in range(2):
                            panel, within = divmod(2*x + byte, 128)
                            offsets[g+byte] = 128*(panel*box[1]*box[2]*box[3] + row) + within
        size = (max(offsets.values()) // 128 + 1)*128
        base = limit - size
        f.mem[src:src+size] = bytes((j*13 + j//128) % 256 for j in range(size))
        await f.result(await f.bar(3, nbytes=size))
        await f.result(await f.linear(src, base, size))
        expected = f.mem.copy()
        for address, offset in offsets.items():
            logical = base + offset
            physical = logical ^ (((logical >> 7) & 7) << 4)
            expected[address] = f.mem[src + physical - base]
        store = await f.tma(1, 128*i, origin, smem=base)
        assert await f.result(store) == 2*box[0]*box[1]*box[2]*box[3]
        assert f.mem == expected

    # An entirely OOB tile advances logical bytes without any data access.
    requests = f.gmem_requests
    assert await f.result(await f.tma(1, 0, (64, 0, 0, 0), smem=limit - 16)) == 256
    assert f.gmem_requests == requests


# Copy throughput and return arbitration

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
    f.load_write_addresses = []
    f.pending.extend(reversed(f.held_reads))
    for _ in range(30):
        await f.edge()
    assert len(f.pending) == 48 and not f.val("gmem_rsp_ready")
    assert load not in f.results
    dut.smem_wr_ack_ready.value = 255
    assert await f.result(load) == 8192
    # The first 16 returned sectors occupy slots 0 through 15 and precede all refills.
    assert f.load_write_addresses[:16] == [0x2000 + 128 * i for i in range(63, 47, -1)]
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
async def ready_ack_bypasses_blocked_store_return(dut):
    f = Fabric(dut)
    await f.reset()
    fresh_contentions = 0

    async def check_returns():
        nonlocal fresh_contentions
        while True:
            await RisingEdge(dut.clk)
            # Client 8 has one read return and one write ACK per SMEM group.
            both = (f.val("rd_rsp_valid") & f.val("wr_ack_valid")) >> (8 * 8)
            fresh = both & ~f.val("lock_ack") & 0xff
            fresh_contentions += fresh.bit_count()
            assert not (fresh & ~f.val("t_rsp_r")), "a ready write ACK lost its group slot"

    monitor = cocotb.start_soon(check_returns())
    try:
        f.mem[:128] = descriptor(0x8000, (64, 32, 1, 1), (128, 4096, 4096), box=(64, 32, 1, 1))
        await f.result(await f.bar(0, 1))
        await f.result(await f.bar(3, nbytes=1920))
        f.hold_reads = True
        load = await f.linear(0x4000, 0x2000, 1920)
        store = await f.tma(1, smem=0x6000)
        while not (f.val("t_req_v") and len(f.held_reads) == 15):
            await f.edge()
        await f.edge()
        # Release the 15 load replies while the independent store reads SMEM.
        rng = Random(1)
        for reply in f.held_reads:
            for _ in range(rng.randrange(5)):
                await f.edge()
            f.pending.append(reply)
            await f.edge()
        assert await f.result(store) == 4096
        assert await f.result(load) == 1920
        assert fresh_contentions
    finally:
        monitor.kill()


# Store groups and issuer-scoped fences

@cocotb.test()
async def empty_commit_advances_wait_read_cutoff(dut):
    f = Fabric(dut)
    await f.reset()
    f.mem[:128] = descriptor(0x4000, (64, 1, 1, 1), (128, 128, 128), box=(64, 1, 1, 1))
    await f.result(await f.bar(0, count=1))
    await f.result(await f.bar(3, nbytes=128))
    await f.block_group(0)
    f.hold_reads = True
    load = await f.tma(0, smem=0x2000, issuer=9)
    await f.result(await f.tma(3, issuer=9))
    assert await f.result(await f.tma(4, issuer=9, wait_n=1)) == 0
    await f.result(await f.tma(3, issuer=9))  # close the empty group
    assert await f.result(await f.tma(4, issuer=8)) == 0
    wait = await f.tma(4, issuer=9, wait_n=1)
    while not f.held_reads:
        await f.edge()
    for _ in range(10):
        await f.edge()
        assert wait not in f.results
    f.pending.extend(f.held_reads)
    assert await f.result(wait) == 0
    assert load not in f.results
    dut.smem_wr_ack_ready.value = 255
    assert await f.result(load) == 128
    assert await f.result(await f.bar(4)) == 1


@cocotb.test()
async def proxy_fence_waits_only_for_its_issuer(dut):
    f = Fabric(dut)
    await f.reset()
    f.mem[:128] = descriptor(0x4000, (8, 1, 1, 1), (16, 16, 16), box=(8, 1, 1, 1))
    f.hold_store_acks = True
    store = await f.tma(1, smem=0)
    while not f.store_acks:
        await f.edge()

    async def fence(issuer):
        key = f.id() | (issuer << 32)
        await f.send("tma_cmd", packed((58, key), (3, 5), (64, 0), (32, 0), (64, 0),
                                       (32, 0), (32, 0), (128, 0), (64, 0), (1, 0)))
        return key

    other = await fence(1)
    for _ in range(16):
        if await f.edge("order_req_valid") & 1:
            break
    else:
        raise AssertionError("unrelated store ACK blocked proxy fence")
    assert list(f.order[0]) == [other]
    await f.result(other)

    same = await fence(0)
    for _ in range(16):
        assert not (await f.edge("order_req_valid") & 1)
    f.pending.extend(f.store_acks)
    while not (await f.edge("order_req_valid") & 1):
        pass
    assert list(f.order[0]) == [same]
    assert await f.result(same) == 0
    assert await f.result(store) == 16


@cocotb.test()
async def init_fence_progresses_while_other_issuer_holds_init_result(dut):
    f = Fabric(dut)
    await f.reset()
    dut.bar_rsp_ready.value = 0
    init = await f.bar(0, count=1, addr=0)
    while not f.val("bar_rsp_valid"):
        await f.edge()
    held = f.val("bar_rsp_payload")
    assert held >> 1 == init

    fence = await f.bar(5, addr=0, issuer=1)
    for _ in range(16):
        assert f.val("bar_rsp_valid") and f.val("bar_rsp_payload") == held
        if await f.edge("order_req_valid") & 2:
            break
    else:
        raise AssertionError("FENCE_INIT waited for another issuer to retire INIT at address 0")
    assert list(f.order[1]) == [fence]
    dut.bar_rsp_ready.value = 1
    await f.result(init)
    await f.result(fence)


# Barrier waits, phase changes and live command IDs

@cocotb.test()
async def same_issuer_waits_enter_service_in_acceptance_order(dut):
    f = Fabric(dut)
    await f.reset()
    target, ready_object = 0x1000, 0x1010
    services = {}

    async def observe_services():
        while True:
            await RisingEdge(dut.clk)
            if f.val("service_req_valid") and f.val("service_req_ready"):
                payload = f.val("service_req_payload")
                key = (payload >> 133) & ((1 << 58) - 1)
                services[key] = f.cycle

    monitor = cocotb.start_soon(observe_services())
    try:
        for addr in (target, ready_object):
            await f.result(await f.bar(0, count=1, addr=addr))
        await f.result(await f.bar(2, count=1, addr=ready_object, issuer=1))
        first = await f.bar(4, addr=ready_object)
        prefix = [await f.bar(4, addr=target) for _ in range(2)]
        assert await f.result(first) == 1
        older = await f.bar(4, addr=target)
        younger = await f.bar(4, addr=target)
        while older not in services or younger not in services:
            await f.edge()

        # Flip between the two timeout edges after the freed wait slot is reused.
        while f.cycle < min(services[older], services[younger]) + 64:
            await f.edge()
        await f.result(await f.bar(2, count=1, addr=target, issuer=1))
        assert [await f.result(key) for key in [*prefix, older, younger]] == [0, 0, 0, 1]

        # A younger ordinary update also follows its issuer's pending TRY probes.
        waits = [await f.bar(4, addr=target) for _ in range(4)]
        update = await f.bar(2, count=1, addr=target)
        await f.result(update)
        assert [await f.result(key) for key in waits] == [1] * len(waits)
        ordered = [first, *prefix, older, younger, *waits, update]
        assert sorted(ordered, key=services.__getitem__) == ordered
    finally:
        monitor.kill()


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
    assert not f.val("wait_cmd_ready"), "all 32 wait records should hold results"
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
