"""Cocotb replay of single-CTA FA4 commands on blackwell_async_subsystem_top."""
import os

import cocotb
import numpy as np

from fa4_model import CASES, direct_attention, mma_payload, pack, tile
from frontend import FrontEnd, LOAD_ISSUER, MMA_ISSUER

CORRECTION_FIRST = 8*32
STORE_ISSUER = 13*32


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
