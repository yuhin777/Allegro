"""FA4 tensor copies, publication checks and workload initialization."""
from fa4_model import MAP_BASE, NAMES, Memory, tile
from frontend import FrontEnd
from workload_protocol import MASK128, pack

# Elected lane 0 of each specialist warp in both 512-thread CTA exports.
MMA_ISSUER = 12 * 32
LOAD_ISSUER = 14 * 32


class Fa4FrontEnd(FrontEnd):
    def __init__(self, dut, case, pattern):
        super().__init__(dut, memory=Memory(case, pattern))
        self.case = case
        self.copy_bytes, self.copy_atoms, self.copy_expected, self.producer = {}, {}, {}, {}
        self.active_stage = {}

    def check_acquire(self, addr):
        if addr in self.active_stage:
            assert all(op in self.producer for op in self.active_stage[addr]), "early acquire"

    def sample_transfers(self):
        if not self.copy_bytes:
            return
        sm = self.d.sm
        request_fire = int(sm.t_req_v.value) & int(sm.t_req_r.value)
        ack_fire = int(sm.t_rsp_v.value) & int(sm.t_rsp_r.value)
        # Retire old tokens first; reusing a token on its retirement edge is legal.
        for group in range(8):
            if ack_fire >> group & 1:
                rsp = int(sm.t_rsp[group].value)
                if rsp >> 210:
                    tag = (rsp >> 132) & ((1<<78)-1)
                    assert rsp & 15 == 0 and tag in self.copy_atoms, (tag,group)
                    self.copy_bytes[tag>>20] += self.copy_atoms.pop(tag)
            if request_fire >> group & 1:
                req = int(sm.t_req[group].value)
                if req >> 254:
                    tag = (req >> 176) & ((1<<78)-1)
                    assert tag not in self.copy_atoms and tag>>20 in self.copy_bytes
                    mask=(req >> 128) & 0xffff
                    address=(req >> 144) & 0xffffffff
                    op=tag>>20
                    expected,remaining=self.copy_expected[op][address]
                    assert mask and (mask&remaining)==mask
                    data=req&MASK128
                    for byte in range(16):
                        if mask>>byte&1:
                            assert (data>>(8*byte))&255 == expected[byte], (op,address,byte)
                    if remaining==mask:
                        del self.copy_expected[op][address]
                    else:
                        self.copy_expected[op][address]=(expected,remaining^mask)
                    self.copy_atoms[tag] = mask.bit_count()
        if int(sm.producer_done_valid.value) and int(sm.producer_done_ready.value):
            value=int(sm.producer_done_payload.value)
            op,count,status=value>>36,(value>>4)&0xffffffff,value&15
            assert op not in self.producer and status==0 and self.copy_bytes[op]==count==16384
            assert not self.copy_expected[op]
            self.producer[op]=self.cycle

    async def tma(self,name,opcode,smem,coord,bar=0,issuer=288,wait_n=0):
        op=self.sign(issuer)
        map_addr=MAP_BASE+128*NAMES.index(name) if name else 0
        coords=sum(int(x)<<(32*i) for i,x in enumerate(coord))
        if opcode==0:
            self.copy_bytes[op]=0
            dim,row,head,batch=coord
            panel=tile(self.case,name,row,128,head,batch,self.mem.pattern)[:,dim:dim+64].astype("<f2")
            expected={}
            for r in range(128):
                for atom in range(8):
                    x=smem+128*r+16*atom
                    expected[x^(((x>>7)&7)<<4)]=(panel[r,8*atom:8*atom+8].tobytes(),0xffff)
            self.copy_expected[op]=expected
        await self.send("tma_cmd",pack((58,op),(3,opcode),(64,map_addr),(32,smem),(64,0),
                        (32,0),(32,bar),(128,coords),(64,0),(1,wait_n)))
        return op

    async def copy(self,name,smem,row,batch,head,bar):
        n=self.case.depth//64
        expect=await self.barrier(bar,3,count=0,nbytes=16384*n,issuer=LOAD_ISSUER)
        await self.result(expect,"bar_rsp")
        copies=[]
        for panel in range(n):
            copies.append(await self.tma(name,0,smem+panel*16384,(panel*64,row,head,batch),bar,issuer=LOAD_ISSUER))
        self.active_stage[bar]=copies
        await self.wait_barrier(bar,issuer=MMA_ISSUER)
        assert all(op in self.producer for op in copies) and sum(self.copy_bytes[op] for op in copies)==n*16384
        del self.active_stage[bar]
        for op in copies:
            assert (await self.result(op,"tma_rsp"))&((1<<64)-1)==16384
            del self.copy_bytes[op], self.copy_expected[op], self.producer[op]

    async def lifecycle_start(self,barriers):
        await self.open()
        for name in NAMES:
            await self.result(await self.tma(name,6,0,(),issuer=0),"tma_rsp")
        for addr,count in barriers.items():
            op=await self.barrier(addr,0,count=count,issuer=0)
            await self.result(op,"bar_rsp")
        await self.result(await self.barrier(0,5,issuer=0),"bar_rsp")
        alloc=self.sign(MMA_ISSUER)
        await self.send("tmem_manage",pack((58,alloc),(2,0),(32,0),(10,512)))
        rsp=await self.result(alloc,"tmem_manage_rsp")
        assert rsp & 0xffffffff == 0
        dst=280 if self.case.causal else 328
        await self.write_smem(dst&~15,0,0xf<<(dst%16),op_id=alloc)
        assert await self.read_smem(dst&~15,0xf<<(dst%16))==0
