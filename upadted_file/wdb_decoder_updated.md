# MC16X2 Memory Controller: WDB, Address Decoder & Arbitration Technical Documentation

This document records the complete technical discussion, questions, architectural analyses, and code rectifications conducted for the **MC16X2 High-Bandwidth Memory Controller IP** (interfacing AXI4 to HBM3 via DFI 5.0), aligned with `MC_IP_Microarchitecture_Spec6.pdf`.

---

## Table of Contents
1. [Initial Inquiry: 256-bit Data & 16-bit Mask Transfer (WDB & DFI)](#1-initial-inquiry-256-bit-data--16-bit-mask-transfer-wdb--dfi)
2. [Clock Domains & Timing: AXI vs. DFI](#2-clock-domains--timing-axi-vs-dfi)
3. [W CDC FIFO to WDB Transfer Timing Analysis](#3-w-cdc-fifo-to-wdb-transfer-timing-analysis)
4. [Spatial Slicing vs. Temporal Serialization (256-bit Bus vs. 32-bit Packets)](#4-spatial-slicing-vs-temporal-serialization-256-bit-bus-vs-32-bit-packets)
5. [The Single 32-bit Slice Paradox: Does 256 bits Require 8 Cycles?](#5-the-single-32-bit-slice-paradox-does-256-bits-require-8-cycles)
6. [Spec vs. RTL: The 8-Cycle Streaming Mechanism](#6-spec-vs-rtl-the-8-cycle-streaming-mechanism)
7. [WDB Buffer Sizing & Math](#7-wdb-buffer-sizing--math)
8. [Analysis of AWADDR[4:2]: Byte Offsets vs. Lane Slicing](#8-analysis-of-awaddr42-byte-offsets-vs-lane-slicing)
9. [Rectified Address Decoder: `decoder.sv`](#9-rectified-address-decoder-decodersv)
10. [Detailed Highlights of Decoder Modifications](#10-detailed-highlights-of-decoder-modifications)
11. [Why `wbeat` is Used for Read Port, Not Write Port](#11-why-wbeat-is-used-for-read-port-not-write-port)
12. [WDB Updated Implementation: `wdb_updated.sv`](#12-wdb-updated-implementation-wdb_updatedsv)
13. [End-to-End Write Transaction Timing Verification](#13-end-to-end-write-transaction-timing-verification)
14. [Credit-Counter Arbitration Policy & Physical/Timing Interpretation](#14-credit-counter-arbitration-policy--physicaltiming-interpretation)

---

## 1. Initial Inquiry: 256-bit Data & 16-bit Mask Transfer (WDB & DFI)

### User Question:
> *So, technically, 256 bits of data and 16 bits of data mask should go in 8 cycles to the WDB. And from there it should go to dft_fmt right? Is this what the spec says?*

### Technical Answer & Corrections:
1. **Mask Width:** AXI byte write strobe is **32 bits** (`s_axi_wstrb[31:0]`), not 16 bits, corresponding to 32 bytes (256 bits). At DFI, the byte mask per Pseudo-Channel is **4 bits** (`dfi_wrdata_mask[3:0]`).
2. **Transfer to WDB:** In the existing RTL implementation, address bits `AWADDR[4:2]` selected **only one 32-bit slice** and 4 bits of mask; this single word was pushed to WDB in **1 cycle**, not 8 cycles.
3. **Module Naming & Issuance:** The module is `mc_dfi_fmt` (DFI Formatter, not DFT). Upon column write grant, data is read from the WDB and issued to the DFI Formatter.

---

## 2. Clock Domains & Timing: AXI vs. DFI

### User Question:
> *When I would implement 8-cycle transfer of all 256 bits into the WDB, I should see that in 8 aclk cycles my 256 bits of data is going into the WDB and in 8 dfi_clk cycles it is going to the DFI Formatter, in the waveform right?*

### Technical Answer:
1. **WDB Clock Domain:** WDB resides in the **`dfi_clk` domain (1 GHz / 1.0 ns)**, not `aclk` (500 MHz / 2.0 ns).
   * AXI write data enters the asynchronous W CDC FIFO in **1 `aclk` cycle**.
   * Any transfer into the WDB occurs entirely within the **`dfi_clk` domain**.
2. **DFI Transfer Spacing:** Transfers to the DFI Formatter cannot occur across 8 consecutive back-to-back clock cycles without observing DRAM timing. Parameter $t_{CCD}$ (column-to-column delay, $T_{CCD} = 4$ cycles) spaces column write commands.

---

## 3. W CDC FIFO to WDB Transfer Timing Analysis

### User Question:
> *Data is being sent from the master "wdata" through AXI domain, in aclk. The wdata then moves to W FIFO, gets stored there in one cycle of the aclk. But WDB accepts that data from the FIFO using dfi_clk and in 8 clock cycles. I should see the WDB accepting data in 8 clk cycles in the waveform right?*

### Technical Answer:
**No.** In the waveform, WDB does not accept data across 8 cycles:
* **Section 6.2.2:** The asynchronous W CDC FIFO is **289 bits wide** (`WDATA 256 + WSTRB 32 + WLAST 1`).
* Both the pop side of the W FIFO and the WDB run in the **`dfi_clk` domain**.
* In `mc16x2_write_tb.vcd`, `wdb_push_val` asserts for **exactly 1 `dfi_clk` cycle** (1.0 ns, e.g., at timestamp 48,500 ps to 49,500 ps). The controller unloads the FIFO into WDB in 1 cycle.

---

## 4. Spatial Slicing vs. Temporal Serialization (256-bit Bus vs. 32-bit Packets)

### User Question:
> *Then what exactly is the meaning of 256 bits of data going in with 32 bits each packets?*

### Technical Answer:
* **Bus Width Mismatch:**
  * Host AXI Data Bus: **256 bits wide** (32 bytes per beat).
  * HBM3 Pseudo-Channel Data Bus: **32 bits wide** (4 bytes per beat).
  * Ratio: $256 \div 32 = 8$ words (packets/lanes).
* **Spatial (Parallel Wires) vs. Temporal (Clock Cycles):**
  * All 256 bits arrive **in parallel across physical wires in 1 clock cycle**:
    ```
    s_axi_wdata[255:0]:
    [ Lane 7 ] [ Lane 6 ] [ Lane 5 ] [ Lane 4 ] [ Lane 3 ] [ Lane 2 ] [ Lane 1 ] [ Lane 0 ]
     255:224    223:192    191:160    159:128    127:96      95:64      63:32       31:0
    ```
  * In the original RTL, `AWADDR[4:2]` was used as an 8-to-1 multiplexer select to extract one 32-bit packet from the 256-bit bus.

---

## 5. The Single 32-bit Slice Paradox: Does 256 bits Require 8 Cycles?

### User Question:
> *Just you said, single 32-bit packet into WDB in 1 cycle. Then it requires 8 cycles to send in 256 bits isn't it?*

### Technical Answer:
* In the original RTL (`mc_addr_decode.sv`), the controller was **not writing all 256 bits to the WDB**.
* It captured `write_word <= wdata[lane*32 +: 32]` (32 bits) and **discarded the remaining 224 bits**.
* The transaction then finished and issued `bresp = OKAY`. To write 256 bits under that original RTL, the host had to issue 8 separate AXI write requests with incremented lane addresses (`AWADDR[4:2] = 000` to `111`).

---

## 6. Spec vs. RTL: The 8-Cycle Streaming Mechanism

### User Question:
> *What is the mechanism there within the WDB and the PC that it would be streaming 32 bit of data in 8 cycles? The PC should know this has to be done right? What does the spec say and where the design files I have fails to address this?*

### Technical Answer:
1. **Spec Requirements:**
   * **Section 4.2:** $\text{WDB Sizing} = 16 \text{ entries} \times \text{burst-length } (8) \times \text{data width } (32\text{b}) = 16 \times 256\text{ bits}$.
   * **Section 5.1:** *"WDB data streamed out on that PC's data lane"* — for writes, `dfi_wrdata_en` asserts and data streams across 8 cycles ($BL8$).
2. **Where Original RTL Failed:**
   * `mc_addr_decode.sv`: Extracted `wdata[lane*32 +: 32]` and discarded 224 bits.
   * `mc_wdb.sv`: `data_mem` was defined as `logic [31:0] data_mem [15:0]` (only 32 bits wide per entry; physically incapable of holding 256 bits).
   * `mc_pc_core.sv`: Had no burst state machine; treated writes as a 1-cycle instantaneous event.
   * `mc16x2.sv`: `write_issue = col_grant && (col_cmd == COL_WR)` asserted for only 1 cycle.

---

## 7. WDB Buffer Sizing & Math

### User Questions:
> *1. So the WDB should be of 16 entries \* burst_length (8) \* data width (256) bits wide?*  
> *2. So the 16 entries is for 16 channels?*  
> *3. And each buffer can store up to 512 bytes?*

### Technical Answer:
1. **Dimensioning Formula:**
   * Data width of Pseudo-Channel = 32 bits.
   * Burst length = 8 beats ($BL8$).
   * $1 \text{ entry} = 8 \times 32\text{ bits} = \mathbf{256\text{ bits (32 bytes)}}$.
2. **Resource Allocation (Section 4.2):**
   * The 16 entries are **queue depth per Pseudo-Channel (PC)**, not channels.
   * With 16 Channels $\times$ 2 PCs = **32 PC Cores**, there are **32 distinct WDB instances**.
3. **Capacity Math:**
   * Per WDB instance: $16 \text{ entries} \times 32 \text{ bytes} = \mathbf{512\text{ bytes}}$ (+ 64 bytes mask).
   * Total IP Storage: $32 \text{ instances} \times 512 \text{ bytes} = \mathbf{16\text{ KB}}$.

---

## 8. Analysis of AWADDR[4:2]: Byte Offsets vs. Lane Slicing

### User Question:
> *AWADDR[4:2] these bits are mentioned as byte offsets. Why and how they could be responsible for data transfer? So, you are saying the byte offset intention in spec and usage in the decoder block doesn't match and it is a wrong use?*

### Technical Answer:
* **The Math:** On a 256-bit (32-byte) bus, $\log_2(32) = 5$ bits (`AWADDR[4:0]`):
  * `AWADDR[1:0]`: Byte offset within a 32-bit word ($0..3$).
  * `AWADDR[4:2]`: Word offset within a 256-bit beat ($0..7$).
* **The Spec Intention (Section 3.1.4):**
  * `AWADDR[4:0]` is defined as: *"Byte position within a 32-byte AXI beat (not used for CH/PC decode)"*.
  * The spec intended for the entire 256-bit beat to be transferred atomically.
* **The RTL Shortcut:**
  * The original RTL used `AWADDR[4:2]` as a multiplexer select (`lane`) to support narrow 32-bit writes and avoid implementing an 8-cycle burst serializer.
  * This was an architectural defect causing silent data loss of 224 bits during full 256-bit AXI writes.

---

## 9. Rectified Address Decoder: `decoder.sv`

The updated address decoder preserves all 256 bits of write data and 32 bits of mask, routing them directly to the WDB. Saved to `top/decoder.sv`.

```systemverilog
`timescale 1ns/1ps
`default_nettype none

module mc_addr_decode (
    input wire logic clk, rst_n,

    // AXI4 Write Address Channel
    input wire logic [7:0]  awid, awlen,
    input wire logic [39:0] awaddr,
    input wire logic [2:0]  awsize,
    input wire logic [1:0]  awburst,
    input wire logic        awvalid,
    output logic            awready,

    // AXI4 Write Data Channel
    input wire logic [255:0] wdata,
    input wire logic [31:0]  wstrb,
    input wire logic         wvalid,
    output logic             wready,

    // AXI4 Write Response Channel
    output logic [7:0] bid,
    output logic [1:0] bresp,
    output logic       bvalid,
    input wire logic   bready,

    // AXI4 Read Address Channel
    input wire logic [7:0]  arid, arlen,
    input wire logic [39:0] araddr,
    input wire logic [2:0]  arsize,
    input wire logic [1:0]  arburst,
    input wire logic        arvalid,
    output logic            arready,

    // AXI4 Read Data Channel
    output logic [7:0]   rid,
    output logic [255:0] rdata,
    output logic [1:0]   rresp,
    output logic         rlast, rvalid,
    input wire logic     rready,

    // CMDQ Interface to 32 PC Cores
    output logic [31:0]        cmd_push_val,
    output logic [31:0][35:0]  cmd_push_entry,
    input wire logic [31:0]    cmdq_full,

    // WDB Interface to 32 PC Cores (Full 256-bit data + 32-bit mask)
    output logic [31:0]        wdb_push_val,
    output logic [31:0][255:0] wdb_push_data,
    output logic [31:0][31:0]  wdb_push_mask,
    input wire logic [31:0][3:0] wdb_alloc_ptr,
    input wire logic [31:0]    wdb_full,
    input wire logic [31:0]    wr_done,

    // RDB Interface from 32 PC Cores (Full 256-bit read return)
    input wire logic [31:0]        rdb_valid,
    output logic [31:0]            rdb_ready,
    input wire logic [31:0][255:0] rdb_data
);

    // FSM States
    logic [2:0] state;
    localparam logic [2:0] IDLE    = 3'b000, 
                           W_DATA  = 3'b001,
                           W_ISSUE = 3'b010, 
                           W_WAIT  = 3'b011,
                           B_RESP  = 3'b100, 
                           R_ISSUE = 3'b101,
                           R_WAIT  = 3'b110, 
                           R_RESP  = 3'b111;

    logic [7:0]   txn_id;
    logic [39:0]  txn_addr;
    logic [255:0] write_payload;
    logic [31:0]  write_strobes;
    logic [255:0] read_payload;

    // Address Decoding (Spec Section 3.1.4)
    logic [3:0]  channel;
    logic        pc;
    logic [4:0]  target;
    logic [13:0] row;
    logic [1:0]  bg, bank;
    logic [4:0]  col;

    logic prefer_read;
    logic accept_write, accept_read;
    logic write_dispatch, read_dispatch;

    // Field extraction per Spec Table 3.1.4
    assign channel = txn_addr[32:29];
    assign pc      = txn_addr[28];
    assign target  = {channel, pc};
    assign row     = txn_addr[27:14];
    assign bg      = txn_addr[13:12];
    assign bank    = txn_addr[11:10];
    assign col     = txn_addr[9:5];

    assign accept_write = awvalid && awready;
    assign accept_read  = arvalid && arready;

    // Address Handshake Arbitration
    always_comb begin
        awready = 1'b0;
        arready = 1'b0;

        if (rst_n && state == IDLE) begin
            if (awvalid && arvalid) begin
                if (prefer_read)
                    arready = 1'b1;
                else
                    awready = 1'b1;
            end
            else if (awvalid)
                awready = 1'b1;
            else if (arvalid)
                arready = 1'b1;
        end
    end

    // Bus Responses
    always_comb begin
        wready  = rst_n && (state == W_DATA);

        bid     = txn_id;
        bresp   = 2'b00; // OKAY
        bvalid  = rst_n && (state == B_RESP);

        rid     = txn_id;
        rdata   = read_payload;
        rresp   = 2'b00; // OKAY
        rlast   = 1'b1;
        rvalid  = rst_n && (state == R_RESP);
    end

    // Dispatch qualifiers
    assign write_dispatch = (state == W_ISSUE) &&
                            !cmdq_full[target] &&
                            !wdb_full[target] &&
                            (|write_strobes);

    assign read_dispatch  = (state == R_ISSUE) &&
                            !cmdq_full[target];

    // Core Enqueue Combinational Logic
    always_comb begin
        cmd_push_val   = '0;
        cmd_push_entry = '0;
        wdb_push_val   = '0;
        wdb_push_data  = '0;
        wdb_push_mask  = '0;
        rdb_ready      = '0;

        if (rst_n && write_dispatch) begin
            cmd_push_val[target]   = 1'b1;
            cmd_push_entry[target] = {
                txn_id, 1'b1, row, bg, bank, col,
                wdb_alloc_ptr[target]
            };
            wdb_push_val[target]  = 1'b1;
            wdb_push_data[target] = write_payload;  // Full 256 bits
            wdb_push_mask[target] = ~write_strobes; // Full 32-bit active-high mask
        end

        if (rst_n && read_dispatch) begin
            cmd_push_val[target]   = 1'b1;
            cmd_push_entry[target] = {
                txn_id, 1'b0, row, bg, bank, col, 4'b0000
            };
        end

        if (rst_n && state == R_WAIT)
            rdb_ready[target] = 1'b1;
    end

    // State Machine
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state         <= IDLE;
            txn_id        <= '0;
            txn_addr      <= '0;
            write_payload <= '0;
            write_strobes <= '0;
            read_payload  <= '0;
            prefer_read   <= 1'b0;
        end
        else begin
            case (state)
                IDLE: begin
                    if (accept_write) begin
                        txn_id        <= awid;
                        txn_addr      <= awaddr;
                        read_payload  <= '0;
                        prefer_read   <= 1'b1;
                        state         <= W_DATA;
                    end
                    else if (accept_read) begin
                        txn_id        <= arid;
                        txn_addr      <= araddr;
                        read_payload  <= '0;
                        prefer_read   <= 1'b0;
                        state         <= R_ISSUE;
                    end
                end

                W_DATA: begin
                    if (wvalid && wready) begin
                        write_payload <= wdata; // Capture all 256 bits
                        write_strobes <= wstrb; // Capture all 32 strobes

                        if (wstrb == 32'h0000_0000)
                            state <= B_RESP;
                        else
                            state <= W_ISSUE;
                    end
                end

                W_ISSUE: begin
                    if (write_dispatch)
                        state <= W_WAIT;
                end

                W_WAIT: begin
                    if (wr_done[target])
                        state <= B_RESP;
                end

                B_RESP: begin
                    if (bready)
                        state <= IDLE;
                end

                R_ISSUE: begin
                    if (read_dispatch)
                        state <= R_WAIT;
                end

                R_WAIT: begin
                    if (rdb_valid[target] && rdb_ready[target]) begin
                        read_payload <= rdb_data[target]; // Capture full 256 bits
                        state        <= R_RESP;
                    end
                end

                R_RESP: begin
                    if (rready)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
```

---

## 10. Detailed Highlights of Decoder Modifications

1. **WDB Push Data & Mask Ports (Lines 43–44):**
   * `output logic [31:0][255:0] wdb_push_data`: Widened from 32b to 256b per PC.
   * `output logic [31:0][31:0] wdb_push_mask`: Widened from 4b to 32b per PC.
2. **RDB Read Data Port (Line 51):**
   * `input wire logic [31:0][255:0] rdb_data`: Widened from 32b to 256b per PC.
3. **Elimination of `lane` Logic (Lines 72 & 85):**
   * Deleted `logic [2:0] lane` and `assign lane = txn_addr[4:2]`.
4. **`W_DATA` Capture (Lines 190–198):**
   * Replaced single-slice capture with `write_payload <= wdata` and `write_strobes <= wstrb`.
5. **WDB Drive (Lines 145–146):**
   * Directly assigns `wdb_push_data[target] = write_payload` (256b) and `wdb_push_mask[target] = ~write_strobes` (32b).
6. **`R_WAIT` Return (Line 223):**
   * Direct full 256-bit assignment `read_payload <= rdb_data[target]`.

---

## 11. Why `wbeat` is Used for Read Port, Not Write Port

### User Inquiry:
> *In the WDB code above, we have created a `rbeat` for the read port. Why have we done this and why not for the write transaction? Let's to avoid confusion change `rbeat` to `wbeat`.*

### Technical Explanation:
* **Write Port (Host $\rightarrow$ WDB):**
  * Bus width is **256 bits wide**.
  * The entire 256-bit payload and 32-bit mask are latched in parallel on **1 clock edge (1 cycle)**.
  * No multi-cycle sequencing is needed $\rightarrow$ **No write counter needed**.
* **Read Port (WDB $\rightarrow$ DFI Formatter / PHY):**
  * The physical Pseudo-Channel data lane is only **32 bits wide**.
  * 256 bits must be serialized as $8 \times 32\text{b}$ words over 8 cycles.
  * **`wbeat` (0 to 7)** acts as the **3-bit multiplexer select**, pointing to the specific 32-bit word currently driving the DFI bus.
  * Renaming from `rbeat` to **`wbeat`** clarifies that it sequences the 8 beats of a **DRAM Write Burst**.

---

## 12. WDB Updated Implementation: `wdb_updated.sv`

Saved to `top/wdb_updated.sv`:

```systemverilog
`timescale 1ns/1ps
`default_nettype none

module mc_wdb #(
  parameter int AXI_DATA_W    = 256,
  parameter int AXI_MASK_W    = 32,
  parameter int DFI_PC_DATA_W = 32,
  parameter int DFI_PC_MASK_W = 4,
  parameter int WDB_DEPTH     = 16,
  parameter int WDB_ADDR_W    = $clog2(WDB_DEPTH)
) (
  input  wire logic                      clk,           // Scheduler clock (dfi_clk domain)
  input  wire logic                      rst_n,         // Synchronous active-low reset

  // Write port: stores full 256-bit payload and 32-bit byte mask in 1 cycle
  input  wire logic                      wdb_push_val,
  input  wire logic [AXI_DATA_W-1:0]     wdb_push_data,
  input  wire logic [AXI_MASK_W-1:0]     wdb_push_mask,
  output logic      [WDB_ADDR_W-1:0]     wdb_alloc_ptr,
  output logic                           wdb_full,
  output logic                           wdb_overflow,
  output logic      [WDB_DEPTH-1:0]      wdb_data_rdy,

  // Outgoing port to DFI: streams 32 bits per cycle across 8 write beats
  input  wire logic [WDB_ADDR_W-1:0]     wdb_raddr,
  input  wire logic [2:0]                wbeat,         // Write beat counter (0..7) to DRAM PHY
  output logic      [DFI_PC_DATA_W-1:0]  wdb_rdata,
  output logic      [DFI_PC_MASK_W-1:0]  wdb_rmask,

  // Pop port: releases slot on the final write beat (wbeat == 7)
  input  wire logic                      wdb_pop_val,
  input  wire logic [WDB_ADDR_W-1:0]     wdb_pop_ptr
);

  logic [AXI_DATA_W-1:0] data_mem [WDB_DEPTH-1:0];
  logic [AXI_MASK_W-1:0] mask_mem [WDB_DEPTH-1:0];
  logic [WDB_DEPTH-1:0]  valid_reg;
  logic                  free_found;

  assign wdb_data_rdy = valid_reg;
  assign wdb_full     = &valid_reg;
  assign wdb_overflow = wdb_push_val && wdb_full;

  // Allocate lowest available free slot
  always_comb begin
    wdb_alloc_ptr = '0;
    free_found    = 1'b0;
    for (int i = 0; i < WDB_DEPTH; i++) begin
      if (!valid_reg[i] && !free_found) begin
        wdb_alloc_ptr = WDB_ADDR_W'(i);
        free_found    = 1'b1;
      end
    end
  end

  // Combinational multiplexing: selects the 32-bit slice and 4-bit mask for the current write beat
  assign wdb_rdata = data_mem[wdb_raddr][wbeat*32 +: 32];
  assign wdb_rmask = mask_mem[wdb_raddr][wbeat*4  +: 4];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_reg <= '0;
      for (int i = 0; i < WDB_DEPTH; i++) begin
        data_mem[i] <= '0;
        mask_mem[i] <= '0;
      end
    end else begin
      // Release slot only on the final write beat (beat 7)
      if (wdb_pop_val && (wbeat == 3'd7)) begin
        valid_reg[wdb_pop_ptr] <= 1'b0;
      end

      // Push full 256-bit payload and 32-bit mask in 1 cycle
      if (wdb_push_val && !wdb_full) begin
        valid_reg[wdb_alloc_ptr] <= 1'b1;
        data_mem[wdb_alloc_ptr]  <= wdb_push_data;
        mask_mem[wdb_alloc_ptr]  <= wdb_push_mask;
      end
    end
  end

endmodule : mc_wdb
`default_nettype wire
```

---

## 13. End-to-End Write Transaction Timing Verification

### User Inquiry:
> *The AXI sends "wdata" to W CDC FIFO in a single AXI beat, FIFO sends 'em to the WDB in a single AXI beat and after that, wdata takes 8 cycles to go into the PC and further into the DFI Formatter. Is this interpretation right?*

### Timing & Structural Clarification:
* **Timing:** **100% correct.**
  1. AXI $\rightarrow$ W CDC FIFO: **1 `aclk` cycle** (500 MHz).
  2. W CDC FIFO $\rightarrow$ WDB: **1 `dfi_clk` cycle** (1 GHz).
  3. WDB $\rightarrow$ DFI Formatter: **8 `dfi_clk` cycles** (streaming 32b/cycle via `wbeat`).
* **Structural Clarification:** The WDB is **physically instantiated inside the PC Core (`mc_pc_core.sv`)**. Data does not travel "into the PC" after WDB; it is already inside the PC, and streams **out of the PC Core $\rightarrow$ through channel arbitration $\rightarrow$ to the DFI Formatter**.

---

## 14. Credit-Counter Arbitration Policy & Physical/Timing Interpretation

### User Inquiry:
> *Explain the arbitration policy according to the spec and explain its timing and physical interpretation and then take the code into consideration. Detail the changes if needed.*

### Comprehensive Explanation:

#### 1. Architecture & Policy (Spec Section 5.2 & 5.6):
* **Credit-Counter Starvation Avoidance:** The only arbitration scheme in the controller.
* **8-bit Saturating Counters:** Each candidate command tracks wait cycles (max 255).
* **Selection:** Highest counter wins. Ties broken by lowest index (CMDQ slot) or PC0 over PC1 (channel level).
* **Reset & Aging:** Winner resets counter to 0 upon `grant_ack`. Eligible losers increment by 1 each cycle.
* **Refresh Preemption:** Refresh (`REF`) has automatic top priority (`req_priority = 1`) and always wins.

#### 2. Physical & Timing Interpretation:
* **HBM3 Silicon Constraints:** Row and Column command buses are physically shared between PC0 and PC1 at the package pins. However, the data pins are split ($32\text{b} + 32\text{b}$).
* **Independent Arbitration:** Row arbitration and Column arbitration are completely independent. PC0 Row command and PC1 Column command can issue simultaneously in the same cycle without contention.
* **1 GHz Single-Cycle Latency:** The decision logic is strictly combinational ($\le 6$ logic levels) to meet 1.0 ns timing closure.

#### 3. Code Evaluation & Downstream Changes Needed:
* **`mc_arbiter.sv`:** 100% compliant with the spec.
* **`mc_ch_arb.sv`:** 100% compliant with the spec.
* **Required System Updates for 8-Cycle Bursting:**
  1. **`mc_pc_core.sv`:** Must instantiate a 3-bit burst counter (`wbeat = 0..7`) started by `col_grant && (col_cmd == COL_WR)`.
  2. **`mc16x2.sv`:** Must maintain `write_enable[pc]` and drive `lane_data` across all 8 cycles of `wbeat` instead of pulsing for 1 cycle.
  3. **`mc_timing_check.sv`:** Must ensure column-to-column write spacing ($t_{CCD}$) prevents the same PC from scheduling another column command while its 8-cycle data burst is occupying the lane.

---
*Document generated on 2026-11-17. References: `MC_IP_Microarchitecture_Spec6.pdf`, `WRITE_TRANSACTION_SIGNAL_ORDER_GUIDE.md`.*
