"""Top-level MMA panel stimulus and edge monitors."""
from frontend import FrontEnd


def descriptor(start):
    return (1 << 46) | (16 << 32) | (8 << 16) | (start >> 4)


class Accumulation(FrontEnd):
    def __init__(self, dut):
        super().__init__(dut)
        self.observe = self.capture
        self.active = False
        self.first_dots = []
        self.events = {}
        self.first_for_id = {}

    def capture(self):
        if not self.active:
            return
        d = self.d
        def core(name):
            return d._id("engine.cores[0].core."+name, extended=False)
        if int(core("operand_valid").value) and int(core("operand_ready").value):
            op = int(core("dot_command").value) >> 388
            if op not in self.first_for_id:
                self.first_for_id[op] = self.cycle
                self.first_dots.append(self.cycle)
        writes = int(core("tm_wr_req_valid").value) & int(core("tm_wr_req_ready").value)
        writing = d._id("tmem.fabric.part[0].partition.writing", extended=False)
        if int(writing.value) & 1:
            self.events[self.last_write_id]["actual_write"] = self.cycle
        if writes & 1:
            self.last_write_id = int(core("tm_wr_req_payload")[0].value) >> 178
            self.events.setdefault(self.last_write_id, {})["write"] = self.cycle
        if int(core("tm_wr_ack_valid").value) & int(core("tm_wr_ack_ready").value) & 1:
            op = int(core("tm_wr_ack_payload")[0].value) >> 24
            self.events.setdefault(op, {})["ack"] = self.cycle
        if self.read("engine_done_valid") and self.read("engine_done_ready"):
            op = self.read("engine_done_payload") >> 4
            self.events.setdefault(op, {})["tracker"] = self.cycle

    async def write_panel(self, start, values):
        # Each 128-byte half contains one 16-byte atom in every physical group.
        lines = []
        for group in range(16):
            for half in range(2):
                line = []
                for lane in range(8):
                    address = start + 256*group + 128*half + 16*lane
                    atom = values[8*group+lane, 8*half:8*half+8].astype("<f2")
                    line.append((address, int.from_bytes(atom.tobytes(), "little")))
                lines.append(line)
        await self.write_smem_lines(lines)
