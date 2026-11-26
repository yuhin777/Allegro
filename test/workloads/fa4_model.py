"""Host tensors, project Tensor Maps and SM100a FA4 layout for the RTL fixture."""
from dataclasses import dataclass
from struct import pack_into
import numpy as np

from workload_protocol import pack


@dataclass(frozen=True)
class Case:
    depth: int
    heads: int
    batches: int
    sequence: int
    causal: bool

    @property
    def stages(self):
        return 2 if self.causal else 1

    def q_smem(self, stage):
        return (68608 + 32768 * stage) if self.causal else 18432

    def kv_smem(self, slot):
        return (134144 if self.causal else 34816) + slot * 256 * self.depth

    def o_smem(self, stage):
        return (3072 + 32768 * stage) if self.causal else 2048


CASES = {"F1": Case(64, 32, 2, 128, False), "F2": Case(128, 16, 32, 1024, True)}
MAP_BASE = 0x10000
TENSOR_BASE = 0x10000000
TENSOR_SPAN = 0x10000000
NAMES = "QKVO"


def inputs(case, name, row, col, head, batch, pattern):
    """Small exact half operands; each K16 slice contributes to the score."""
    if pattern == "uniform":
        return np.broadcast_to(np.float16(name == "V"), np.broadcast_shapes(np.shape(row), np.shape(col)))
    phase = (head + 3 * batch) % 7
    if name == "Q":
        value = ((row + 3 * col + phase) % 5 - 2) * np.where(col % 16 == 0, 0.5, 0.125)
    elif name == "K":
        value = ((row * 3 + 2 * col + phase) % 7 - 3) * np.where(col % 16 == 1, 0.5, 0.125)
    else:
        value = ((5 * row + 7 * col + phase) % 13 - 6) * 0.25
    return value.astype(np.float16)


def tile(case, name, row, rows, head, batch, pattern):
    return inputs(case, name, np.arange(row, row+rows)[:, None], np.arange(case.depth)[None, :],
                  head, batch, pattern)


def tensor_map(case, name):
    descriptor = bytearray(128)
    descriptor[:4] = bytes((0x10, 3, 6, 3))
    pack_into("<Q", descriptor, 4, TENSOR_BASE + NAMES.index(name)*TENSOR_SPAN)
    pack_into("<5I", descriptor, 12, case.depth-1, case.sequence-1, case.heads-1, case.batches-1, 0)
    pack_into("<5Q", descriptor, 32, 0, 2*case.depth*case.heads, 2*case.depth,
              2*case.depth*case.heads*case.sequence, 0)
    pack_into("<5H", descriptor, 72, 64, 128, 1, 1, 0)
    descriptor[82:86] = bytes((1,1,1,1))
    return descriptor


class Memory:
    """Sparse host GMEM. READ is derived by decoding contiguous B/S/H/D addresses."""
    def __init__(self, case, pattern):
        self.case, self.pattern = case, pattern
        self.output = {}
        self.maps = {MAP_BASE + 128*i: tensor_map(case, name) for i, name in enumerate(NAMES)}

    def addr(self, name, batch, row, head, dim):
        c = self.case
        return TENSOR_BASE + NAMES.index(name)*TENSOR_SPAN + 2*(((batch*c.sequence+row)*c.heads+head)*c.depth+dim)

    def read(self, addr):
        if addr in self.maps:
            return self.maps[addr]
        c = self.case
        kind, offset = divmod(addr-TENSOR_BASE, TENSOR_SPAN)
        assert 0 <= kind < 3 and offset % 128 == 0
        pos, dim = divmod(offset // 2, c.depth)
        pos, head = divmod(pos, c.heads)
        batch, row = divmod(pos, c.sequence)
        assert batch < c.batches
        return inputs(c, NAMES[kind], row, dim+np.arange(64), head, batch, self.pattern).astype("<f2").tobytes()

    def write(self, addr, data, mask):
        c = self.case
        start = TENSOR_BASE + 3*TENSOR_SPAN
        assert start <= addr <= start + 2*c.batches*c.sequence*c.heads*c.depth - 128
        assert addr % 128 == 0 and mask
        for i in range(128):
            if mask & (1 << i):
                assert addr+i not in self.output, ("duplicate O write",addr+i)
                self.output[addr+i] = data[i]

    def output_tile(self, batch, head, row):
        c = self.case
        blob = bytearray()
        for r in range(row,row+128):
            start = self.addr("O",batch,r,head,0)
            blob.extend(self.output[start+i] for i in range(2*c.depth))
        return np.frombuffer(blob, dtype="<f2").reshape(128,c.depth)


def mma_payload(case, op_id, pv, stage, step, kv_slot, use_d):
    n = case.depth if pv else 128
    k16_offset = 16384*(step//4) + 32*(step%4)
    # Offline PTX combines each low descriptor word with 0x40004040.
    desc_hi = 0x40004040 << 32
    if pv:
        raw_idesc = 0x08110010 if n == 64 else 0x08210010
        a_ref = 64 + 128*stage + 8*step
        b_desc = desc_hi | ((0x400 << 16) if n == 128 else 0) | ((case.kv_smem(kv_slot)+2048*step)//16)
        dest = 256 + 128*stage
    else:
        raw_idesc = 0x08200010
        a_ref = desc_hi | (1 << 16) | ((case.q_smem(stage)+k16_offset)//16)
        b_desc = desc_hi | (1 << 16) | ((case.kv_smem(kv_slot)+k16_offset)//16)
        dest = 128*stage
    return pack((58,op_id),(3,0),(4,0),(4,0),(2,((raw_idesc>>17)&63)//8-1),
                (1,pv),(1,0),(1,use_d),(1,0),(1,(raw_idesc>>16)&1),(1,0),(1,0),(1,0),
                (4,0),(2,0),(2,0),(128,0),(7,0),(64,a_ref),(64,b_desc),(32,dest),(32,0),(32,0))


def direct_attention(case, q, k, v, first_row):
    scores = q.astype(np.float64) @ k.astype(np.float64).T / np.sqrt(case.depth)
    if case.causal:
        scores[np.arange(k.shape[0])[None,:] > (first_row + np.arange(128))[:,None]] = -np.inf
    weights = np.exp(scores - np.max(scores,axis=1,keepdims=True))
    return (weights @ v.astype(np.float64)) / np.sum(weights,axis=1,keepdims=True)
