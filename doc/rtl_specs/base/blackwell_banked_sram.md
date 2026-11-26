# blackwell_banked_sram

## Description

This module implements a synchronous SRAM parameterized by `BANKS, DEPTH, WORD_W=128`. Each bank has one independent read port and one byte-masked write port. The SMEM fabric, TMEM partition, and TMA data path configure bank count, depth, and width. Each parent accounts for its own macro storage and read outputs.

| Signal / channel | Direction | Type / width | Peer | Sampling condition |
|---|---|---|---|---|
| `read_enable` | Input | BANKS bits | Parent memory controller | The enabled bank samples its address on the read edge. |
| `read_addr` | Input | BANKS×ceil(log2 DEPTH) bits | Parent memory controller | Sample when read_enable is 1 for the bank. |
| `read_q` | Output | BANKS×WORD_W bits | Parent memory controller | Update after the read sampling edge, otherwise hold. |
| `write_enable` | Input | BANKS bits | Parent memory controller | Commit selected bytes on the write-enable edge. |
| `write_addr` | Input | BANKS×ceil(log2 DEPTH) bits | Parent memory controller | Sample when write enable is asserted for the bank. |
| `write_data` | Input | BANKS×WORD_W bits | Parent memory controller | Sample when write enable is asserted for the bank. |
| `write_byte_mask` | Input | BANKS×WORD_W/8 bits | Parent memory controller | Sample the mask on the write-enable edge. Bit b selects data byte b. |
| `clk` | Input | 1 bit | Parent memory controller | Sample enables for each bank on the rising edge. |

## Functionality

### Read sampling and byte writes

The macro samples the address on an edge with read_enable asserted and updates SRAM_Q after the edge. Disabled banks hold Q. The parent must ensure the old Q can move before enabling a new sample. [SMEM](../smem/blackwell_smem_fabric.md) samples directly at grant edge g. [TMEM partition](../tmem/blackwell_tmem_partition.md) registers read control at g and samples at g+1.

TMA RD is a stallable address register. An address can be preselected. Enable the macro only on an actual sampling edge with room in Q. Sampling a read and handing the old Q to R_OUT can occur on the same edge.

Sample write_enable at the write edge and immediately commit the selected bytes. The parent compares addresses for the actual macro access edge and resolves same-bank, same-word conflicts before asserting enables. Different words permit simultaneous 1R+1W.

If the macro cannot hold Q, an adapter must supply an equivalent enable register of the same width. Count it as Q. If both copies are retained, count both. Data RAM and Q require no array-wide reset. Clearing the parent's valid bits makes undefined payload unobservable.

### Port conflicts and boundary checks

Check independent bank enables, Q retention during stalls, preservation of adjacent bytes under masking, addresses DEPTH−1 and DEPTH, concurrent different-word reads and writes, and controller suppression of same-word conflicts. The fabric or partition owns transaction identity, ready, return credits, and ACKs. This module supplies physical storage.
