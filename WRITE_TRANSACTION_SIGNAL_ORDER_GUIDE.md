# MC16X2 Write Transaction Signal Plotting & Waveform Analysis Guide

## 1. Executive Summary & Architecture Overview

The `mc16x2` is a high-bandwidth DRAM Memory Controller supporting **16 independent channels** with **2 Pseudo-Channels (PC0 and PC1) per channel** (32 total PC cores), interfacing to an **AXI4 subordinate bus** on the host side and **DFI 5.0 (DDR PHY Interface)** on the PHY/DRAM side.

### Key Operational Characteristics:
- **AXI Clock Domain (`aclk`)**: Typically 500 MHz (2.0 ns period).
- **DFI / Controller Clock Domain (`dfi_clk`)**: Typically 1000 MHz (1.0 ns period).
- **AXI Data Bus Width**: 256 bits (`s_axi_wdata[255:0]`), with 32-bit byte strobes (`s_axi_wstrb[31:0]`).
- **DFI Data Bus Width**: 64 bits per channel (`dfi_wrdata[ch][63:0]`), where PC0 drives bits `[31:0]` and PC1 drives bits `[63:32]`.
- **Word Slicing**: Each 256-bit AXI write transaction contains eight 32-bit words (lanes 0 to 7). Address bits `AWADDR[4:2]` select which 32-bit lane is routed to the target channel and pseudo-channel.
- **Synchronous DFI Capture**: The DFI Formatter captures the column command (`dfi_col`), write data (`dfi_wrdata`), write mask (`dfi_wrdata_mask`), and write enable (`dfi_wrdata_en`) on the **exact same clock edge**.

---

## 2. Recommended Signal Order for Waveform Analysis (GTKWave / Verdi / DVE)

To understand the write transaction in chronological and microarchitectural order, arrange your waveform signals into the following **11 distinct hierarchical groups**:

```
+----------------------------------------------------------------------------------------------------+
|                                    WAVEFORM SIGNAL GROUP ORDER                                     |
+----+----------------------------------------------+------------------------------------------------+
| Grp| Group Name                                   | Microarchitectural Stage                       |
+----+----------------------------------------------+------------------------------------------------+
| 01 | Clocks & Resets                              | Global Clocking & Reset Control                |
| 02 | AXI4 Write Address Channel (AW)              | Host Write Request Handshake                   |
| 03 | AXI4 Write Data Channel (W)                  | Host 256-bit Payload & Byte Strobes            |
| 04 | CDC Clock Domain Crossing (Async FIFOs)      | aclk -> dfi_clk Domain Transfer                |
| 05 | Address Decoder & 256-bit Lane Slicer        | Target Decoding & 32-bit Slice Extraction      |
| 06 | Target PC Core Queues (CMDQ & WDB)           | Command Scheduling & Payload Buffering         |
| 07 | Bank State Engine & Timing (ACT -> WR)       | Bank Activation & tRCD Delay Enforcement       |
| 08 | Channel Arbiter (PC0 vs PC1 Arbitration)     | Channel Multiplexing for Row and Col Buses     |
| 09 | DFI 5.0 Formatter Outputs (PHY Interface)    | DFI Row, Col, Write Data, Mask & Enables       |
| 10 | Write Completion Feedback & AXI B Channel    | wr_done Pulse -> BVALID Handshake              |
| 11 | Error & Status Flags                         | Queue Overflows & Refresh Deadline Misses      |
+----+----------------------------------------------+------------------------------------------------+
```

---

### Detailed Signal Specification Table

#### GROUP 1: Clocks & Resets
| # | Signal Path | Radix | Description |
|---|---|---|---|
| 1.1 | `tb_mc16x2_write_verify.aclk` | Bin | 500 MHz AXI domain clock |
| 1.2 | `tb_mc16x2_write_verify.aresetn` | Bin | AXI active-low synchronous reset |
| 1.3 | `tb_mc16x2_write_verify.dfi_clk` | Bin | 1000 MHz Controller/DFI domain clock |
| 1.4 | `tb_mc16x2_write_verify.ctl_reset_n` | Bin | Controller active-low synchronous reset |

#### GROUP 2: AXI4 Write Address Channel (AW)
| # | Signal Path | Radix | Description |
|---|---|---|---|
| 2.1 | `tb_mc16x2_write_verify.s_axi_awvalid` | Bin | Master write address valid |
| 2.2 | `tb_mc16x2_write_verify.s_axi_awready` | Bin | Slave write address ready |
| 2.3 | `tb_mc16x2_write_verify.s_axi_awid[7:0]` | Hex | Write transaction ID |
| 2.4 | `tb_mc16x2_write_verify.s_axi_awaddr[39:0]` | Hex | 40-bit AXI write address |
| 2.5 | `tb_mc16x2_write_verify.s_axi_awlen[7:0]` | Dec | Burst length (`0` = 1 beat) |
| 2.6 | `tb_mc16x2_write_verify.s_axi_awsize[2:0]` | Dec | Burst size (`3'b101` = 32 bytes / 256 bits) |
| 2.7 | `tb_mc16x2_write_verify.s_axi_awburst[1:0]` | Bin | Burst type (`2'b01` = INCR) |

#### GROUP 3: AXI4 Write Data Channel (W)
| # | Signal Path | Radix | Description |
|---|---|---|---|
| 3.1 | `tb_mc16x2_write_verify.s_axi_wvalid` | Bin | Master write data valid |
| 3.2 | `tb_mc16x2_write_verify.s_axi_wready` | Bin | Slave write data ready |
| 3.3 | `tb_mc16x2_write_verify.s_axi_wdata[255:0]` | Hex | **Full 256-bit write data vector** |
| 3.4 | `tb_mc16x2_write_verify.s_axi_wstrb[31:0]` | Hex | **32-bit byte write strobes** |
| 3.5 | `tb_mc16x2_write_verify.s_axi_wlast` | Bin | Last data beat flag (`1` for single beat) |

#### GROUP 4: CDC Clock Domain Crossing (Async FIFOs)
| # | Signal Path | Radix | Description |
|---|---|---|---|
| 4.1 | `dut.u_axi_cdc.m_awvalid` | Bin | AW FIFO valid in `dfi_clk` domain |
| 4.2 | `dut.u_axi_cdc.m_awready` | Bin | AW FIFO ready from address decoder |
| 4.3 | `dut.u_axi_cdc.m_awaddr[39:0]` | Hex | Synchronized 40-bit address in `dfi_clk` |
| 4.4 | `dut.u_axi_cdc.m_awid[7:0]` | Hex | Synchronized transaction ID |
| 4.5 | `dut.u_axi_cdc.m_wvalid` | Bin | W FIFO valid in `dfi_clk` domain |
| 4.6 | `dut.u_axi_cdc.m_wready` | Bin | W FIFO ready from address decoder |
| 4.7 | `dut.u_axi_cdc.m_wdata[255:0]` | Hex | Synchronized 256-bit write data |
| 4.8 | `dut.u_axi_cdc.m_wstrb[31:0]` | Hex | Synchronized 32-bit write strobes |

#### GROUP 5: Address Decoder & 256-bit Lane Slicer (`u_addr_decode`)
| # | Signal Path | Radix | Description |
|---|---|---|---|
| 5.1 | `dut.u_addr_decode.state[2:0]` | Enum | FSM: IDLE(0), W_DATA(1), W_ISSUE(2), W_WAIT(3), B_RESP(4) |
| 5.2 | `dut.u_addr_decode.channel[3:0]` | Dec | Decoded Channel index (`AWADDR[32:29]`, 0..15) |
| 5.3 | `dut.u_addr_decode.pc` | Dec | Decoded Pseudo-Channel (`AWADDR[28]`, 0..1) |
| 5.4 | `dut.u_addr_decode.target[4:0]` | Dec | Target PC Core ID (`{channel, pc}`, 0..31) |
| 5.5 | `dut.u_addr_decode.row[13:0]` | Hex | Decoded DRAM Row address (`AWADDR[27:14]`) |
| 5.6 | `dut.u_addr_decode.bg[1:0]` | Dec | Decoded Bank Group (`AWADDR[13:12]`, 0..3) |
| 5.7 | `dut.u_addr_decode.bank[1:0]` | Dec | Decoded Bank Address (`AWADDR[11:10]`, 0..3) |
| 5.8 | `dut.u_addr_decode.col[4:0]` | Hex | Decoded Column address (`AWADDR[9:5]`, 0..31) |
| 5.9 | `dut.u_addr_decode.lane[2:0]` | Dec | Decoded Lane select (`AWADDR[4:2]`, 0..7) |
| 5.10 | `dut.u_addr_decode.write_word[31:0]` | Hex | **Extracted 32-bit slice** from `wdata[lane*32 +: 32]` |
| 5.11 | `dut.u_addr_decode.write_strobes[3:0]` | Hex | **Extracted 4-bit strobe** from `wstrb[lane*4 +: 4]` |
| 5.12 | `dut.u_addr_decode.write_dispatch` | Bin | Qualifier: queue ready & strobe active |
| 5.13 | `dut.cmd_push_val[target]` | Bin | Push pulse to target PC Core CMDQ |
| 5.14 | `dut.cmd_push_entry[target][35:0]` | Hex | Packed command `{axi_id, 1'b1, row, bg, bank, col, wdb_ptr}` |
| 5.15 | `dut.wdb_push_val[target]` | Bin | Push pulse to target PC Core WDB |
| 5.16 | `dut.wdb_push_data[target][31:0]` | Hex | 32-bit payload pushed into WDB buffer |
| 5.17 | `dut.wdb_push_mask[target][3:0]` | Hex | Inverted active-high byte mask (`~write_strobes`) |

#### GROUP 6: Target PC Core Queues & Buffer (`g_channel[ch].g_pc[pc].u_pc_core`)
*(Substitute `ch` and `pc` with target channel and pseudo-channel, e.g. `ch=0, pc=0`)*
| # | Signal Path | Radix | Description |
|---|---|---|---|
| 6.1 | `dut.g_channel[ch].g_pc[pc].u_pc_core.cmd_push_val` | Bin | Enqueue command entry into CMDQ |
| 6.2 | `dut.g_channel[ch].g_pc[pc].u_pc_core.cmdq_full` | Bin | CMDQ full backpressure flag |
| 6.3 | `dut.g_channel[ch].g_pc[pc].u_pc_core.wdb_push_val` | Bin | Enqueue write payload into WDB |
| 6.4 | `dut.g_channel[ch].g_pc[pc].u_pc_core.wdb_alloc_ptr[3:0]` | Dec | Assigned buffer index in WDB (0..15) |
| 6.5 | `dut.g_channel[ch].g_pc[pc].u_pc_core.wdb_full` | Bin | WDB full backpressure flag |
| 6.6 | `dut.g_channel[ch].g_pc[pc].u_pc_core.wdb_rdata[31:0]` | Hex | 32-bit data read out from WDB on write issue |
| 6.7 | `dut.g_channel[ch].g_pc[pc].u_pc_core.wdb_rmask[3:0]` | Hex | 4-bit mask read out from WDB on write issue |

#### GROUP 7: DRAM Bank State Engine & Timing (`mc_timing_check`, `mc_bank_state`)
| # | Signal Path | Radix | Description |
|---|---|---|---|
| 7.1 | `dut.g_channel[ch].g_pc[pc].u_pc_core.u_bank_state.bank_state[bank_idx]` | Enum | Bank state: IDLE(00) -> ACTIVE(01) |
| 7.2 | `dut.g_channel[ch].g_pc[pc].u_pc_core.row_req_val` | Bin | Candidate row command ready for arbitration |
| 7.3 | `dut.g_channel[ch].g_pc[pc].u_pc_core.row_req_cmd[2:0]` | Bin | Row command: `3'b001` = ACTIVATE |
| 7.4 | `dut.g_channel[ch].g_pc[pc].u_pc_core.ch_arb_row_grant` | Bin | Channel arbiter row grant pulse |
| 7.5 | `dut.g_channel[ch].g_pc[pc].u_pc_core.u_timing_check.cnt_rcd[bank_idx][7:0]` | Dec | **tRCD countdown timer** (loaded to 17, counts down to 0) |
| 7.6 | `dut.g_channel[ch].g_pc[pc].u_pc_core.u_timing_check.legal_wr[bank_idx]` | Bin | Write column command legality flag (`cnt_rcd == 0`) |
| 7.7 | `dut.g_channel[ch].g_pc[pc].u_pc_core.col_req_val` | Bin | Candidate column command ready for arbitration |
| 7.8 | `dut.g_channel[ch].g_pc[pc].u_pc_core.col_req_cmd[1:0]` | Bin | Column command: `2'b10` = WRITE |
| 7.9 | `dut.g_channel[ch].g_pc[pc].u_pc_core.ch_arb_col_grant` | Bin | Channel arbiter column grant pulse |

#### GROUP 8: Channel Arbiter & Formatter Inputs (`u_ch_arb`)
| # | Signal Path | Radix | Description |
|---|---|---|---|
| 8.1 | `dut.g_channel[ch].u_ch_arb.row_valid` | Bin | Channel row valid to formatter |
| 8.2 | `dut.g_channel[ch].u_ch_arb.row_pc_sel` | Dec | PC grant select for row command (0=PC0, 1=PC1) |
| 8.3 | `dut.g_channel[ch].u_ch_arb.row_cmd_out[21:0]` | Hex | Selected packed row command |
| 8.4 | `dut.g_channel[ch].u_ch_arb.col_valid` | Bin | Channel col valid to formatter |
| 8.5 | `dut.g_channel[ch].u_ch_arb.col_pc_sel` | Dec | PC grant select for col command (0=PC0, 1=PC1) |
| 8.6 | `dut.g_channel[ch].u_ch_arb.col_cmd_out[11:0]` | Hex | Selected packed col command |
| 8.7 | `dut.g_channel[ch].lane_data[63:0]` | Hex | Formatter write data input (PC0:[31:0], PC1:[63:32]) |
| 8.8 | `dut.g_channel[ch].lane_mask[7:0]` | Hex | Formatter write mask input (PC0:[3:0], PC1:[7:4]) |
| 8.9 | `dut.g_channel[ch].write_enable[1:0]` | Bin | Per-PC write enable strobe |

#### GROUP 9: DFI 5.0 Formatter Outputs (Top-Level Ports)
| # | Signal Path | Radix | Description |
|---|---|---|---|
| 9.1 | `tb_mc16x2_write_verify.dfi_row_val[ch]` | Bin | **DFI Row Command Valid** |
| 9.2 | `tb_mc16x2_write_verify.dfi_row[ch][21:0]` | Hex | **DFI Row Bus**: `{pc_sel, cmd[2:0], bg[1:0], ba[1:0], row[13:0]}` |
| 9.3 | `tb_mc16x2_write_verify.dfi_col_val[ch]` | Bin | **DFI Column Command Valid** |
| 9.4 | `tb_mc16x2_write_verify.dfi_col[ch][11:0]` | Hex | **DFI Column Bus**: `{pc_sel, cmd[1:0], bg[1:0], ba[1:0], col[4:0]}` |
| 9.5 | `tb_mc16x2_write_verify.dfi_wrdata[ch][63:0]` | Hex | **DFI Write Data Bus** (`[31:0]` for PC0, `[63:32]` for PC1) |
| 9.6 | `tb_mc16x2_write_verify.dfi_wrdata_mask[ch][7:0]` | Hex | **DFI Write Mask Bus** (`[3:0]` for PC0, `[7:4]` for PC1) |
| 9.7 | `tb_mc16x2_write_verify.dfi_wrdata_en[ch][1:0]` | Bin | **DFI Write Data Enable** (`[0]` for PC0, `[1]` for PC1) |

#### GROUP 10: Write Completion & AXI Response (B Channel)
| # | Signal Path | Radix | Description |
|---|---|---|---|
| 10.1 | `dut.wr_done[target]` | Bin | Write completion feedback (`dfi_wrdata_en[ch][pc]`) |
| 10.2 | `dut.u_addr_decode.state[2:0]` | Enum | Decoder state transitions `W_WAIT` -> `B_RESP` |
| 10.3 | `tb_mc16x2_write_verify.s_axi_bvalid` | Bin | Slave write response valid |
| 10.4 | `tb_mc16x2_write_verify.s_axi_bready` | Bin | Master write response ready |
| 10.5 | `tb_mc16x2_write_verify.s_axi_bid[7:0]` | Hex | Response ID (must match `s_axi_awid`) |
| 10.6 | `tb_mc16x2_write_verify.s_axi_bresp[1:0]` | Bin | Write response status (`2'b00` = OKAY) |

#### GROUP 11: Error & Status Flags
| # | Signal Path | Radix | Description |
|---|---|---|---|
| 11.1 | `tb_mc16x2_write_verify.err_cmdq_overflow[31:0]` | Hex | CMDQ overflow error flags (must remain 0) |
| 11.2 | `tb_mc16x2_write_verify.err_wdb_overflow[31:0]` | Hex | WDB overflow error flags (must remain 0) |
| 11.3 | `tb_mc16x2_write_verify.err_ref_deadline_miss[31:0]` | Hex | Refresh deadline miss flags (must remain 0) |

---

## 3. Microarchitectural Dataflow & Bit Slicing Reference

### 3.1 AXI Address Bit Decomposition (40-bit `AWADDR`)

```
 39      33 32      29 28 27                  14 13  12 11  10 9       5 4     2 1   0
+----------+----------+--+----------------------+------+------+---------+-------+-----+
| Reserved | Channel  |PC|     Row Address      |  BG  | Bank | Column  | Lane  |Byte |
| (7 bits) | (4 bits) |  |      (14 bits)       |(2 b) |(2 b) | (5 b)   | (3 b) |Offset
|  39:33   |  32:29   |28|        27:14         |13:12 |11:10 |   9:5   |  4:2  | 1:0 |
+----------+----------+--+----------------------+------+------+---------+-------+-----+
```

| Field Name | Bit Range | Width | Description / Range |
|---|---|---|---|
| `Reserved` | `[39:33]` | 7 bits | Typically set to zero (`7'b0`) |
| `Channel` | `[32:29]` | 4 bits | Channel index `0` to `15` |
| `PC` | `[28]` | 1 bit | Pseudo-Channel select: `0` = PC0, `1` = PC1 |
| `Row` | `[27:14]` | 14 bits | DRAM Row address (`0` to `16,383`) |
| `BG` | `[13:12]` | 2 bits | Bank Group index (`0` to `3`) |
| `Bank` | `[11:10]` | 2 bits | Bank Address index (`0` to `3`) |
| `Column` | `[9:5]` | 5 bits | Column address (`0` to `31`) |
| `Lane` | `[4:2]` | 3 bits | Selects 32-bit word slice from 256-bit bus (`0` to `7`) |
| `Byte Offset` | `[1:0]` | 2 bits | 32-bit word aligned (`2'b00`) |

---

### 3.2 256-bit WDATA to 32-bit Lane Mapping Table

Each 256-bit AXI data payload contains 8 words of 32 bits. The `lane` field (`AWADDR[4:2]`) dictates which word is extracted by the decoder and passed to the DFI Formatter:

```
  s_axi_wdata[255:0]:
  [ Lane 7 ] [ Lane 6 ] [ Lane 5 ] [ Lane 4 ] [ Lane 3 ] [ Lane 2 ] [ Lane 1 ] [ Lane 0 ]
   255:224    223:192    191:160    159:128    127:96      95:64      63:32       31:0
```

| Lane (`AWADDR[4:2]`) | `s_axi_wdata` Bit Range | `s_axi_wstrb` Bit Range | Extracted Word at DFI Formatter | Active-High Mask at DFI |
|---|---|---|---|---|
| `3'b000` (Lane 0) | `[31:0]` | `[3:0]` | `wdata[31:0]` | `~wstrb[3:0]` |
| `3'b001` (Lane 1) | `[63:32]` | `[7:4]` | `wdata[63:32]` | `~wstrb[7:4]` |
| `3'b010` (Lane 2) | `[95:64]` | `[11:8]` | `wdata[95:64]` | `~wstrb[11:8]` |
| `3'b011` (Lane 3) | `[127:96]` | `[15:12]` | `wdata[127:96]` | `~wstrb[15:12]` |
| `3'b100` (Lane 4) | `[159:128]` | `[19:16]` | `wdata[159:128]` | `~wstrb[19:16]` |
| `3'b101` (Lane 5) | `[191:160]` | `[23:20]` | `wdata[191:160]` | `~wstrb[23:20]` |
| `3'b110` (Lane 6) | `[223:192]` | `[27:24]` | `wdata[223:192]` | `~wstrb[27:24]` |
| `3'b111` (Lane 7) | `[255:224]` | `[31:28]` | `wdata[255:224]` | `~wstrb[31:28]` |

---

### 3.3 DFI 5.0 Output Bus Packing Specifications

#### A. DFI Row Command Bus (`dfi_row[ch][21:0]`)
```
 21     20     18 17    16 15    14 13                           0
+------+---------+--------+--------+-------------------------------+
|pc_sel| row_cmd | row_bg | row_ba |           row_addr            |
| (1b) | (3b=001)|  (2b)  |  (2b)  |            (14b)              |
+------+---------+--------+--------+-------------------------------+
```
- `dfi_row[21]`: `0` for PC0, `1` for PC1.
- `dfi_row[20:18]`: Command code (`3'b001` = ACTIVATE).
- `dfi_row[17:16]`: Bank Group (`0` to `3`).
- `dfi_row[15:14]`: Bank Address (`0` to `3`).
- `dfi_row[13:0]`: Row Address (`0` to `16,383`).

#### B. DFI Column Command Bus (`dfi_col[ch][11:0]`)
```
 11     10      9 8      7 6      5 4               0
+------+---------+--------+--------+-----------------+
|pc_sel| col_cmd | col_bg | col_ba |    col_addr     |
| (1b) | (2b=10) |  (2b)  |  (2b)  |      (5b)       |
+------+---------+--------+--------+-----------------+
```
- `dfi_col[11]`: `0` for PC0, `1` for PC1.
- `dfi_col[10:9]`: Command code (`2'b10` = WRITE).
- `dfi_col[8:7]`: Bank Group (`0` to `3`).
- `dfi_col[6:5]`: Bank Address (`0` to `3`).
- `dfi_col[4:0]`: Column Address (`0` to `31`).

#### C. DFI Write Data Bus (`dfi_wrdata[ch][63:0]`)
- **Bits `[31:0]`**: Dedicated to **Pseudo-Channel 0 (PC0)**.
- **Bits `[63:32]`**: Dedicated to **Pseudo-Channel 1 (PC1)**.

#### D. DFI Write Mask Bus (`dfi_wrdata_mask[ch][7:0]`)
- **Bits `[3:0]`**: Active-high byte mask for **PC0** (`~wstrb[lane*4 +: 4]`).
- **Bits `[7:4]`**: Active-high byte mask for **PC1** (`~wstrb[lane*4 +: 4]`).

#### E. DFI Write Data Enable (`dfi_wrdata_en[ch][1:0]`)
- **Bit `[0]`**: Write strobe pulse for **PC0**.
- **Bit `[1]`**: Write strobe pulse for **PC1**.

---

## 4. Chronological Step-by-Step Execution Timeline

Below is the exact execution timeline as captured during simulation of **Test 1** (Channel 0, PC 0, Lane 0, ID `0xA1`):

```
Time (ps)       Microarchitectural Event & Signal Transitions
====================================================================================================
0               [RESET ASSERTION] aresetn=0, ctl_reset_n=0 asserted. All registers initialized.
10,000          [DFI RESET RELEASE] ctl_reset_n deasserted synchronously to negedge dfi_clk.
16,000          [AXI RESET RELEASE] aresetn deasserted synchronously to negedge aclk.
16,000-40,000   [CDC SETTLING] Gray code pointers and synchronizers settle across domains.
44,000          [AXI AW HANDSHAKE]
                - s_axi_awvalid=1, s_axi_awaddr=0x4000, s_axi_awid=0xA1, s_axi_awsize=5 (256-bit).
                - s_axi_awready=1. Handshake completes on rising aclk edge.
46,000          [AXI W HANDSHAKE]
                - s_axi_wvalid=1, s_axi_wlast=1, s_axi_wdata=256'h001122...89ABCDEF, s_axi_wstrb=0xFFFFFFFF.
                - s_axi_wready=1. Handshake completes on rising aclk edge.
48,000-50,000   [CDC PROPAGATION]
                - AW FIFO & W FIFO transfer payload across domains into dfi_clk domain.
                - u_addr_decode transitions: IDLE -> W_DATA -> W_ISSUE.
                - Decoded: channel=0, pc=0, target=0, row=0x0001, bg=0, bank=0, col=0, lane=0.
                - Extracted 32-bit slice: write_word = 0x89ABCDEF.
                - Extracted 4-bit strobe: write_strobes = 0xF -> wdb_push_mask = 0x0.
50,500          [PC CORE QUEUE ALLOCATION]
                - cmd_push_val[0]=1, cmd_push_entry[0] enqueued into CMDQ.
                - wdb_push_val[0]=1, wdb_push_data[0]=0x89ABCDEF enqueued into WDB buffer.
                - u_addr_decode transitions: W_ISSUE -> W_WAIT.
51,000          [DRAM ROW ACTIVATION (ACT)]
                - Bank (BG0, Bank0) was IDLE. Scheduler triggers ACTIVATE command.
                - Channel arbiter grants row bus to PC0.
                - DFI Formatter emits: dfi_row_val[0]=1, dfi_row[0]={pc=0, cmd=ACT, bg=0, ba=0, row=0x0001}.
                - mc_timing_check loads cnt_rcd[0] = 17 (tRCD timing countdown).
51,000-68,000   [tRCD COUNTDOWN]
                - cnt_rcd counts down 18 clock cycles: 17, 16, 15, ..., 1, 0.
                - legal_wr[0] remains 0, holding off the write column command.
69,000          [DRAM COLUMN WRITE & DFI DATA TRANSMISSION]
                - cnt_rcd reaches 0 -> legal_wr[0] asserts.
                - Scheduler requests WRITE column command (col_cmd = 2'b10, col_addr = 0x00).
                - Channel arbiter grants column bus to PC0.
                - DFI Formatter emits simultaneously on the SAME clock edge:
                  * dfi_col_val[0] = 1
                  * dfi_col[0] = {pc=0, cmd=WR, bg=0, ba=0, col=0x00}
                  * dfi_wrdata[0][31:0] = 0x89ABCDEF
                  * dfi_wrdata_mask[0][3:0] = 0x0
                  * dfi_wrdata_en[0][0] = 1
69,000          [WRITE COMPLETION FEEDBACK]
                - wr_done[0] pulses high (tied directly to dfi_wrdata_en[0][0]).
                - u_addr_decode detects wr_done[0]=1 and transitions: W_WAIT -> B_RESP.
                - m_bvalid=1, m_bid=0xA1, m_bresp=2'b00 pushed to CDC B FIFO.
77,000          [AXI WRITE RESPONSE (B CHANNEL)]
                - s_axi_bvalid asserts in aclk domain with s_axi_bid=0xA1, s_axi_bresp=2'b00.
                - s_axi_bready=1 handshakes and completes the entire write transaction.
88,000          [SETTLE & NEXT TRANSACTION]
                - Controller ready for subsequent transaction.
```

---

## 5. Waveform Viewing with GTKWave

### 5.1 Re-running Simulation and Generating Waveforms
To recompile and run the testbench:
```bash
cd /home/dell/MC16/top
verilator --binary --trace --timing -f filelist_write_verify.f --top-module tb_mc16x2_write_verify -j 8
./obj_dir/Vtb_mc16x2_write_verify
```
The simulation generates `mc16x2_write_tb.vcd` (1.7 MB).

### 5.2 Opening Waveform in GTKWave
```bash
gtkwave mc16x2_write_tb.vcd &
```

### 5.3 Automated GTKWave Layout File (`mc16x2_write.gtkw`)
You can open the pre-arranged waveform layout with one command:
```bash
gtkwave mc16x2_write_tb.vcd mc16x2_write.gtkw &
```
*(This loads all the signals in the exact 11-group hierarchy defined in Section 2, with colors and radices pre-configured).*

---

## 6. Checklist: What to Verify When Inspecting Waveforms

| Check Item | Signal(s) to Inspect | Expected Behavior |
|---|---|---|
| **1. AW Handshake** | `s_axi_awvalid`, `s_axi_awready` | Coincide high for 1 `aclk` cycle. Address and ID stable. |
| **2. W Handshake** | `s_axi_wvalid`, `s_axi_wready`, `s_axi_wlast` | Coincide high for 1 `aclk` cycle. 256-bit data present. |
| **3. Address Decoding** | `u_addr_decode.channel`, `pc`, `lane` | Correctly extracted from `AWADDR[32:29]`, `[28]`, and `[4:2]`. |
| **4. Word Slicing** | `u_addr_decode.write_word` | Matches the exact 32-bit slice `s_axi_wdata[lane*32 +: 32]`. |
| **5. Strobe Inversion** | `u_addr_decode.wdb_push_mask` | Equals `~s_axi_wstrb[lane*4 +: 4]` (active-high in DFI). |
| **6. CMDQ/WDB Queuing** | `cmd_push_val`, `wdb_push_val` | Pulse high for 1 cycle on target target index `{ch, pc}`. |
| **7. Row ACT Command** | `dfi_row_val[ch]`, `dfi_row[ch]` | Pulses high with `cmd=3'b001`, correct BG, Bank, and Row. |
| **8. tRCD Timing Spacing**| `cnt_rcd`, interval between ACT and WR | Exactly 18 `dfi_clk` cycles between ACT and WR command. |
| **9. Col WR Command** | `dfi_col_val[ch]`, `dfi_col[ch]` | Pulses high with `cmd=2'b10`, correct BG, Bank, and Col. |
| **10. DFI WrData & En** | `dfi_wrdata[ch]`, `dfi_wrdata_en[ch]` | Synchronous with `dfi_col_val`. Correct 32-bit word in PC slice. |
| **11. Write Done Feedback**| `wr_done[target]` | Pulses high simultaneously with `dfi_wrdata_en[ch][pc]`. |
| **12. AXI B Response** | `s_axi_bvalid`, `s_axi_bid`, `s_axi_bresp` | Asserts after `wr_done`. `BID == AWID`, `BRESP == 2'b00 (OKAY)`. |
| **13. Error Immunity** | `err_cmdq_overflow`, `err_wdb_overflow` | Must remain strictly `32'h00000000` throughout. |
