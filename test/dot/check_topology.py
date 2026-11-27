"""Check physical reduction-tree instances in a Verilator elaboration."""
from collections import Counter
import sys
from xml.etree import ElementTree

cells = ElementTree.parse(sys.argv[1]).find("cells")
shared = int(sys.argv[2])
topologies = Counter()
for lane in cells.iter("cell"):
    if lane.get("submodname", "").startswith("blackwell_fp_dot_lane"):
        children = Counter(child.get("name") for child in lane.iter("cell"))
        topologies[children["add_pair"], children["add_group"],
                   children["finish_sum"]] += 1

expected = {(16, 4, 2): 64} if shared else {(8, 2, 1): 64, (16, 4, 1): 64}
if topologies != expected:
    raise SystemExit(f"Unexpected floating-point lane topologies: {topologies}")
print(f"PASS elaborated (pair, group, tail) trees per lane: {dict(topologies)}")
