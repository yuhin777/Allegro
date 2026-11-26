"""Clock, memory, handshakes and transaction tracking for the subsystem workload tests."""
from collections import defaultdict, deque

from cocotb.triggers import Timer
import numpy as np

from workload_protocol import MASK128, pack


class FrontEnd:
    """Advance one common clock and settle real RF, memory and ordering obligations."""
    wait_cycles = 200_000
    returns = {"tc_op_done":4,"tc_commit_done":4,"tmem_ldst_done":4,"tmem_wait_done":4,
               "bar_rsp":5,"tma_rsp":68,"tmem_manage_rsp":36}
    def __init__(self, dut, memory=None):
        self.d = dut
        self.mem = memory
        self.pending_memory, self.pending_order = deque(),deque()
        self.results, self.rf = {},defaultdict(list)
        self.observe = lambda: None
        self.seq, self.phase = defaultdict(int),defaultdict(int)
        self.cycle, self.epoch = 0,1
        self.written_atoms, self.acks = {},set()
        self.lifecycle = set()
        self.acquired = {}
        self.order_kind, self.wait_address = {}, {}
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

    def sample_transfers(self):
        """Sample workload-specific transfers before checking ordering requests."""

    def check_acquire(self, addr):
        """Check any workload-specific prerequisites at the acquire handshake."""

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
            self.sample_transfers()
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
                operation = "write" if opcode else "read"
                service = getattr(self.mem, operation, None)
                if service is None:
                    raise AssertionError(f"Missing GMEM {operation} service at {addr:#x}, cycle {self.cycle}")
                if opcode:
                    service(addr,data.to_bytes(128,"little"),mask)
                    reply=0
                else:
                    reply=int.from_bytes(service(addr),"little")
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
                    self.check_acquire(self.wait_address[op])
                self.pending_order.append(op<<4)
        self.observe()
        d.clk.value=1
        await Timer(1,units="ns")
        d.clk.value=0
        self.cycle+=1
        assert self.cycle < 30_000_000, f"Global workload timeout at cycle {self.cycle} in epoch {self.epoch}"
        return ready

    async def wait_until(self, condition, description):
        deadline = self.cycle + self.wait_cycles
        while not condition():
            if self.cycle >= deadline:
                raise AssertionError(f"Timed out at cycle {self.cycle} waiting for {description}")
            await self.edge()

    async def wait_edge(self, signal, mask=1, *, transaction):
        for _ in range(self.wait_cycles):
            if await self.edge(signal) & mask:
                return
        raise AssertionError(f"{signal} mask {mask:#x} blocked at cycle {self.cycle} for {transaction}")

    async def transfer_groups(self, channel, mask, address):
        valid = getattr(self.d, channel + "_valid")
        deadline = self.cycle + self.wait_cycles
        while mask:
            if self.cycle >= deadline:
                raise AssertionError(
                    f"{channel} at {address:#x} blocked for group mask {mask:#x} at cycle {self.cycle}"
                )
            valid.value = mask
            mask &= ~await self.edge(channel + "_ready")
        valid.value = 0

    async def send(self,channel,value=None):
        getattr(self.d,channel+"_valid").value=1
        if value is not None: getattr(self.d,channel+"_payload").value=value
        await self.wait_edge(channel + "_ready", transaction=value)
        getattr(self.d,channel+"_valid").value=0

    async def result(self,op,channel):
        await self.wait_until(lambda: op in self.results, f"{channel} for operation {op}")
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
        deadline = self.cycle + self.wait_cycles
        while self.cycle < deadline:
            op=await self.barrier(addr,4,issuer=issuer)
            rsp=await self.result(op,"bar_rsp")
            del self.wait_address[op]
            if rsp&1:
                assert op in self.acquired and self.acquired[op]<self.cycle
                self.phase[addr]^=1
                return
        raise AssertionError(f"Barrier {addr:#x} phase {self.phase[addr]} still pending at cycle {self.cycle}")

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
        await self.wait_edge("smem_wr_ready", 1 << group, transaction=tag)
        self.written_atoms[tag]=addr
        self.d.smem_wr_valid.value=0
        await self.wait_until(lambda: tag in self.acks, f"SMEM write ACK for tag {tag} at {addr:#x}")
        self.acks.remove(tag)
        self.d.lsu_quiescent.value=1

    async def read_smem(self,addr,mask,issuer=384):
        group=(addr>>4)&7
        tag=pack((58,self.sign(issuer)),(4,12),(16,group))
        self.d.lsu_quiescent.value=0
        self.d.smem_rd_rsp_ready.value=0
        self.d.smem_rd_payload[group].value=pack((78,tag),(32,addr),(16,mask))
        self.d.smem_rd_valid.value=1<<group
        await self.wait_edge("smem_rd_ready", 1 << group, transaction=tag)
        self.d.smem_rd_valid.value=0
        await self.wait_edge("smem_rd_rsp_valid", 1 << group, transaction=tag)
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
            for addr,data in line:
                g=(addr>>4)&7
                tag=pack((58,self.sign(256)),(4,12),(16,g))
                self.d.smem_wr_payload[g].value=pack((78,tag),(32,addr),(16,65535),(128,data))
                self.written_atoms[tag]=addr
                tags.append(tag)
            await self.transfer_groups("smem_wr", 255, line[0][0])
        await self.wait_until(lambda: not self.written_atoms, "outstanding SMEM write acknowledgments")
        assert all(tag in self.acks for tag in tags)
        self.acks.difference_update(tags)
        self.d.lsu_quiescent.value=1

    async def open(self, *, release_reset=True):
        if release_reset:
            await self.edge()
            await self.edge()
            self.d.rst_n.value = 1
        await self.send("open_req", self.epoch)
        await self.wait_until(lambda: "open_rsp" in self.lifecycle, f"open response for epoch {self.epoch}")
        self.lifecycle.remove("open_rsp")

    async def shutdown(self,barriers,issuer=384):
        for addr in barriers:
            await self.result(await self.barrier(addr,1),"bar_rsp")
        free=self.sign(issuer)
        await self.send("tmem_manage",pack((58,free),(2,1),(32,0),(10,512)))
        await self.result(free,"tmem_manage_rsp")
        await self.send("close_req")
        await self.wait_until(lambda: "close_rsp" in self.lifecycle, f"close response for epoch {self.epoch}")
        assert not self.written_atoms and not self.pending_memory and not self.pending_order
