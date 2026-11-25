"""Cocotb replay of single-CTA FA4 commands on blackwell_async_subsystem_top."""
from collections import defaultdict, deque
import os
import cocotb
from cocotb.triggers import Timer
import numpy as np

from fa4_model import CASES, MAP_BASE, NAMES, Memory, direct_attention, mma_payload, pack, tile

MASK128 = (1 << 128)-1

# Elected lane 0 of each specialist warp in both 512-thread CTA exports.
CORRECTION_FIRST = 8*32
MMA_ISSUER = 12*32
STORE_ISSUER = 13*32
LOAD_ISSUER = 14*32


class FrontEnd:
    """Advance one common clock and settle real RF, memory and ordering obligations."""
    returns = {"tc_op_done":4,"tc_commit_done":4,"tmem_ldst_done":4,"tmem_wait_done":4,
               "bar_rsp":5,"tma_rsp":68,"tmem_manage_rsp":36}
    def __init__(self,dut,case,pattern):
        self.d, self.case = dut,case
        self.mem = Memory(case,pattern)
        self.pending_memory, self.pending_order = deque(),deque()
        self.results, self.rf = {},defaultdict(list)
        self.observe = lambda: None
        self.seq, self.phase = defaultdict(int),defaultdict(int)
        self.cycle, self.epoch = 0,1
        self.written_atoms, self.acks = {},set()
        self.lifecycle = set()
        self.acquired = {}
        self.order_kind, self.wait_address = {}, {}
        self.copy_bytes, self.copy_atoms, self.copy_expected, self.producer = {}, {}, {}, {}
        self.active_stage = {}
        for name in (*self.returns,"rf_load","open_rsp","close_rsp","gmem_req","order_req"):
            getattr(dut,name+"_ready").value = 1
        for name in ("open_req","close_req","tmem_manage","tmem_ldst","rf_store","tmem_wait",
                     "mma_cmd","tc_commit","tma_cmd","bar_cmd","smem_rd","smem_wr","gmem_rsp","order_rsp"):
            getattr(dut,name+"_valid").value = 0
        dut.smem_rd_rsp_ready.value = 255
        dut.smem_wr_ack_ready.value = 255
        dut.clk.value=0
        dut.isolated.value=1
        dut.lsu_quiescent.value=1
        dut.rst_n.value=0

    def read(self,name):
        return int(getattr(self.d,name).value)

    def fired(self,channel):
        valid=self.read(channel+"_valid")
        return valid & self.read(channel+"_ready") if valid else 0

    def sign(self,issuer):
        key = pack((16,self.epoch),(10,issuer),(32,self.seq[issuer]))
        self.seq[issuer]+=1
        return key

    def trace_copy_acks(self):
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

    async def edge(self,probe=None):
        d=self.d
        for channel,queue in (("gmem_rsp",self.pending_memory),("order_rsp",self.pending_order)):
            getattr(d,channel+"_valid").value = bool(queue)
            getattr(d,channel+"_payload").value = queue[0] if queue else 0
        await Timer(1,units="ns")
        ready = self.read(probe) if probe else None
        if self.read("rst_n"):
            assert not self.read("fault"), f"sticky fault at cycle {self.cycle}, requests {list(self.results)[-4:]}"
            for channel,bits in self.returns.items():
                if self.fired(channel):
                    value=self.read(channel+"_payload")
                    op=value>>bits
                    assert op not in self.results,(channel,op)
                    status=(value>>(bits-4))&15
                    assert status==0,(channel,op,status,self.cycle)
                    if channel=="bar_rsp" and op in self.wait_address and value&1:
                        assert op in self.acquired and self.acquired[op]<self.cycle, "wait result bypassed acquire"
                    self.results[op]=(channel,value)
            if self.fired("rf_load"):
                value=self.read("rf_load_payload")
                op,index,last=value>>1032,(value>>1025)&127,(value>>1024)&1
                assert index==len(self.rf[op])
                self.rf[op].append((last,(value & ((1<<1024)-1)).to_bytes(128,"little")))
            for channel in ("close_rsp","open_rsp"):
                if self.fired(channel):
                    assert self.read(channel+"_payload")==0
                    self.lifecycle.add(channel)
            ack_mask=self.fired("smem_wr_ack")
            for g in range(8):
                if ack_mask>>g & 1:
                    value=int(d.smem_wr_ack_payload[g].value)
                    tag=value>>4
                    assert value&15==0 and tag in self.written_atoms
                    del self.written_atoms[tag]
                    self.acks.add(tag)
            if self.fired("gmem_rsp"):
                self.pending_memory.popleft()
            if self.copy_bytes: self.trace_copy_acks()
            if self.fired("order_rsp"):
                op=self.pending_order.popleft()>>4
                if self.order_kind.pop(op)==1:
                    self.acquired[op]=self.cycle
            if self.fired("gmem_req"):
                request=self.read("gmem_req_payload")>>64
                mask=request & MASK128
                data=(request>>128)&((1<<1024)-1)
                addr=(request>>1152)&((1<<64)-1)
                opcode=(request>>1216)&7
                tag=request>>1219
                assert addr%128==0 and opcode in (0,1)
                if opcode:
                    self.mem.write(addr,data.to_bytes(128,"little"),mask)
                    reply=0
                else:
                    reply=int.from_bytes(self.mem.read(addr),"little")
                self.pending_memory.append(pack((9,tag),(1024,reply),(4,0)))
            if self.fired("order_req"):
                request=self.read("order_req_payload")
                op=request>>105
                kind=(request>>102)&7
                # This fixture uses one committed word store and a single-clock
                # GMEM model; no ACK can escape before the write is observable.
                assert not self.written_atoms
                self.order_kind[op]=kind
                if kind==1:
                    addr=self.wait_address[op]
                    if addr in self.active_stage:
                        assert all(i in self.producer for i in self.active_stage[addr]), "early acquire"
                self.pending_order.append(op<<4)
        self.observe()
        d.clk.value=1
        await Timer(1,units="ns")
        d.clk.value=0
        self.cycle+=1
        assert self.cycle<30000000,"global workload timeout"
        return ready

    async def send(self,channel,value=None):
        getattr(self.d,channel+"_valid").value=1
        if value is not None: getattr(self.d,channel+"_payload").value=value
        for _ in range(200000):
            if await self.edge(channel+"_ready"): break
        else: raise AssertionError(f"{channel} blocked at {self.cycle}")
        getattr(self.d,channel+"_valid").value=0

    async def result(self,op,channel):
        for _ in range(200000):
            if op in self.results: break
            await self.edge()
        else: raise AssertionError(f"missing {channel} for {op} at {self.cycle}")
        name,value=self.results.pop(op)
        assert name==channel,(name,channel,op)
        return value

    async def barrier(self,addr,opcode,count=0,nbytes=0,issuer=288):
        op=self.sign(issuer)
        if opcode==4: self.wait_address[op]=addr
        await self.send("bar_cmd",pack((58,op),(4,opcode),(32,addr),(32,count),(32,nbytes),
                        (1,self.phase[addr] if opcode==4 else 0),(1,0),(32,10000000 if opcode==4 else 0)))
        return op

    async def wait_barrier(self,addr,issuer=320):
        while True:
            op=await self.barrier(addr,4,issuer=issuer)
            rsp=await self.result(op,"bar_rsp")
            del self.wait_address[op]
            if rsp&1:
                assert op in self.acquired and self.acquired[op]<self.cycle
                self.phase[addr]^=1
                return

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

    async def get_rf(self,col,width,warp_base=0):
        rows=np.empty((128,width),dtype="<u4")
        for j in range(0,width,32):
            for w in range(4):
                op=self.sign((warp_base+w)*32)
                await self.send("tmem_ldst",pack((58,op),(1,0),(1,1),(32,(w*32<<16)+col+j)))
                await self.result(op,"tmem_ldst_done")
                beats=self.rf.pop(op)
                assert len(beats)==32 and [i for i,(last,_) in enumerate(beats) if last]==[31]
                for reg,(_,data) in enumerate(beats):
                    rows[32*w:32*w+32,j+reg]=np.frombuffer(data,dtype="<u4")
        return rows

    async def put_rf(self,col,words,warp_base=0):
        width=words.shape[1]
        assert words.shape[0]==128 and width%16==0
        for w in range(4):
            for j in range(0,width,16):
                op=self.sign((warp_base+w)*32)
                await self.send("tmem_ldst",pack((58,op),(1,1),(1,0),(32,(32*w<<16)+col+j)))
                for b in range(16):
                    data=int.from_bytes(words[32*w:32*w+32,j+b].astype("<u4").tobytes(),"little")
                    await self.send("rf_store",pack((58,op),(7,b),(1,b==15),(1024,data)))
                await self.result(op,"tmem_ldst_done")
            wait=self.sign((warp_base+w)*32)
            await self.send("tmem_wait",wait)
            await self.result(wait,"tmem_wait_done")

    async def write_smem(self,addr,data,mask=0xffff,op_id=None):
        group=(addr>>4)&7
        tag=pack((58,self.sign(256) if op_id is None else op_id),(4,12),(16,group))
        self.d.smem_wr_payload[group].value=pack((78,tag),(32,addr),(16,mask),(128,data))
        self.d.smem_wr_valid.value=1<<group
        self.d.lsu_quiescent.value=0
        while not (await self.edge("smem_wr_ready"))&(1<<group): pass
        self.written_atoms[tag]=addr
        self.d.smem_wr_valid.value=0
        while tag not in self.acks: await self.edge()
        self.acks.remove(tag)
        self.d.lsu_quiescent.value=1

    async def read_smem(self,addr,mask):
        group=(addr>>4)&7
        tag=pack((58,self.sign(MMA_ISSUER)),(4,12),(16,group))
        self.d.lsu_quiescent.value=0
        self.d.smem_rd_rsp_ready.value=0
        self.d.smem_rd_payload[group].value=pack((78,tag),(32,addr),(16,mask))
        self.d.smem_rd_valid.value=1<<group
        while not (await self.edge("smem_rd_ready"))&(1<<group): pass
        self.d.smem_rd_valid.value=0
        while not (await self.edge("smem_rd_rsp_valid"))&(1<<group): pass
        response=int(self.d.smem_rd_rsp_payload[group].value)
        assert response>>132==tag and response&15==0
        self.d.smem_rd_rsp_ready.value=255
        await self.edge()
        self.d.lsu_quiescent.value=1
        return (response>>4)&MASK128

    async def write_smem_lines(self, lines):
        self.d.lsu_quiescent.value=0
        tags=[]
        for line in lines:
            valid=255
            for addr,data in line:
                g=(addr>>4)&7
                tag=pack((58,self.sign(256)),(4,12),(16,g))
                self.d.smem_wr_payload[g].value=pack((78,tag),(32,addr),(16,65535),(128,data))
                self.written_atoms[tag]=addr
                tags.append(tag)
            while valid:
                self.d.smem_wr_valid.value=valid
                valid &= ~await self.edge("smem_wr_ready")
        self.d.smem_wr_valid.value=0
        while self.written_atoms: await self.edge()
        assert all(tag in self.acks for tag in tags)
        self.acks.difference_update(tags)
        self.d.lsu_quiescent.value=1

    async def lifecycle_start(self,barriers):
        await self.edge(); await self.edge()
        self.d.rst_n.value=1
        await self.send("open_req",self.epoch)
        while "open_rsp" not in self.lifecycle: await self.edge()
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

    async def shutdown(self,barriers):
        for addr in barriers:
            await self.result(await self.barrier(addr,1),"bar_rsp")
        free=self.sign(MMA_ISSUER)
        await self.send("tmem_manage",pack((58,free),(2,1),(32,0),(10,512)))
        await self.result(free,"tmem_manage_rsp")
        await self.send("close_req")
        while "close_rsp" not in self.lifecycle: await self.edge()
        assert not self.written_atoms and not self.pending_memory and not self.pending_order


class WorkTile:
    def __init__(self,fe,first,batch,head,pattern):
        self.fe,self.c,self.first,self.batch,self.head,self.pattern=fe,fe.case,first,batch,head,pattern
        self.highest=(first+255)//128 if self.c.causal else 0
        self.loaded={}
        self.maximum=np.full((self.c.stages,128),-np.inf,dtype=np.float64)
        self.denominator=np.zeros_like(self.maximum)
        self.accum=np.zeros((self.c.stages,128,self.c.depth),dtype=np.float32)
        self.probabilities={}
        self.mma_issuer=MMA_ISSUER
        self.s_full=80 if self.c.causal else 208
        self.p_ready=96 if self.c.causal else 216
        self.lastsplit=112 if self.c.causal else 224
        self.o_full=144 if self.c.causal else 240
        self.o_shared=208 if self.c.causal else 272
        self.o_empty=224 if self.c.causal else 280
        self.q_empty=16 if self.c.causal else 8
        self.kv_empty=56 if self.c.causal else 112
        self.kv_full=32 if self.c.causal else 16
        self.tracked={}
        self.timing_errors=[]
        self.cold_op=None
        self.cold_a_grants=0
        self.incomplete_cold_fill=False
        self.core_dots=[tuple(fe.d._id(f"cores[{c}].core.{port}",extended=False)
                              for port in ("operand_valid","operand_ready","dot_command")) for c in range(4)]
        self.fe.observe=self.sample_dots

    def sample_dots(self):
        if not self.tracked:
            return
        for c,(valid,ready,command) in enumerate(self.core_dots):
            if int(valid.value) and int(ready.value):
                op=int(command.value)>>388
                assert op in self.tracked
                if c==0 and op==self.cold_op:
                    # A fresh QK requires 256 SMEM A atoms. Fewer total
                    # A-client accepts by the first dot proves that this cold
                    # launch precedes the warmed four-cycle service window.
                    self.incomplete_cold_fill=self.cold_a_grants<256
                    self.cold_op=None
                self.tracked[op][c].append(self.fe.cycle)
        if self.cold_op is not None:
            a=self.fe.read("tc_smem_req_valid") & self.fe.read("tc_smem_req_ready") & 0xffffffff
            self.cold_a_grants+=a.bit_count()

    def barriers(self):
        # The PTX prologue initializes every ring and producer/consumer barrier.
        end=self.o_empty+8*self.c.stages
        b=dict.fromkeys(range(0,end,8),1)
        for s in range(self.c.stages):
            b[self.p_ready+8*s]=256
            b[self.lastsplit+8*s]=4
            b[self.o_empty+8*s]=32
        correction_begin=160 if self.c.causal else 248
        for addr in range(correction_begin,self.o_empty,8):
            b[addr]=128
        return b

    def tile(self,name,row):
        return tile(self.c,name,row,128,self.head,self.batch,self.pattern)

    async def ensure_kv(self,name,t):
        slot=(2*(self.highest-t)+(name=="V"))%3
        if self.loaded.get(slot)!=(name,t):
            if slot in self.loaded:
                await self.fe.wait_barrier(self.kv_empty+8*slot,LOAD_ISSUER)
            await self.fe.copy(name,self.c.kv_smem(slot),128*t,self.batch,self.head,self.kv_full+8*slot)
            self.loaded[slot]=(name,t)
        return slot

    async def arrivals(self,addr,issuers):
        fe=self.fe
        # Each participating thread has already settled its own RF/wait
        # obligations. Submit independent releases as front-end slots free up.
        pending=[]
        for issuer in issuers:
            pending.append(await fe.barrier(addr,2,count=1,issuer=issuer))
        for op in pending:
            await fe.result(op,"bar_rsp")

    async def product(self,s,t,pv):
        fe,c=self.fe,self.c
        slot=await self.ensure_kv("V" if pv else "K",t)
        if pv:
            await fe.wait_barrier(self.p_ready+8*s,self.mma_issuer)
        fe.d._log.info("Q-stage=%d KV=%d starting %s at cycle %d",s,t,"PV" if pv else "QK",fe.cycle)
        ops=[]
        cmd_edges=[]
        self.cold_a_grants=0
        self.incomplete_cold_fill=False
        for step in range(8 if pv else c.depth//16):
            if pv and step==6:
                await fe.wait_barrier(self.lastsplit+8*s,self.mma_issuer)
            op=fe.sign(self.mma_issuer)
            cmd=mma_payload(c,op,pv,s,step,slot,step!=0 or (pv and t!=self.highest))
            self.tracked[op]=[[],[],[],[]]
            if not pv and step==0:
                self.cold_op=op
            await fe.send("mma_cmd",cmd)
            cmd_edges.append(fe.cycle-1)
            ops.append(op)
        # PTX publishes each S, publishes final O only at t=0, and releases
        # the shared KV ring slot after its last consumer on this CTA.
        ready_addr=(self.o_full if pv else self.s_full)+s*8
        targets=[ready_addr] if not pv or t==0 else []
        if s==c.stages-1:
            targets.append(self.kv_empty+8*slot)
        if not pv and t==0 and s==c.stages-1:
            targets.extend(self.q_empty+8*i for i in range(c.stages))
        commits=[]
        for addr in targets:
            commit=fe.sign(self.mma_issuer)
            await fe.send("tc_commit",pack((58,commit),(32,addr)))
            commits.append(commit)
        # Defer consumer warp scheduling until the stream has finished. Its
        # barrier backing miss can otherwise steal a timed SMEM operand grant.
        for commit in commits: await fe.result(commit,"tc_commit_done")
        for op in ops: await fe.result(op,"tc_op_done")
        if ready_addr in targets:
            await fe.wait_barrier(ready_addr,CORRECTION_FIRST if pv else 128*s)
        q=c.depth//2 if pv else 64
        first=[self.tracked[op][0][0] for op in ops]
        for step,op in enumerate(ops):
            for times in self.tracked.pop(op):
                assert len(times)==q and times[0]==first[step], (op,len(times),times[:1])
            if step:
                deadline=first[step-1]+q
                # Only PV step 6 has an intervening software wait. Its first B
                # half needs to enter R_BREQ by F-7 under the published trace.
                late_wait=pv and step==6 and cmd_edges[step]>deadline-7
                cold=step==1 and not pv and self.incomplete_cold_fill
                if cold:
                    fe.d._log.info("Cold QK first-dot interval %d; %d/256 A atoms accepted before first dot",
                                   first[1]-first[0],self.cold_a_grants)
                if not (late_wait or cold) and first[step]!=deadline:
                    discrepancy=(op,step,first[step],deadline,cmd_edges[step])
                    fe.d._log.error("K16 first-dot timing (id, step, actual, expected, cmd.fire) %s",discrepancy)
                    self.timing_errors.append(discrepancy)
        fe.d._log.info("%s stage=%d KV=%d first dots=%s", "PV" if pv else "QK",s,t,first)
        if pv:
            old=self.accum[s].copy()
            values=self.tile("V",128*t).astype(np.float32)
            wanted=old + self.probabilities.pop((s,t)).astype(np.float32) @ values
            actual=(await fe.get_rf(256+128*s,c.depth,warp_base=8)).view("<f4")
            np.testing.assert_allclose(actual,wanted,atol=0.0005,rtol=0.00005)
            self.accum[s]=actual
        else:
            await self.softmax(s,t)

    async def softmax(self,s,t):
        fe,c=self.fe,self.c
        row=self.first+128*s
        data=(await fe.get_rf(128*s,128,warp_base=4*s)).view("<f4")
        expected=self.tile("Q",row).astype(np.float32) @ self.tile("K",128*t).astype(np.float32).T
        np.testing.assert_array_equal(data,expected)
        logits=data.astype(np.float64)/np.sqrt(c.depth)
        if c.causal:
            logits[np.arange(128)[None,:]+128*t > row+np.arange(128)[:,None]]=-np.inf
        max_old=self.maximum[s].copy()
        max_new=np.maximum(max_old,np.max(logits,axis=1))
        safe_max=np.where(np.isfinite(max_new),max_new,0)
        correction=np.exp(max_old-safe_max)
        weights=np.exp(logits-safe_max[:,None])
        self.maximum[s]=max_new
        self.denominator[s]=self.denominator[s]*correction+weights.sum(axis=1)
        p=weights.astype("<f2")
        self.probabilities[s,t]=p
        packed=p.view("<u4")
        await fe.put_rf(64+128*s,packed[:,:48],warp_base=4*s)
        await self.arrivals(self.p_ready+8*s,range(s*128,s*128+128))
        if t!=self.highest and np.any(correction!=1):
            old=(await fe.get_rf(256+128*s,c.depth,warp_base=8)).view("<f4")
            corrected=(old*correction[:,None]).astype("<f4")
            await fe.put_rf(256+128*s,corrected.view("<u4"),warp_base=8)
            self.accum[s]=corrected
        await self.arrivals(self.p_ready+8*s,range(CORRECTION_FIRST,CORRECTION_FIRST+128))
        await fe.put_rf(64+128*s+48,packed[:,48:],warp_base=4*s)
        await self.arrivals(self.lastsplit+8*s,range(s*128,s*128+128,32))

    async def emit(self,s):
        c,fe=self.c,self.fe
        row=self.first+128*s
        out=(self.accum[s]/self.denominator[s,:,None]).astype("<f2")
        lines=[]
        for r in range(128):
            for panel in range(c.depth//64):
                line=[]
                for i in range(8):
                    x=c.o_smem(s)+panel*16384+r*128+i*16
                    addr=x^(((x>>7)&7)<<4)
                    words=out[r,panel*64+i*8:panel*64+i*8+8].tobytes()
                    line.append((addr,int.from_bytes(words,"little")))
                lines.append(line)
        await fe.write_smem_lines(lines)
        await fe.result(await fe.tma(None,5,0,(),issuer=CORRECTION_FIRST),"tma_rsp")
        await self.arrivals(self.o_shared+8*s,range(CORRECTION_FIRST,CORRECTION_FIRST+128))
        await fe.wait_barrier(self.o_shared+8*s,STORE_ISSUER)
        stores=[]
        for panel in range(c.depth//64):
            stores.append(await fe.tma("O",1,c.o_smem(s)+panel*16384,(64*panel,row,self.head,self.batch),issuer=STORE_ISSUER))
        await fe.result(await fe.tma(None,3,0,(),issuer=STORE_ISSUER),"tma_rsp")
        return stores,out

    async def check_output(self,s,stores,out):
        c,fe=self.c,self.fe
        row=self.first+128*s
        await fe.result(await fe.tma(None,4,0,(),issuer=STORE_ISSUER,wait_n=c.stages-s-1),"tma_rsp")
        await self.arrivals(self.o_empty+8*s,range(STORE_ISSUER,STORE_ISSUER+32))
        for op in stores:
            assert (await fe.result(op,"tma_rsp"))&((1<<64)-1)==16384
        output=fe.mem.output_tile(self.batch,self.head,row)
        np.testing.assert_array_equal(output,out)
        q=self.tile("Q",row)
        k=tile(c,"K",0,128*(self.highest+1),self.head,self.batch,self.pattern)
        v=tile(c,"V",0,128*(self.highest+1),self.head,self.batch,self.pattern)
        direct=direct_attention(c,q,k,v,row)
        if self.pattern=="uniform":
            np.testing.assert_array_equal(output,np.ones_like(output))
        else:
            # The external softmax rounds P and the final O to FP16.
            np.testing.assert_allclose(output,direct,atol=0.001,rtol=0.002)

    async def run(self):
        c,fe=self.c,self.fe
        for s in range(c.stages):
            await fe.copy("Q",c.q_smem(s),self.first+128*s,self.batch,self.head,8*s)
            await self.product(s,self.highest,False)
        for t in range(self.highest,-1,-1):
            for s in range(c.stages):
                await self.product(s,t,True)
                if t: await self.product(s,t-1,False)
        relinquish=fe.sign(self.mma_issuer)
        await fe.send("tmem_manage",pack((58,relinquish),(2,2),(32,0),(10,0)))
        await fe.result(relinquish,"tmem_manage_rsp")
        assert not fe.read("tmem_alloc_credit")
        groups=[await self.emit(s) for s in range(c.stages)]
        for s,(stores,out) in enumerate(groups): await self.check_output(s,stores,out)
        assert len(fe.mem.output)==c.stages*128*c.depth*2


def coordinates(name, extent):
    value=os.getenv(name,str(extent-1))
    if value=="all":
        return range(extent)
    indices=[int(x) for x in value.split(",")]
    assert all(0<=i<extent for i in indices)
    return indices


@cocotb.test()
async def replay_fa4(dut):
    """Replay every distinct CTA row schedule, with selectable host head and batch."""
    for target in os.getenv("FA4_CASE","F1,F2").split(","):
        case=CASES[target]
        rows=[int(os.environ["FA4_ROW"])] if "FA4_ROW" in os.environ else range(0,case.sequence,128*case.stages)
        for first in rows:
            assert first%(128*case.stages)==0 and 0<=first<case.sequence
            for pattern in os.getenv("FA4_PATTERN","uniform,coordinate").split(","):
                assert pattern in ("uniform","coordinate")
                for head in coordinates("FA4_HEAD",case.heads):
                    for batch in coordinates("FA4_BATCH",case.batches):
                        fe=FrontEnd(dut,case,pattern)
                        work=WorkTile(fe,first,batch,head,pattern)
                        await fe.lifecycle_start(work.barriers())
                        await work.run()
                        await fe.shutdown(work.barriers())
                        assert not fe.results and not fe.rf
                        dut._log.info("%s %s checked GMEM O batch=%d head=%d row=%d total CTA cycles=%d",
                                      target,pattern,batch,head,first,fe.cycle)
                        assert not work.timing_errors, ("first-dot cycle mismatches",work.timing_errors)
