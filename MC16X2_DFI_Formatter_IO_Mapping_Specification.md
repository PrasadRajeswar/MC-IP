# MC16X2 Memory Controller IP
## DFI Formatter (`mc_dfi_formatter` / `mc_dfi_fmt`) Input & Output Interconnect Specification

**Document Version:** 1.0  
**Target RTL Modules:** [`mc_dfi_formatter.sv`](file:///home/dell/MC16/mc_dfi_formatter.sv), [`mc_dfi_fmt.sv`](file:///home/dell/MC16/mc_dfi_fmt.sv)  
**Parent Modules:** [`mc_channel_arb.sv`](file:///home/dell/MC16/mc_channel_arb.sv), [`mc_ch_arb.sv`](file:///home/dell/MC16/mc_ch_arb.sv), [`mc_channel.sv`](file:///home/dell/MC16/p5/mc_channel.sv), [`mc16x2.sv`](file:///home/dell/MC16/p5/mc16x2.sv)  
**Connected Blocks:** [`mc_pc_core.sv`](file:///home/dell/MC16/p5/mc_pc_core.sv), [`mc_credit_arb.sv`](file:///home/dell/MC16/mc_credit_arb.sv), [`mc_arbiter.sv`](file:///home/dell/MC16/mc_arbiter.sv), [`mc_read_return_arb.sv`](file:///home/dell/MC16/p5/mc_read_return_arb.sv), External DFI 5.0 PHY  

---

## 1. Executive Architectural Overview

In the **MC16X2 High-Bandwidth Memory Controller IP**, each physical HBM3 channel consists of two autonomous **Pseudo-Channels (PC0 and PC1)**. While PC0 and PC1 have dedicated command queues (`CMDQ`), write data buffers (`WDB`), read data buffers (`RDB`), bank state tables (16 banks each), and timing down-counters, the physical HBM3 DFI 5.0 interface exposes:
1. **A single shared Row Command Bus** (`dfi_row`, 22 bits).
2. **A single shared Column Command Bus** (`dfi_col`, 12 bits).
3. **A shared 64-bit Data Bus** (`dfi_wrdata` / `dfi_rddata`), partitioned as `[31:0]` for PC0 and `[63:32]` for PC1.

The **DFI Formatter** ([`mc_dfi_formatter.sv`](file:///home/dell/MC16/mc_dfi_formatter.sv) / [`mc_dfi_fmt.sv`](file:///home/dell/MC16/mc_dfi_fmt.sv)) serves as the **1-cycle registered boundary isolation and packetization stage** at 1 GHz (`dfi_clk`). It provides:
- **1 GHz Timing Closure Isolation**: Isolates deep internal scheduling and arbitration combinational paths (5–6 logic levels) from external PHY pad delays.
- **Bit-Vector Packetization**: Packs pseudo-channel identifiers, command opcodes, bank groups, bank addresses, and DRAM addresses into standardized DFI 5.0 bus encodings.
- **Data Path Aggregation & Demuxing**: Combines 32-bit PC write data and byte strobes into 64-bit/8-bit PHY buses, and demultiplexes returning 64-bit PHY read data into independent 32-bit streams for PC0 and PC1.

---

## 2. End-to-End System Block Diagram

```mermaid
flowchart TD
    subgraph PC0_Block ["Pseudo-Channel Core 0 (u_pc0)"]
        PC0_CMD["PC0 Command Scheduler and Refresh Engine"]
        PC0_WDB["PC0 Write Data Buffer (WDB0: 32-bit Data)"]
        PC0_RDB["PC0 Read Return Shift Register (RDB0)"]
    end

    subgraph PC1_Block ["Pseudo-Channel Core 1 (u_pc1)"]
        PC1_CMD["PC1 Command Scheduler and Refresh Engine"]
        PC1_WDB["PC1 Write Data Buffer (WDB1: 32-bit Data)"]
        PC1_RDB["PC1 Read Return Shift Register (RDB1)"]
    end

    subgraph Arb_Block ["Channel Arbiter (mc_channel_arb / mc_ch_arb)"]
        ROW_ARB["Row Credit Arbiter (Starvation Avoidance)"]
        COL_ARB["Column Credit Arbiter (Starvation Avoidance)"]
        ROW_MUX["Row Bus MUX (Opcode, BG, BA, Addr)"]
        COL_MUX["Column Bus MUX (Opcode, BG, BA, Addr)"]
        DATA_PACK["Data Bundler (64b wrdata, 8b mask, 2b en)"]
    end

    subgraph DFI_FMT_Block ["DFI Formatter (mc_dfi_formatter / mc_dfi_fmt)"]
        DFI_ROW_REG["1-Cycle Reg Flop: dfi_row_val and dfi_row (22-bit)"]
        DFI_COL_REG["1-Cycle Reg Flop: dfi_col_val and dfi_col (12-bit)"]
        DFI_WR_REG["1-Cycle Reg Flop: dfi_wrdata (64-bit) and mask (8-bit)"]
        DFI_RD_DEMUX["Read Slicer: dfi_rddata to rddata_pc0 and rddata_pc1"]
    end

    subgraph PHY_Block ["DFI 5.0 Physical Layer Interface (Top-Level Pins)"]
        PHY_ROW["PHY Row Command Bus: dfi_row_val_ch and dfi_row_ch"]
        PHY_COL["PHY Column Command Bus: dfi_col_val_ch and dfi_col_ch"]
        PHY_WR["PHY Write Data Bus: dfi_wrdata_ch and dfi_wrdata_mask_ch"]
        PHY_RD["PHY Read Data Bus: dfi_rddata_ch and dfi_rddata_valid_ch"]
    end

    PC0_CMD --> ROW_ARB
    PC1_CMD --> ROW_ARB
    PC0_CMD --> COL_ARB
    PC1_CMD --> COL_ARB

    ROW_ARB --> ROW_MUX
    PC0_CMD --> ROW_MUX
    PC1_CMD --> ROW_MUX

    COL_ARB --> COL_MUX
    PC0_CMD --> COL_MUX
    PC1_CMD --> COL_MUX

    PC0_WDB --> DATA_PACK
    PC1_WDB --> DATA_PACK

    ROW_MUX --> DFI_ROW_REG
    COL_MUX --> DFI_COL_REG
    DATA_PACK --> DFI_WR_REG

    DFI_ROW_REG --> PHY_ROW
    DFI_COL_REG --> PHY_COL
    DFI_WR_REG --> PHY_WR

    PHY_RD --> DFI_RD_DEMUX
    DFI_RD_DEMUX --> PC0_RDB
    DFI_RD_DEMUX --> PC1_RDB
```

### Structural Architecture Schematic

```
=========================================================================================================
                               MC16X2 CHANNEL ARBITER & DFI FORMATTER DATAFLOW
=========================================================================================================

  +--------------------------------+                          +--------------------------------+
  |      PC0 Core (u_pc0)          |                          |      PC1 Core (u_pc1)          |
  |  - CMDQ / 16-Bank State Table  |                          |  - CMDQ / 16-Bank State Table  |
  |  - Emergency Refresh Engine    |                          |  - Emergency Refresh Engine    |
  |  - Write Data Buffer (32-bit)  |                          |  - Write Data Buffer (32-bit)  |
  |  - Read Shift Register (32-bit)|                          |  - Read Shift Register (32-bit)|
  +--------------------------------+                          +--------------------------------+
       |             |          |                                  |             |          |
   Row Cand      Col Cand   wrdata_pc0                         Row Cand      Col Cand   wrdata_pc1
       |             |          |                                  |             |          |
       v             v          |                                  v             v          |
  ==============================|===========================================================|============
  CHANNEL ARBITER (mc_channel_arb / mc_ch_arb)                                              |
  ------------------------------------------------------------------------------------------|------------
    [Row Credit Arbiter] <---------------+                          [Col Credit Arbiter]    |
       | row_grant                       |                             | col_grant          |
       v                                 |                             v                    |
    [Row Bus MUX] <----------------------+                          [Col Bus MUX]           |
       | selected_row_*                                                | selected_col_*     |
       |                                                               |                    |
       |                +----------------------------------------------+                    |
       |                |                                                                   |
       |                |           [Write Data & Mask Bundler] <---------------------------+
       |                |             - combined_wrdata      = {wrdata_pc1, wrdata_pc0} (64b)
       |                |             - combined_wrdata_mask = {mask_pc1,   mask_pc0  } (8b)
       |                |             - combined_wrdata_en   = {en_pc1,     en_pc0    } (2b)
       |                |             - combined_rddata_en   = {rden_pc1,   rden_pc0  } (2b)
       |                |                     |
       v                v                     v
  =======================================================================================================
  DFI FORMATTER (mc_dfi_formatter / mc_dfi_fmt) - 1-Cycle Registered Boundary Stage (dfi_clk = 1 GHz)
  -------------------------------------------------------------------------------------------------------
    Row Flop:   dfi_row_val     <= row_valid;
                dfi_row[21:0]   <= {row_pc_sel, row_cmd[2:0], row_bg[1:0], row_ba[1:0], row_addr[13:0]};

    Col Flop:   dfi_col_val     <= col_valid;
                dfi_col[11:0]   <= {col_pc_sel, col_cmd[1:0], col_bg[1:0], col_ba[1:0], col_addr[4:0]};

    Data Flop:  dfi_wrdata      <= combined_wrdata;       // [31:0]=PC0, [63:32]=PC1
                dfi_wrdata_mask <= combined_wrdata_mask;  // [3:0]=PC0,  [7:4]=PC1
                dfi_wrdata_en   <= combined_wrdata_en;
                dfi_rddata_en   <= combined_rddata_en;

    Read Demux: rddata_pc0      <= dfi_rddata[31:0];      // Returned directly to PC0 RDB
                rddata_pc1      <= dfi_rddata[63:32];     // Returned directly to PC1 RDB
                rddata_valid    <= dfi_rddata_valid;
  =======================================================================================================
           |                |                 |                     ^
           v                v                 v                     |
  =======================================================================================================
  EXTERNAL DFI 5.0 PHY PADS (mc16x2 Top-Level Egress Pins)
  -------------------------------------------------------------------------------------------------------
    dfi_row_val_ch[ch]    (1-bit strobe to PHY)
    dfi_row_ch[ch][21:0]  (22-bit row bus to PHY)
    dfi_col_val_ch[ch]    (1-bit strobe to PHY)
    dfi_col_ch[ch][11:0]  (12-bit col bus to PHY)
    dfi_wrdata_ch[ch][63:0] & dfi_wrdata_mask_ch[ch][7:0] (64-bit write data + 8-bit mask to PHY)
    dfi_rddata_ch[ch][63:0] & dfi_rddata_valid_ch[ch][1:0] (64-bit read return + valid from PHY)
  =======================================================================================================
```

---

## 3. Comprehensive Input Mapping Table

The following table documents every input pin of `mc_dfi_formatter`, detailing its immediate source in [`mc_channel_arb.sv`](file:///home/dell/MC16/mc_channel_arb.sv) / [`mc_ch_arb.sv`](file:///home/dell/MC16/mc_ch_arb.sv), its root originating block, the driving logic expression, and its architectural purpose.

| Signal Name | Dir | Width | Immediate Arbiter Signal | Originating Source Block | Driving Logic Expression | Functional Purpose |
| :--- | :---: | :---: | :--- | :--- | :--- | :--- |
| `dfi_clk` | Input | 1 | `dfi_clk` | Top-Level Clock Gen | Direct Clock Net | 1 GHz DFI synchronous clock (1.0 ns period). |
| `dfi_reset_n` | Input | 1 | `dfi_reset_n` | Top-Level Reset / CSR | Active-low sync reset | Global controller reset line; synchronously resets all output boundary registers. |
| **`row_valid`** | Input | 1 | `\|row_grant` | [`mc_credit_arb`](file:///home/dell/MC16/mc_credit_arb.sv) (Row Arbiter) | `row_grant[0] \| row_grant[1]` | Qualifies whether a valid row command won arbitration in the current cycle. |
| **`row_pc_sel`** | Input | 1 | `row_grant[1]` | [`mc_credit_arb`](file:///home/dell/MC16/mc_credit_arb.sv) (Row Arbiter) | `row_grant[1]` | Identifies the winning Pseudo-Channel: `0` = PC0, `1` = PC1. |
| **`row_cmd`** | Input | 3 | `selected_row_cmd` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (u_pc0 / u_pc1) | `row_grant[0] ? row_cmd_pc0 : row_cmd_pc1` | Winning Row Command Opcode: `3'b000`=NOP, `3'b001`=ACT, `3'b010`=PRE, `3'b011`=REF. |
| **`row_bg`** | Input | 2 | `selected_row_bg` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (u_pc0 / u_pc1) | `row_grant[0] ? row_bg_pc0 : row_bg_pc1` | Winning Bank Group address (BG0–BG3). |
| **`row_ba`** | Input | 2 | `selected_row_ba` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (u_pc0 / u_pc1) | `row_grant[0] ? row_ba_pc0 : row_ba_pc1` | Winning Bank Address (BA0–BA3). |
| **`row_addr`** | Input | 14 | `selected_row_addr` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (u_pc0 / u_pc1) | `row_grant[0] ? row_addr_pc0 : row_addr_pc1` | Winning Row Address (R0–R13) driven to DRAM array during ACT/PRE. |
| **`col_valid`** | Input | 1 | `\|col_grant` | [`mc_credit_arb`](file:///home/dell/MC16/mc_credit_arb.sv) (Col Arbiter) | `col_grant[0] \| col_grant[1]` | Qualifies whether a valid column command won arbitration in the current cycle. |
| **`col_pc_sel`** | Input | 1 | `col_grant[1]` | [`mc_credit_arb`](file:///home/dell/MC16/mc_credit_arb.sv) (Col Arbiter) | `col_grant[1]` | Identifies the winning Pseudo-Channel: `0` = PC0, `1` = PC1. |
| **`col_cmd`** | Input | 2 | `selected_col_cmd` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (u_pc0 / u_pc1) | `col_grant[0] ? col_cmd_pc0 : col_cmd_pc1` | Winning Column Command Opcode: `2'b00`=NOP, `2'b01`=RD, `2'b10`=WR. |
| **`col_bg`** | Input | 2 | `selected_col_bg` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (u_pc0 / u_pc1) | `col_grant[0] ? col_bg_pc0 : col_bg_pc1` | Winning Bank Group address (BG0–BG3). |
| **`col_ba`** | Input | 2 | `selected_col_ba` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (u_pc0 / u_pc1) | `col_grant[0] ? col_ba_pc0 : col_ba_pc1` | Winning Bank Address (BA0–BA3). |
| **`col_addr`** | Input | 5 | `selected_col_addr` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (u_pc0 / u_pc1) | `col_grant[0] ? col_addr_pc0 : col_addr_pc1` | Winning Column Address (C0–C4). |
| **`wrdata`** | Input | 64 | `combined_wrdata` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (WDB0 & WDB1) | `{u_pc1.wrdata_pc, u_pc0.wrdata_pc}` | Combined 64-bit write data: lower 32 bits from PC0 WDB, upper 32 bits from PC1 WDB. |
| **`wrdata_mask`**| Input | 8 | `combined_wrdata_mask` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (WDB0 & WDB1) | `{u_pc1.wrdata_mask_pc, u_pc0.wrdata_mask_pc}` | Combined 8-bit byte mask: `[3:0]` from PC0 WDB, `[7:4]` from PC1 WDB. |
| **`wrdata_en`** | Input | 2 | `combined_wrdata_en` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (u_pc0 & u_pc1) | `{u_pc1.wrdata_en_pc, u_pc0.wrdata_en_pc}` | Dynamic write data valid strobes: `[0]`=PC0 write active, `[1]`=PC1 write active. |
| **`rddata_en`** | Input | 2 | `combined_rddata_en` | [`mc_pc_core`](file:///home/dell/MC16/p5/mc_pc_core.sv) (u_pc0 & u_pc1) | `{u_pc1.rddata_en_pc, u_pc0.rddata_en_pc}` | Expected read return data enable flags: `[0]`=PC0 read pending, `[1]`=PC1 read pending. |
| **`dfi_rddata`** | Input | 64 | `dfi_rddata` | External DFI 5.0 PHY Pads | Direct pad wire from PHY DQ pins | 64-bit read return data bus driven by DRAM through PHY. |
| **`dfi_rddata_valid`**| Input | 2 | `dfi_rddata_valid` | External DFI 5.0 PHY Pads | Direct pad wire from PHY control | Read data valid strobes returning from PHY: `[0]` for PC0, `[1]` for PC1. |

---

## 4. Comprehensive Output Mapping Table

The following table documents every output pin of `mc_dfi_formatter`, detailing its immediate destination in [`mc_channel_arb.sv`](file:///home/dell/MC16/mc_channel_arb.sv) / [`mc_channel.sv`](file:///home/dell/MC16/p5/mc_channel.sv), its final chip destination, the bit-packing/slicing equation, and its architectural purpose.

| Signal Name | Dir | Width | Immediate Arbiter Signal | Final Recipient Block & Pin | Packing / Slicing Formula | Functional Purpose |
| :--- | :---: | :---: | :--- | :--- | :--- | :--- |
| **`dfi_row_val`** | Output | 1 | `dfi_row_val` | External PHY Pad: [`mc16x2.sv`](file:///home/dell/MC16/p5/mc16x2.sv) `dfi_row_val_ch[ch]` | Flop: `row_valid` | 1-cycle registered row command valid strobe to PHY. |
| **`dfi_row`** | Output | 22 | `dfi_row` | External PHY Pad: [`mc16x2.sv`](file:///home/dell/MC16/p5/mc16x2.sv) `dfi_row_ch[ch][21:0]` | Flop: `{row_pc_sel, row_cmd[2:0], row_bg[1:0], row_ba[1:0], row_addr[13:0]}` | Standardized 22-bit DFI Row Command bus vector. |
| **`dfi_col_val`** | Output | 1 | `dfi_col_val` | External PHY Pad: [`mc16x2.sv`](file:///home/dell/MC16/p5/mc16x2.sv) `dfi_col_val_ch[ch]` | Flop: `col_valid` | 1-cycle registered column command valid strobe to PHY. |
| **`dfi_col`** | Output | 12 | `dfi_col` | External PHY Pad: [`mc16x2.sv`](file:///home/dell/MC16/p5/mc16x2.sv) `dfi_col_ch[ch][11:0]` | Flop: `{col_pc_sel, col_cmd[1:0], col_bg[1:0], col_ba[1:0], col_addr[4:0]}` | Standardized 12-bit DFI Column Command bus vector. |
| **`dfi_wrdata`** | Output | 64 | `dfi_wrdata` | External PHY Pad: [`mc16x2.sv`](file:///home/dell/MC16/p5/mc16x2.sv) `dfi_wrdata_ch[ch][63:0]` | Flop: `wrdata[63:0]` | 1-cycle registered 64-bit write data bus: `[31:0]`=PC0, `[63:32]`=PC1. |
| **`dfi_wrdata_mask`**| Output | 8 | `dfi_wrdata_mask` | External PHY Pad: [`mc16x2.sv`](file:///home/dell/MC16/p5/mc16x2.sv) `dfi_wrdata_mask_ch[ch][7:0]` | Flop: `wrdata_mask[7:0]` | 1-cycle registered 8-bit byte write mask: `[3:0]`=PC0, `[7:4]`=PC1. |
| **`dfi_wrdata_en`** | Output | 2 | `dfi_wrdata_en` | External PHY Pad: [`mc16x2.sv`](file:///home/dell/MC16/p5/mc16x2.sv) `dfi_wrdata_en_ch[ch][1:0]` | Flop: `wrdata_en[1:0]` | 1-cycle registered write data timing enable strobes to PHY. |
| **`dfi_rddata_en`** | Output | 2 | `dfi_rddata_en` | External PHY Pad: [`mc16x2.sv`](file:///home/dell/MC16/p5/mc16x2.sv) `dfi_rddata_en_ch[ch][1:0]` | Flop: `rddata_en[1:0]` | 1-cycle registered expected read return enable strobes to PHY. |
| **`rddata_pc0`** | Output | 32 | `rddata_pc0` | [`u_pc0.rddata_pc`](file:///home/dell/MC16/p5/mc_pc_core.sv#L51) | Sliced: `dfi_rddata[31:0]` | Lower 32 bits of returning PHY read data delivered to PC0 Core. |
| **`rddata_pc1`** | Output | 32 | `rddata_pc1` | [`u_pc1.rddata_pc`](file:///home/dell/MC16/p5/mc_pc_core.sv#L51) | Sliced: `dfi_rddata[63:32]` | Upper 32 bits of returning PHY read data delivered to PC1 Core. |
| **`rddata_valid`** | Output | 2 | `rddata_valid_pc` | `[0]` $\to$ `u_pc0.rddata_valid_pc`<br>`[1]` $\to$ `u_pc1.rddata_valid_pc` | Flop: `dfi_rddata_valid[1:0]` | Registered read valid strobes enabling PC0/PC1 Read Data Buffer shifts. |

---

## 5. Bit-Level Packing & Vector Definitions

### 5.1 Row Command Bus Vector (`dfi_row[21:0]`)

The 22-bit row vector concatenates 5 sub-fields into a single physical bus flopped directly to the PHY pads:

```
+------------+----------------+---------------+---------------+--------------------+
| Bit 21     | Bits [20:18]   | Bits [17:16]  | Bits [15:14]  | Bits [13:0]        |
| pc_sel     | cmd[2:0]       | bg[1:0]       | ba[1:0]       | addr[13:0]         |
+------------+----------------+---------------+---------------+--------------------+
```

| Bit Field | Name | Width | Encodings & Meaning |
| :---: | :---: | :---: | :--- |
| `[21]` | `row_pc_sel` | 1 | Target Pseudo-Channel selector:<br>• `1'b0`: pseudo-channel 0 (`PC0`)<br>• `1'b1`: pseudo-channel 1 (`PC1`) |
| `[20:18]` | `row_cmd[2:0]` | 3 | Row Command Opcode:<br>• `3'b000`: `NOP`<br>• `3'b001`: `ACT` (Activate Row)<br>• `3'b010`: `PRE` (Precharge Bank/All)<br>• `3'b011`: `REF` (All-Bank Refresh) |
| `[17:16]` | `row_bg[1:0]` | 2 | Bank Group identifier (`BG0` through `BG3`). |
| `[15:14]` | `row_ba[1:0]` | 2 | Bank Address identifier (`BA0` through `BA3`). |
| `[13:0]` | `row_addr[13:0]` | 14 | Row Address bits (`R0` through `R13`) selecting one of 16,384 rows. |

### 5.2 Column Command Bus Vector (`dfi_col[11:0]`)

The 12-bit column vector concatenates 5 sub-fields:

```
+------------+----------------+---------------+---------------+--------------------+
| Bit 11     | Bits [10:9]    | Bits [8:7]    | Bits [6:5]    | Bits [4:0]         |
| pc_sel     | cmd[1:0]       | bg[1:0]       | ba[1:0]       | addr[4:0]          |
+------------+----------------+---------------+---------------+--------------------+
```

| Bit Field | Name | Width | Encodings & Meaning |
| :---: | :---: | :---: | :--- |
| `[11]` | `col_pc_sel` | 1 | Target Pseudo-Channel selector:<br>• `1'b0`: pseudo-channel 0 (`PC0`)<br>• `1'b1`: pseudo-channel 1 (`PC1`) |
| `[10:9]` | `col_cmd[1:0]` | 2 | Column Command Opcode:<br>• `2'b00`: `NOP`<br>• `2'b01`: `RD` (Column Read Burst)<br>• `2'b10`: `WR` (Column Write Burst) |
| `[8:7]` | `col_bg[1:0]` | 2 | Bank Group identifier (`BG0` through `BG3`). |
| `[6:5]` | `col_ba[1:0]` | 2 | Bank Address identifier (`BA0` through `BA3`). |
| `[4:0]` | `col_addr[4:0]` | 5 | Column Address bits (`C0` through `C4`) specifying column offset. |

### 5.3 Write Data & Byte-Strobe Alignment

The 64-bit write data bus and 8-bit mask bus are partitioned into two 32-bit pseudo-channel lanes:
- **Bits `[31:0]` / Mask `[3:0]`**: Dedicated to **Pseudo-Channel 0**.
- **Bits `[63:32]` / Mask `[7:4]`**: Dedicated to **Pseudo-Channel 1**.

```
dfi_wrdata[63:0]:      [63 ............. 32] [31 ............. 0]
Lane Assignment:            PC1 (32 bits)         PC0 (32 bits)

dfi_wrdata_mask[7:0]:  [7 .............. 4]  [3 .............. 0]
Lane Assignment:            PC1 (4 bytes)         PC0 (4 bytes)
```

### 5.4 Read Data Demultiplexing & AXI Reassembly

When the PHY returns 64-bit read data, the formatter slices it across pseudo-channel boundaries:
1. `rddata_pc0 = dfi_rddata[31:0]`
2. `rddata_pc1 = dfi_rddata[63:32]`

Inside each [`mc_pc_core.sv`](file:///home/dell/MC16/p5/mc_pc_core.sv), each 32-bit beat is shifted across 8 consecutive cycles into a 256-bit shift register:
```math
$$\text{rdb\_shift}[255:0] \Longleftarrow \{\text{rddata\_pc}[31:0], \text{rdb\_shift}[255:32]\}$$
```

After 8 beats (`rdb_beat_cnt == 3'd7`), the 256-bit word is driven onto `rdata_axi` and passed to [`mc_read_return_arb.sv`](file:///home/dell/MC16/p5/mc_read_return_arb.sv), crossing the AXI CDC FIFO back to the host AXI4 bus.

---

## 6. Verilog RTL Implementation Reference

Below is the complete boundary flop stage implemented in [`mc_dfi_fmt.sv`](file:///home/dell/MC16/mc_dfi_fmt.sv):

```systemverilog
module mc_dfi_fmt (
    input  logic        dfi_clk,
    input  logic        dfi_reset_n,

    // Row Command Inputs
    input  logic        row_valid,
    input  logic        row_pc_sel,
    input  logic [2:0]  row_cmd,
    input  logic [1:0]  row_bg,
    input  logic [1:0]  row_ba,
    input  logic [13:0] row_addr,
    output logic        dfi_row_val,
    output logic [21:0] dfi_row,

    // Column Command Inputs
    input  logic        col_valid,
    input  logic        col_pc_sel,
    input  logic [1:0]  col_cmd,
    input  logic [1:0]  col_bg,
    input  logic [1:0]  col_ba,
    input  logic [4:0]  col_addr,
    output logic        dfi_col_val,
    output logic [11:0] dfi_col,

    // Write Data Inputs
    input  logic [63:0] wrdata,
    input  logic [7:0]  wrdata_mask,
    input  logic [1:0]  wrdata_en,
    output logic [63:0] dfi_wrdata,
    output logic [7:0]  dfi_wrdata_mask,
    output logic [1:0]  dfi_wrdata_en,

    // Read Data Path
    input  logic [63:0] dfi_rddata,
    input  logic [1:0]  dfi_rddata_valid,
    input  logic [1:0]  rddata_en,
    output logic [1:0]  dfi_rddata_en,
    output logic [31:0] rddata_pc0,
    output logic [31:0] rddata_pc1,
    output logic [1:0]  rddata_valid
);

    always_ff @(posedge dfi_clk or negedge dfi_reset_n) begin
        if (!dfi_reset_n) begin
            dfi_row_val      <= 1'b0;
            dfi_row          <= '0;
            dfi_col_val      <= 1'b0;
            dfi_col          <= '0;
            dfi_wrdata       <= '0;
            dfi_wrdata_mask  <= '0;
            dfi_wrdata_en    <= '0;
            rddata_pc0       <= '0;
            rddata_pc1       <= '0;
            dfi_rddata_en    <= '0;
            rddata_valid     <= '0;
        end else begin
            // 1. Pack and flop Row command
            dfi_row_val      <= row_valid;
            dfi_row          <= {row_pc_sel, row_cmd, row_bg, row_ba, row_addr};

            // 2. Pack and flop Column command
            dfi_col_val      <= col_valid;
            dfi_col          <= {col_pc_sel, col_cmd, col_bg, col_ba, col_addr};

            // 3. Flop Write Data and Mask
            dfi_wrdata       <= wrdata;
            dfi_wrdata_mask  <= wrdata_mask;
            dfi_wrdata_en    <= wrdata_en;

            // 4. Demux returning PHY Read Data and forward to PC0 and PC1
            rddata_pc0       <= dfi_rddata[31:0];
            rddata_pc1       <= dfi_rddata[63:32];
            dfi_rddata_en    <= rddata_en;
            rddata_valid     <= dfi_rddata_valid;
        end
    end

endmodule
```

---

## 7. Summary Checklist for Verification & Synthesis

1. **Setup Margin at PHY Pinned Egress**: Zero combinational logic exists between the internal pipeline flops and the module output ports (`dfi_row`, `dfi_col`, `dfi_wrdata`, `dfi_wrdata_mask`).
2. **Dual-Issue Non-Interference**: The Row bus and Column bus operate independently—PC0 may issue a Row ACT while PC1 issues a Column RD in the exact same clock cycle without structural hazards.
3. **Data Integrity on Demuxing**: Slicing is verified by unit testbench [`tb_dfi_formatter.sv`](file:///home/dell/MC16/tb_dfi_formatter.sv) ensuring no bit shifts, endian mismatches, or channel lane cross-talk occur.
